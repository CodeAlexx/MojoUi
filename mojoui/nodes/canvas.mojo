"""NodeCanvas — immediate-mode node-graph viewport (M2.5 chunk 39).

Renders a retained `Graph` (c36) inside a pan/zoom viewport: each `Node`'s
title bar + body + per-port dots are drawn, each `Edge` is drawn as a
cubic-bezier wire (c38), and the canvas drives node-drag + single-select
interaction directly mutating the caller-owned `CanvasState` + `Graph`.

Mirrors EriGui's `NodeGraph` widget (`erigui-widgets/src/node_graph/mod.rs`)
per EriGui node audit notes "Canvas / Visual Layer":

  - `pan: Vec2`, `zoom: Float32` — affine `screen = world * zoom + pan`.
  - `Interaction` variants — M2.5 ships **NodeDrag + Pan only**. LinkDrag
    / Marquee / FieldSliderDrag are M3 (the LinkDrag-in-progress state
    fields are RESERVED here so M3 can wire them without an ABI break).
  - Wires via `wires.draw_wire` — 24 segments, horizontal-tangent control
    points at `dx * 0.35` (c38).

Usage (microui begin/end container pattern, same as `scroll_area` c28 /
`window_panel` c30):

    var state = CanvasState()
    var graph = Graph()
    ...
    if begin_node_canvas(ctx, "main_canvas", state, graph):
        # state changed this frame — caller may invalidate caches.
        pass
    # caller overlays (debug HUD, add-menu) here.
    end_node_canvas(ctx)

`CanvasState` is RETAINED (Movable, not Copyable — copy semantics make
no sense for "active drag state"). Drag start sets `dragging_node` +
`selected_node` + `drag_offset`; each frame inverts the affine to
recompute the node's world position so the click point stays glued to
the cursor; drag ends on LEFT-button release. Held MIDDLE button pans
the viewport.

What this chunk deliberately does NOT do (M3+): multi-select / marquee,
LinkDrag (the wire-drag-in-progress UI; fields reserved), mouse-wheel
zoom (wheel-event FFI is M3), minimap / grid dots / port hover glow,
connect-time type checking, right-click add-menu.

`.copy()` discipline: `Vec2`/`Rect`/`Color` are Copyable-not-
ImplicitlyCopyable (Mojo implementation notes c15) — every read into another call
needs `.copy()`. `Float32`/`Bool`/`UInt64` ARE ImplicitlyCopyable;
`String` is ImplicitlyCopyable per c29.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import OPT_NONE, CTRL_ACTIVE, CTRL_RELEASED, CTRL_PRESSED
from mojoui.core.id import ImmediateId, RetainedId, RET_ID_NONE
from mojoui.nodes.node import Node, PortRef
from mojoui.nodes.graph import Graph, Edge
from mojoui.nodes.wires import (
    draw_wire,
    draw_wire_thick,
    wire_color_for_type,
    wire_distance_to_point,
    WIRE_THICKNESS,
)
from mojoui.nodes.node_body import draw_node_body
from mojoui.render.ffi import MOJOUI_BTN_RIGHT, MOJOUI_KEY_DELETE


# Title bar height (px) in WORLD space; multiplied by `state.zoom` when
# drawn. Matches `window_panel._TITLE_BAR_H` so a node title bar is the
# same visual height as a window title bar at zoom == 1.0.
comptime _TITLE_BAR_H: Float32 = 24.0

# Vertical pitch between port dots inside a node (world space).
comptime _PORT_SPACING: Float32 = 20.0

# On-screen diameter of a port dot (px). Drawn as an axis-aligned square
# rather than a circle (M2.5 stub for the M3 tessellator's filled disc).
comptime _PORT_DOT_SIZE: Float32 = 8.0

# Default node body fill (RGBA bytes packed into Color at runtime).
comptime _NODE_BG_R: Int = 40
comptime _NODE_BG_G: Int = 40
comptime _NODE_BG_B: Int = 50
comptime _NODE_BG_A: Int = 240

# Node body fill when selected — same hue as primary but darker so the
# title bar still pops against the body.
comptime _NODE_SEL_R: Int = 60
comptime _NODE_SEL_G: Int = 60
comptime _NODE_SEL_B: Int = 90

# Title bar fill (matches EriGui's "header" color shape — slightly
# brighter / cooler than the body fill).
comptime _TITLE_BG_R: Int = 60
comptime _TITLE_BG_G: Int = 70
comptime _TITLE_BG_B: Int = 110

# Canvas background — dark slate so the bright node colors pop. M3 reads
# from theme.
comptime _CANVAS_BG_R: Int = 15
comptime _CANVAS_BG_G: Int = 15
comptime _CANVAS_BG_B: Int = 18

# Default border (un-selected) — neutral grey.
comptime _BORDER_R: Int = 80
comptime _BORDER_G: Int = 80
comptime _BORDER_B: Int = 90

# Mouse-button indices (mirror `mojoui/render/ffi.mojo` MOJOUI_BTN_*).
comptime _BTN_LEFT: Int32 = 0
comptime _BTN_MIDDLE: Int32 = 2

# Max screen-space distance (px) from the cursor to a wire's bezier
# polyline for the wire to count as hovered/clickable. ~half the port-dot
# size gives a comfortable hit target without overlapping adjacent wires.
comptime _WIRE_HIT_DIST: Float32 = 6.0

# Stroke thickness for the hovered / selected wire (vs WIRE_THICKNESS for
# idle wires). Selected is thickest so it reads as "armed for delete".
comptime _WIRE_HOVER_THICKNESS: Float32 = 3.5
comptime _WIRE_SELECT_THICKNESS: Float32 = 4.5


# ============================================================================
# CanvasState — retained per-canvas state
# ============================================================================


struct CanvasState(Movable):
    """Per-canvas mutable state — persists across frames (retained).

    Owned by the application; threaded into `begin_node_canvas` by `mut`
    reference. `Movable` only — copy semantics make no sense for "active
    drag in progress" (would alias the drag across canvases).

    M3 LinkDrag fields (`wire_drag_from_*`) are RESERVED — zero-init by
    `__init__`, never read in M2.5. Wiring LinkDrag in M3 only changes
    the body of `begin_node_canvas`, not the struct shape.
    """

    var pan: Vec2
    """Screen-space offset of the world origin. Mutated by middle-button
    drag. `screen = world * zoom + pan`."""

    var zoom: Float32
    """Affine scale factor. 1.0 = no scaling; >1 zooms in. Mouse-wheel
    zoom is M3."""

    var dragging_node: RetainedId
    """Id of the node currently being dragged, or `RET_ID_NONE`. Set on
    `CTRL_PRESSED` over a node body; cleared on LEFT-button release."""

    var drag_offset: Vec2
    """Mouse-pos minus node-screen-top-left at drag start; used each
    frame to keep the click point under the cursor."""

    var selected_node: RetainedId
    """Single-select for M2.5 — never auto-cleared (M3 clears on
    background click). Set on every successful node press."""

    var wire_drag_from_node: RetainedId
    """RESERVED for M3 LinkDrag. Zero-init to `RET_ID_NONE`."""

    var wire_drag_from_port: String
    """RESERVED for M3 LinkDrag. Empty-string sentinel in M2.5."""

    var wire_drag_from_is_output: Bool
    """RESERVED for M3 LinkDrag. False in M2.5."""

    var ctx_menu_open: Bool
    """True while the per-node right-click context menu is showing. Set
    when RMB is pressed over a node body; cleared by the menu widget on
    item-click or click-outside (see `node_menu.node_context_menu`)."""

    var ctx_menu_anchor: Vec2
    """Window-space top-left for the open context menu — the point where
    the user right-clicked."""

    var ctx_menu_node: RetainedId
    """Id of the node the open context menu targets, or `RET_ID_NONE`."""

    var renaming_node: RetainedId
    """Id of the node currently being renamed (set when the context
    menu's Rename item is chosen), or `RET_ID_NONE`. The canvas itself
    does NOT draw the rename text field — that pulls the FFI-backed
    `text_edit` into the pure node layer. A live app overlays a
    `text_edit` bound to `graph.nodes[i].title` while this is set, then
    clears it. Pure-Mojo callers/tests just observe the flag."""

    var selected_edge: Int32
    """List index of the currently-selected wire, or -1. Selection is
    by index (stable while the edge list is unmutated); cleared to -1 on
    any structural change (node press, edge delete)."""

    var hovered_edge: Int32
    """List index of the wire under the cursor this frame, or -1.
    Recomputed every frame in `begin_node_canvas`; drives the thicker
    hover stroke. Not persisted across frames in any meaningful way."""

    def __init__(out self):
        """Default — origin pan, identity zoom, no drag, no selection."""
        self.pan = Vec2.zero()
        self.zoom = Float32(1.0)
        self.dragging_node = RET_ID_NONE
        self.drag_offset = Vec2.zero()
        self.selected_node = RET_ID_NONE
        self.wire_drag_from_node = RET_ID_NONE
        self.wire_drag_from_port = String("")
        self.wire_drag_from_is_output = False
        self.ctx_menu_open = False
        self.ctx_menu_anchor = Vec2.zero()
        self.ctx_menu_node = RET_ID_NONE
        self.renaming_node = RET_ID_NONE
        self.selected_edge = Int32(-1)
        self.hovered_edge = Int32(-1)


# ============================================================================
# Transform helpers
# ============================================================================


def canvas_world_to_screen(state: CanvasState, world: Vec2) -> Vec2:
    """Affine world→screen: `screen = world * zoom + pan`."""
    return Vec2(world.x * state.zoom + state.pan.x, world.y * state.zoom + state.pan.y)


def canvas_screen_to_world(state: CanvasState, screen: Vec2) -> Vec2:
    """Inverse of `canvas_world_to_screen`. Guards against divide-by-zero
    in the degenerate `zoom == 0` case (returns origin)."""
    if state.zoom == Float32(0.0):
        return Vec2.zero()
    return Vec2(
        (screen.x - state.pan.x) / state.zoom,
        (screen.y - state.pan.y) / state.zoom,
    )


def port_screen_pos(
    state: CanvasState, node: Node, port_index: Int, is_input: Bool
) -> Vec2:
    """Returns the on-screen anchor of port `port_index` on `node`.

    Layout: ports stack vertically inside the node's body, starting just
    below the title bar. Input ports anchor on the LEFT edge (x =
    `node.position.x`); output ports anchor on the RIGHT edge (x =
    `node.position.x + node.size.x`). Y coordinate is shared between
    inputs and outputs at the same index (visually rows the I/O pair).
    """
    var port_y_world = (
        node.position.y
        + _TITLE_BAR_H
        + Float32(port_index) * _PORT_SPACING
        + _PORT_SPACING * Float32(0.5)
    )
    var port_x_world: Float32 = node.position.x
    if not is_input:
        port_x_world = port_x_world + node.size.x
    return canvas_world_to_screen(state, Vec2(port_x_world, port_y_world))


def hovered_edge(
    state: CanvasState, graph: Graph, point: Vec2, threshold: Float32
) -> Int32:
    """Return the list index of the edge whose drawn bezier passes closest
    to `point` (screen space), provided that distance is within
    `threshold` px; otherwise -1.

    Resolves each edge's endpoints exactly as the wire-draw loop does
    (port-index-by-NAME, then `port_screen_pos`) so the clickable region
    matches the rendered curve. Edges referencing a missing node/port are
    skipped. Pure (non-raising) so tests can call it directly with a known
    on-curve point.
    """
    var best_idx: Int32 = -1
    var best_dist = threshold
    var ne = graph.edge_count()
    for ei in range(ne):
        var edge = graph.edges[ei].copy()
        var from_idx = graph.find_node(edge.from_node)
        var to_idx = graph.find_node(edge.to_node)
        if from_idx < 0 or to_idx < 0:
            continue
        var from_node = graph.nodes[from_idx].copy()
        var to_node = graph.nodes[to_idx].copy()

        var from_port_idx: Int = -1
        var nfo = len(from_node.outputs)
        for pi in range(nfo):
            if from_node.outputs[pi].name == edge.from_port:
                from_port_idx = pi
                break
        var to_port_idx: Int = -1
        var nti = len(to_node.inputs)
        for pi in range(nti):
            if to_node.inputs[pi].name == edge.to_port:
                to_port_idx = pi
                break
        if from_port_idx < 0 or to_port_idx < 0:
            continue

        var from_pos = port_screen_pos(state, from_node, from_port_idx, False)
        var to_pos = port_screen_pos(state, to_node, to_port_idx, True)
        var d = wire_distance_to_point(
            from_pos.copy(), to_pos.copy(), point.copy()
        )
        if d <= best_dist:
            best_dist = d
            best_idx = Int32(ei)
    return best_idx


# ============================================================================
# begin_node_canvas / end_node_canvas
# ============================================================================


def begin_node_canvas(
    mut ctx: Context,
    id_str: String,
    mut state: CanvasState,
    mut graph: Graph,
) raises -> Bool:
    """Render the canvas viewport. Returns True iff `state` or `graph`
    were mutated this frame (drag, selection, pan, wire-select/delete,
    right-click-to-open-context-menu).

    JUMP semantics: does NOT emit `CMD_JUMP`. Uses the layout flow's
    current slot and clips children with a single `CMD_CLIP`.
    Caller contract: title text only renders when `ctx.theme.font_id != 0`
    (FRAGILE #5).

    `raises`: the per-node body renderer (`draw_node_body`) reads the
    node's `fields` Dict (getitem raises in current beta). All existing
    callers are already in `raises` contexts.

    Companion overlays — call AFTER `end_node_canvas`:
      - `node_menu.node_context_menu` — handles the right-click menu this
        function opens via `state.ctx_menu_*`.
      - `progress.draw_progress_overlay` — per-node status badges.
    """
    # 1. id, outer slot, update_control. Pan/drag are driven off
    #    `ctx.input.mouse_held(...)` directly so the returned flags are
    #    only reserved for future hover feedback.
    var id = ctx.get_id(id_str)
    var rect = ctx.layout_next()
    var _viewport_flags = ctx.update_control(id, rect.copy(), OPT_NONE)
    var changed: Bool = False

    # Push an id_stack scope so per-node ids derived below (`"node_<N>"`)
    # don't collide between two canvases on the same Context. Paired with
    # `ctx.pop_id()` in `end_node_canvas`. Matches the scroll_area /
    # window_panel convention from the M2 bugfix (regression notes
    # FRAGILE #3); re-applied here per M2.5 skeptic FRAGILE #1.
    ctx.push_id_str(id_str)

    # 2. Clip to viewport (one CMD_CLIP; restored by end_node_canvas).
    ctx.draw_clip(rect.copy())

    # 3. Canvas background (dark slate). M3 reads from theme.
    ctx.draw_rect(
        rect.copy(),
        Color(
            UInt8(_CANVAS_BG_R),
            UInt8(_CANVAS_BG_G),
            UInt8(_CANVAS_BG_B),
            UInt8(255),
        ),
    )

    # 4. Pan — middle-button hold drags the viewport (EriGui Interaction::Pan).
    if ctx.input.mouse_held(_BTN_MIDDLE):
        var pan_dx = ctx.input.mouse_delta.x
        var pan_dy = ctx.input.mouse_delta.y
        if pan_dx != Float32(0.0) or pan_dy != Float32(0.0):
            state.pan.x = state.pan.x + pan_dx
            state.pan.y = state.pan.y + pan_dy
            changed = True

    # 5. Walk every node — draw body + title + border + port dots and
    #    handle press for select-and-start-drag. Iterate by integer
    #    index (no direct `for n in graph.nodes` in current beta).
    # `node_left_pressed` records whether a node claimed the left-press
    # this frame; the wire-select pass below uses it to avoid stealing a
    # click that landed on a node.
    var node_left_pressed: Bool = False
    var nn = graph.node_count()
    for i in range(nn):
        var node = graph.nodes[i].copy()
        var node_pos_world = node.position.copy()
        var screen_pos = canvas_world_to_screen(state, node_pos_world.copy())
        var screen_size = Vec2(
            node.size.x * state.zoom, node.size.y * state.zoom
        )
        var node_rect = Rect(
            screen_pos.x, screen_pos.y, screen_size.x, screen_size.y
        )

        # Per-node ID derived from the RetainedId.
        var node_id_str = String("node_") + String(node.id)
        var node_id = ctx.get_id(node_id_str)
        var node_flags = ctx.update_control(
            node_id, node_rect.copy(), OPT_NONE
        )

        # Drag start on press — claim selection + drag, remember the
        # click offset within the node so cursor stays glued to it.
        if (node_flags & CTRL_PRESSED) != 0:
            state.selected_node = node.id
            state.dragging_node = node.id
            state.selected_edge = Int32(-1)  # node-select clears wire-select
            node_left_pressed = True
            state.drag_offset = Vec2(
                ctx.control.mouse_pos.x - screen_pos.x,
                ctx.control.mouse_pos.y - screen_pos.y,
            )
            changed = True

        # Right-click over a node body → open the per-node context menu.
        # `mouse_pressed` is a pure struct read (no FFI; the FFI lives in
        # input.poll upstream), so this is safe under `mojo run` tests.
        # Last matching node in iteration order wins (= topmost).
        if ctx.input.mouse_pressed(MOJOUI_BTN_RIGHT) and node_rect.contains(
            ctx.control.mouse_pos.copy()
        ):
            state.selected_node = node.id
            state.ctx_menu_open = True
            state.ctx_menu_node = node.id
            state.ctx_menu_anchor = ctx.control.mouse_pos.copy()
            changed = True

        # Body fill — brighter shade when selected.
        var is_selected = state.selected_node == node.id
        var body_color: Color
        if is_selected:
            body_color = Color(
                UInt8(_NODE_SEL_R),
                UInt8(_NODE_SEL_G),
                UInt8(_NODE_SEL_B),
                UInt8(_NODE_BG_A),
            )
        else:
            body_color = Color(
                UInt8(_NODE_BG_R),
                UInt8(_NODE_BG_G),
                UInt8(_NODE_BG_B),
                UInt8(_NODE_BG_A),
            )
        ctx.draw_rect(node_rect.copy(), body_color^)

        # Title bar — height scales with zoom.
        var title_rect = Rect(
            node_rect.x,
            node_rect.y,
            node_rect.w,
            _TITLE_BAR_H * state.zoom,
        )
        ctx.draw_rect(
            title_rect.copy(),
            Color(
                UInt8(_TITLE_BG_R),
                UInt8(_TITLE_BG_G),
                UInt8(_TITLE_BG_B),
                UInt8(255),
            ),
        )

        # Title text (FRAGILE #5 — only when font loaded).
        if ctx.theme.font_id != 0:
            var title_pos = Vec2(
                title_rect.x + Float32(6.0),
                title_rect.y + Float32(16.0),
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                title_pos^,
                ctx.theme.text.copy(),
                node.title,
            )

        # Body — per-node field rows (the draw_body hook seam). Default
        # renderer lists `name: value` for each field below the title bar.
        # No-op when font_id == 0 (headless).
        draw_node_body(ctx, node, node_rect.copy(), _TITLE_BAR_H * state.zoom)

        # Border — primary when selected, neutral grey otherwise.
        # Four thin filled rects (same shape as window_panel._draw_border).
        var border_color: Color
        if is_selected:
            border_color = ctx.theme.primary.copy()
        else:
            border_color = Color(
                UInt8(_BORDER_R),
                UInt8(_BORDER_G),
                UInt8(_BORDER_B),
                UInt8(255),
            )
        # Top, bottom, left, right edges (1 px each).
        ctx.draw_rect(
            Rect(node_rect.x, node_rect.y, node_rect.w, Float32(1.0)),
            border_color.copy(),
        )
        ctx.draw_rect(
            Rect(
                node_rect.x,
                node_rect.y + node_rect.h - Float32(1.0),
                node_rect.w,
                Float32(1.0),
            ),
            border_color.copy(),
        )
        ctx.draw_rect(
            Rect(
                node_rect.x,
                node_rect.y + Float32(1.0),
                Float32(1.0),
                node_rect.h - Float32(2.0),
            ),
            border_color.copy(),
        )
        ctx.draw_rect(
            Rect(
                node_rect.x + node_rect.w - Float32(1.0),
                node_rect.y + Float32(1.0),
                Float32(1.0),
                node_rect.h - Float32(2.0),
            ),
            border_color^,
        )

        # Port dots — input (left edge) + output (right edge). Color
        # via `wire_color_for_type`.
        var n_inputs = len(node.inputs)
        for pi in range(n_inputs):
            var p = node.inputs[pi].copy()
            var pos = port_screen_pos(state, node, pi, True)
            var port_color = wire_color_for_type(p.value_type)
            ctx.draw_rect(
                Rect(
                    pos.x - _PORT_DOT_SIZE * Float32(0.5),
                    pos.y - _PORT_DOT_SIZE * Float32(0.5),
                    _PORT_DOT_SIZE,
                    _PORT_DOT_SIZE,
                ),
                port_color^,
            )
        var n_outputs = len(node.outputs)
        for pi in range(n_outputs):
            var p = node.outputs[pi].copy()
            var pos = port_screen_pos(state, node, pi, False)
            var port_color = wire_color_for_type(p.value_type)
            ctx.draw_rect(
                Rect(
                    pos.x - _PORT_DOT_SIZE * Float32(0.5),
                    pos.y - _PORT_DOT_SIZE * Float32(0.5),
                    _PORT_DOT_SIZE,
                    _PORT_DOT_SIZE,
                ),
                port_color^,
            )

    # 6. NodeDrag in progress — inverse-transform cursor through active
    #    pan/zoom to get the new world position; drag_offset is in
    #    screen space (same units as the cursor).
    if state.dragging_node != RET_ID_NONE:
        var idx = graph.find_node(state.dragging_node)
        if idx >= 0:
            if state.zoom != Float32(0.0):
                var new_world_x = (
                    ctx.control.mouse_pos.x
                    - state.drag_offset.x
                    - state.pan.x
                ) / state.zoom
                var new_world_y = (
                    ctx.control.mouse_pos.y
                    - state.drag_offset.y
                    - state.pan.y
                ) / state.zoom
                graph.nodes[idx].position = Vec2(new_world_x, new_world_y)
                changed = True
        # Drag ends on LEFT-button release. We check `mouse_released`
        # (rising-edge to up) rather than `not mouse_held` because the
        # press frame itself has pressed=True/held=True but the test
        # fixture (`begin_frame_no_input`) does not auto-sync `held`
        # off `pressed` — checking the release edge keeps both the
        # production path (poll() syncs held) and the test path
        # consistent.
        if ctx.input.mouse_released(_BTN_LEFT):
            state.dragging_node = RET_ID_NONE

    # 7. Wire hover hit-test (before drawing so the hovered/selected wire
    #    can be stroked thicker this same frame). Nearest edge within
    #    `_WIRE_HIT_DIST` px of the cursor, or -1.
    state.hovered_edge = hovered_edge(
        state, graph, ctx.control.mouse_pos.copy(), _WIRE_HIT_DIST
    )

    # 8. Wires — drawn AFTER nodes so they paint on top of node bodies.
    var ne = graph.edge_count()
    for ei in range(ne):
        var edge = graph.edges[ei].copy()
        var from_idx = graph.find_node(edge.from_node)
        var to_idx = graph.find_node(edge.to_node)
        if from_idx < 0 or to_idx < 0:
            continue
        var from_node = graph.nodes[from_idx].copy()
        var to_node = graph.nodes[to_idx].copy()

        # Resolve port indices by NAME (EriGui invariant).
        var from_port_idx: Int = -1
        var nfo = len(from_node.outputs)
        for pi in range(nfo):
            if from_node.outputs[pi].name == edge.from_port:
                from_port_idx = pi
                break
        var to_port_idx: Int = -1
        var nti = len(to_node.inputs)
        for pi in range(nti):
            if to_node.inputs[pi].name == edge.to_port:
                to_port_idx = pi
                break
        if from_port_idx < 0 or to_port_idx < 0:
            continue

        var from_pos = port_screen_pos(
            state, from_node, from_port_idx, False
        )
        var to_pos = port_screen_pos(state, to_node, to_port_idx, True)
        var wcolor = wire_color_for_type(
            from_node.outputs[from_port_idx].value_type
        )
        # Selected wire = thickest + theme-primary so it reads as armed
        # for delete; hovered = medium; idle = default thickness.
        if Int32(ei) == state.selected_edge:
            draw_wire_thick(
                ctx,
                from_pos.copy(),
                to_pos.copy(),
                ctx.theme.primary.copy(),
                _WIRE_SELECT_THICKNESS,
            )
        elif Int32(ei) == state.hovered_edge:
            draw_wire_thick(
                ctx,
                from_pos.copy(),
                to_pos.copy(),
                wcolor^,
                _WIRE_HOVER_THICKNESS,
            )
        else:
            draw_wire(ctx, from_pos.copy(), to_pos.copy(), wcolor^)

    # 9. Wire select + delete.
    #    - Left-press on a hovered wire (and NOT on a node) selects it and
    #      clears any node selection.
    #    - Left-press on empty space (no node, no wire) clears wire-select.
    #    - Delete key removes the selected wire.
    if ctx.control.mouse_pressed_this_frame and not node_left_pressed:
        if state.hovered_edge >= Int32(0):
            state.selected_edge = state.hovered_edge
            state.selected_node = RET_ID_NONE
            changed = True
        else:
            if state.selected_edge >= Int32(0):
                state.selected_edge = Int32(-1)
                changed = True
    if state.selected_edge >= Int32(0):
        if ctx.input.key_pressed(MOJOUI_KEY_DELETE):
            graph.remove_edge_at(Int(state.selected_edge))
            state.selected_edge = Int32(-1)
            state.hovered_edge = Int32(-1)
            changed = True

    return changed


def end_node_canvas(mut ctx: Context):
    """End the matching `begin_node_canvas`: pop the id_stack scope pushed
    by `begin_node_canvas` and restore the clip rect to the full window.
    M2.5 does NOT push an inner layout frame so no `layout.pop()` is needed.
    """
    # Pop the id_stack scope pushed by begin_node_canvas (M2.5 skeptic
    # FRAGILE #1 — matches scroll_area / window_panel convention).
    ctx.pop_id()
    ctx.draw_clip(ctx.window_rect.copy())
