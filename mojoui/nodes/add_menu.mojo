"""Add-node context menu — right-click on canvas spawns a typedef-filtered
spawn list. M2.5 chunk 40.

Mirrors EriGui's `AddNodeMenuState` from `erigui-widgets/src/node_graph/
add_menu.rs` (per `EriGui node audit notes` §"Context Menu / Node Spawning
UX"): a retained menu state lives across frames (`open`, `anchor`,
`world_spawn_pos`, `search_text`, `selected_idx`), the rendering function
is immediate-mode and re-runs each frame. EriGui decouples the registry
through a `NodeRegistryHandle` trait; MojoUI's c37 registry is a concrete
struct referenced directly — the trait can be introduced later if needed.

API:

  - `AddMenuState` — Movable-only, one per canvas; `show_at(screen_pos,
    world_pos)` opens, `hide()` closes. Fields are public so the caller's
    text-input widget can drive `search_text` directly (mirrors
    `widgets/text_edit` `mut buffer` convention).

  - `add_menu(ctx, id_str, mut state, registry, mut graph) raises -> Bool`
    — renders nothing when closed; otherwise a 250 px popup at anchor
    with search-box placeholder + up to 8 filtered entries. Returns True
    iff a node was spawned this frame.

  - `_filter_registry(registry, search) raises -> List[String]` — case-
    insensitive substring match on `display_name`. Empty search returns
    insertion order. Exposed module-private for tests.

  - `_lower(s)` / `_contains_substr(h, n)` — byte-level ASCII helpers.
    Full Unicode case folding deferred to M3.

Caller pattern (NodeCanvas widget c39 / examples/m2_5):

```mojo
if right_clicked and not over_node:
    menu_state.show_at(mouse_screen, mouse_world)
if add_menu(ctx, String("canvas_menu"), menu_state, registry, graph):
    pass  # node spawned at menu_state.world_spawn_pos
```

M2.5 deliberate omissions (per brief WHAT-NOT-to-do; c41+ picks up):

  - No keyboard nav (`selected_idx` stored but not driven) — M3.
  - No live typing into `search_text` — caller wires a `text_edit`
    instance pointed at our field. The menu only renders the current
    value as a placeholder label.
  - No category headers / sub-menus — flat filtered list (matches EriGui
    `add_menu.rs:124-138`).
  - No click-outside-to-dismiss — c39 canvas detects that pattern and
    calls `state.hide()` directly. The menu self-dismisses only on
    item-click + Escape.
  - `Graph.add_node` lacks a pre-built-Node entry point, so spawn uses
    "allocate-via-add_node, remove, append-from-registry.make_node". M3
    refactors Graph to accept a pre-built Node atomically.

Forbidden-syntax audit (Mojo implementation notes cumulative): no `fn` (c8), no
`@value` (c16), no `Stringable` (c8), no module-level `var` (c10), no new
`alias` (c11; `comptime` only), no `unsafe_cstr_ptr` (c7), no explicit
`__copyinit__` (c32/c33). `.copy()` at every Vec2/Rect/Color/String read
passed onward (c12/c13/c15).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_RELEASED, OPT_NONE
from mojoui.core.id import RetainedId
from mojoui.nodes.graph import Graph
from mojoui.nodes.registry import NodeRegistry, NodeTypeDef
from mojoui.render.ffi import MOJOUI_KEY_ESCAPE


# ============================================================================
# Geometry constants — comptime so they participate in compile-time eval.
# ============================================================================


comptime _MENU_WIDTH: Float32 = 250.0
"""Total menu width in screen pixels."""

comptime _SEARCH_H: Float32 = 28.0
"""Height of the search-box row (top of the menu)."""

comptime _ROW_H: Float32 = 22.0
"""Height per filtered registry entry row."""

comptime _MAX_VISIBLE: Int = 8
"""Maximum number of filtered entries rendered. Excess is clipped silently
(M3 adds scrolling)."""

comptime _MENU_PAD: Float32 = 4.0
"""Inner padding between the menu's outer rect and content."""


# ============================================================================
# AddMenuState — retained per-canvas state
# ============================================================================


struct AddMenuState(Movable):
    """Per-canvas retained add-menu state. Movable-only (one per canvas;
    copies would risk parallel UI drivers). Fields are public so the
    caller's text-input widget can drive `search_text` directly
    (mirrors `widgets/text_edit` `mut buffer` convention).
    """

    var open: Bool
    """True while menu is visible. Flipped by `show_at`/`hide`."""

    var anchor: Vec2
    """Screen-space top-left where the menu was opened. No viewport
    clamp (M3 adds edge-flip)."""

    var world_spawn_pos: Vec2
    """World-space new-node spawn position recorded at `show_at`. The
    canvas un-projects the mouse through `pan`/`zoom` before opening —
    the menu is transform-agnostic."""

    var search_text: String
    """Filter substring; caller's text-input mutates between frames.
    Empty matches every type_id."""

    var selected_idx: Int32
    """M3 keyboard-nav index. Stored, not driven in M2.5."""

    def __init__(out self):
        """Construct a closed menu with empty filter."""
        self.open = False
        self.anchor = Vec2(0.0, 0.0)
        self.world_spawn_pos = Vec2(0.0, 0.0)
        self.search_text = String("")
        self.selected_idx = 0

    def show_at(mut self, screen_pos: Vec2, world_pos: Vec2):
        """Open at `screen_pos` with `world_pos` as spawn anchor;
        clears filter and selection."""
        self.open = True
        self.anchor = screen_pos.copy()
        self.world_spawn_pos = world_pos.copy()
        self.search_text = String("")
        self.selected_idx = 0

    def hide(mut self):
        """Close the menu (other fields preserved until next show_at)."""
        self.open = False


# ============================================================================
# add_menu — immediate-mode renderer + click handler
# ============================================================================


def add_menu(
    mut ctx: Context,
    id_str: String,
    mut menu_state: AddMenuState,
    registry: NodeRegistry,
    mut graph: Graph,
) raises -> Bool:
    """Render the add-node menu if `menu_state.open`. Returns True iff
    a node was spawned this frame.

    Steps: (1) early-out when closed; (2) filter registry; (3) compute
    menu rect; (4) draw bg + 4-rect border; (5) search-box placeholder;
    (6) per-entry control + hover bg + label + click→spawn; (7) Escape
    dismiss.

    Raises propagate from `registry.lookup` / `make_node` (Dict access
    raises per c37 finding). `id_str` scopes control IDs under the
    caller's id_stack (microui contextual-hashing contract).
    """
    if not menu_state.open:
        return False

    # 2. Filter.
    var matches = _filter_registry(registry, menu_state.search_text)

    # 3. Geometry. `_MENU_PAD` doubled at the bottom for breathing room
    # under the last row.
    var n_total = len(matches)
    var visible_count = n_total
    if visible_count > _MAX_VISIBLE:
        visible_count = _MAX_VISIBLE
    var menu_h = _SEARCH_H + Float32(visible_count) * _ROW_H + _MENU_PAD * 2.0
    var menu_rect = Rect(menu_state.anchor.x, menu_state.anchor.y, _MENU_WIDTH, menu_h)

    # 4. Background + 4-rect border.
    ctx.draw_rect(menu_rect.copy(), Color(30, 30, 36, 245))
    _draw_menu_border(ctx, menu_rect.copy(), ctx.theme.primary.copy(), 1.0)

    # 5. Search-box placeholder. The full text-input wiring is the
    # caller's responsibility (per WHAT-NOT-to-do in the brief); here
    # we just render whatever is currently in `search_text` (or a hint
    # when empty). Font_id == 0 → skip text per FRAGILE #5.
    var search_rect = Rect(
        menu_rect.x + _MENU_PAD,
        menu_rect.y + _MENU_PAD,
        menu_rect.w - _MENU_PAD * 2.0,
        _SEARCH_H - _MENU_PAD,
    )
    ctx.draw_rect(search_rect.copy(), Color(50, 50, 60, 255))
    if ctx.theme.font_id != 0:
        var search_display: String
        if menu_state.search_text.byte_length() == 0:
            search_display = String("(type to filter)")
        else:
            search_display = String("Search: ") + menu_state.search_text
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(search_rect.x + _MENU_PAD, search_rect.y + 16.0),
            ctx.theme.text.copy(),
            search_display,
        )

    # 6. Per-entry rows.
    var spawned = False
    for i in range(visible_count):
        var type_id = matches[i].copy()
        var typedef = registry.lookup(type_id)  # raises on miss; matches came from `registry`
        var row_y = menu_rect.y + _SEARCH_H + Float32(i) * _ROW_H
        var row_rect = Rect(
            menu_rect.x + _MENU_PAD,
            row_y,
            menu_rect.w - _MENU_PAD * 2.0,
            _ROW_H - 2.0,
        )

        # Per-item id — derived from menu's id_str + entry's type_id so
        # two adjacent menus don't share state.
        var item_id_str = id_str + String("_item_") + type_id
        var item_id = ctx.get_id(item_id_str)
        var item_flags = ctx.update_control(item_id, row_rect.copy(), OPT_NONE)

        # Hover highlight. Background defaults to transparent (no draw
        # cost beyond the row_rect background that's already painted on
        # hover only).
        if (item_flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(row_rect.copy(), Color(60, 70, 110, 255))

        # Label — typedef.display_name.
        if ctx.theme.font_id != 0:
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                Vec2(row_rect.x + _MENU_PAD, row_rect.y + 14.0),
                ctx.theme.text.copy(),
                typedef.display_name,
            )

        # Click → spawn. The two-step (Graph.add_node + remove + append
        # registry.make_node) is the M2.5 stub for the M3 atomic API.
        if (item_flags & CTRL_RELEASED) != 0:
            var placeholder_id = graph.add_node(type_id, menu_state.world_spawn_pos.copy())
            graph.remove_node(placeholder_id)
            var fresh_id = graph.id_alloc.alloc()
            var built = registry.make_node(
                type_id, menu_state.world_spawn_pos.copy(), fresh_id
            )
            graph.nodes.append(built^)
            menu_state.hide()
            spawned = True

    # 7. Escape dismiss. `key_pressed` is a pure-Mojo read from the
    # InputState's keys array (no FFI in this path; the FFI lives in
    # `InputState.poll`, which is upstream of us). Safe to call from
    # any frame.
    if ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
        menu_state.hide()

    return spawned


# ============================================================================
# _draw_menu_border — local 4-rect outline helper (mirrors widget pattern)
# ============================================================================


def _draw_menu_border(
    mut ctx: Context, rect: Rect, color: Color, thickness: Float32
):
    """4-rect outline. Mirrors `widgets/basic._draw_border` — kept
    private per widget-isolation convention; M3 collapses copies into
    one shared AA helper."""
    # Top edge.
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    # Bottom edge.
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    # Left edge (inset to avoid double-painting corners).
    ctx.draw_rect(
        Rect(rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness),
        color.copy(),
    )
    # Right edge.
    ctx.draw_rect(
        Rect(
            rect.x + rect.w - thickness,
            rect.y + thickness,
            thickness,
            rect.h - 2.0 * thickness,
        ),
        color.copy(),
    )


# ============================================================================
# _filter_registry — case-insensitive substring filter on display_name
# ============================================================================


def _filter_registry(registry: NodeRegistry, search: String) raises -> List[String]:
    """Return type_ids whose display_name contains `search` (case-
    insensitive substring). Empty search returns insertion order
    (canonical menu order per c37). Raises propagate from lookup
    (Dict access) — in practice never misses since every key came from
    `register()`. Uses `byte_length()` not `len(s)` per c11 wall.
    """
    if search.byte_length() == 0:
        return registry.all_type_ids()

    var search_lower = _lower(search)
    var matches = List[String]()
    var all_ids = registry.all_type_ids()
    var n = len(all_ids)
    for i in range(n):
        var tid = all_ids[i].copy()
        var typedef = registry.lookup(tid)
        var name_lower = _lower(typedef.display_name)
        if _contains_substr(name_lower, search_lower):
            matches.append(tid^)
    return matches^


# ============================================================================
# _lower — byte-level ASCII lowercase
# ============================================================================


def _lower(s: String) -> String:
    """Byte-level ASCII lowercase. Bytes 0x41..0x5A (A..Z) shift by
    0x20; everything else passes through (multi-byte UTF-8 high bytes
    >=0x80 untouched). Full Unicode case folding deferred to M3.
    Construction mirrors `widgets/text_edit._apply_text_edit_input` —
    copy bytes through `List[UInt8]` and rebuild via
    `String(unsafe_from_utf8=...)` per c24 finding.
    """
    var n = s.byte_length()
    var out_bytes = List[UInt8](capacity=n)
    var ptr = s.unsafe_ptr()
    for i in range(n):
        var b = ptr[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            b = b + UInt8(0x20)
        out_bytes.append(b)
    return String(unsafe_from_utf8=out_bytes)


# ============================================================================
# _contains_substr — naive byte-level substring search
# ============================================================================


def _contains_substr(haystack: String, needle: String) -> Bool:
    """True iff `needle` appears as a contiguous byte run inside
    `haystack`. Empty needle returns True. Naive O(n*m) — fine for
    n,m<32 bytes (every realistic display_name); M3 swaps in
    Boyer-Moore if profiling flags it (unlikely for 5..50 entries).
    """
    var hn = haystack.byte_length()
    var nn = needle.byte_length()
    if nn == 0:
        return True
    if nn > hn:
        return False
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return True
    return False
