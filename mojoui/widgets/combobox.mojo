"""Combobox widget — dropdown selector. M2 chunk 25.

A combobox shows the currently-selected option in a closed "header" row; click
it to toggle a dropdown list of options below; click an option to select it
and close the list. Returns True on the single frame the selection changed.

Microui 6-step recipe (same shape as `widgets/basic.mojo::button` — wrapped
twice here: once for the closed header, once per option row when open):

    1. id     = ctx.get_id(id_str)             # caller-supplied id seed
    2. rect   = ctx.layout_next()              # the "closed" header rect
    3. flags  = ctx.update_control(id, rect, OPT_NONE)
    4. behavior — on CTRL_RELEASED on the header: toggle `is_open`. When the
                   dropdown is open, the per-option sub-rects each run their
                   own update_control (with a derived id) and on RELEASED
                   write the option index into `selected_index`, set
                   `is_open = False`, and flag `changed`.
    5. draw   — header: bg + selected option text + 'v' glyph. Open: draw
                 each option row as an overlay BELOW the header (absolute
                 positioning, no layout_next — overlay can extend past parent
                 bounds; M2 acceptable, M3 fixes with clip + z-order JUMP).
    6. return — `changed` (True only on the frame an option was picked).

ID strategy — caller-supplied `id_str`:
  Same convention as `widgets/slider.mojo::slider` and
  `widgets/drag_value.mojo::drag_value`. Two `combobox(ctx, id_str=...)` calls
  with the same id_str under the same id_stack parent will collide. Use
  `ctx.push_id_str("group")` to scope. Per-option ids are derived by pushing
  the header id then hashing the option index ("0", "1", ...) — this keeps
  the option ids stable across re-renders even if the options list shrinks
  or grows (the index is what matters, not the option text).

Open-state storage — caller-owned `mut is_open: Bool`:
  Mojo currently has no module-level mutable state (Mojo implementation notes "Module-
  level `var` is REJECTED") and no extensible Context-owned per-id state map
  (planned for M2.5 — once `serde/` lands an `IdMap[Bool]` becomes a natural
  fit). The pragmatic M2 workaround is to make the open flag an explicit
  caller-managed `Bool`. The caller stores it next to `selected_index` and
  threads both in each frame. This is uglier than egui's `egui::ComboBox`
  (which hides the open flag in `egui::Memory`) but it keeps the widget
  state machine entirely local to a single function call — no hidden
  storage, no per-id allocation, no surprise lifetime questions. M3 will
  swap to a Context-owned `IdMap[Bool]` once the broader retained-state
  story lands.

Out-of-bounds selected_index:
  If `selected_index < 0` or `>= len(options)`, the closed header just draws
  an empty selection string (no crash). The dropdown still renders all
  available options; clicking one heals the out-of-bounds state. This
  matches egui's defensive behaviour where a model with a stale index
  doesn't blow up the UI.

Overlay scope (M2 simplification):
  The open dropdown is drawn at absolute coordinates BELOW the closed header
  with no clip rect and no z-order isolation. Consequence: the overlay can
  extend past the parent container's bounds AND can draw underneath
  subsequent widgets that are emitted later in the same frame. M2 accepts
  this — proper layering needs (a) a clip command pushed at the start of
  the overlay and (b) a JUMP command at the end of the previous content so
  the overlay's draw commands are physically later in the command stream
  (microui's z-order trick — see `core/commands.mojo` `emit_jump` /
  `patch_jump`). M3 will wire both.

`.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
  `Rect`/`Color`/`Vec2`/`DefaultTheme` are `Copyable, Movable` but NOT
  `ImplicitlyCopyable`. Every read of a field-typed value to pass into
  another call needs `.copy()`. The header `rect` is read multiple times
  (update_control, draw_rect, draw_text, plus for the overlay y origin);
  the per-option sub-rects are read twice each (update_control + draw_rect).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_FOCUSED,
    CTRL_ACTIVE,
    CTRL_RELEASED,
    OPT_NONE,
)


# ============================================================================
# combobox — dropdown selector
# ============================================================================


def combobox(
    mut ctx: Context,
    id_str: String,
    options: List[String],
    mut selected_index: Int32,
    mut is_open: Bool,
) -> Bool:
    """Dropdown selector. Click the closed header to toggle open; click an
    option to select it and close. Returns True on the single frame the
    selection changed.

    Args:
        ctx:            Per-frame Context.
        id_str:         Caller-supplied id seed for contextual hashing — two
                        combobox calls with the same id_str under the same
                        id_stack parent will collide. Pass a logical name
                        (`"theme"`, `"sampler"`, etc).
        options:        List of option labels. May be empty (header still
                        draws, dropdown shows no rows when open).
        selected_index: Index into `options` of the currently-selected entry.
                        Out-of-range (negative or >= len) renders as empty
                        selection in the header — does not crash.
        is_open:        Caller-managed open/closed flag. Initialise to False;
                        widget toggles it on header click and clears it on
                        option click. (Caller-managed because Mojo has no
                        module-level state — see module docstring.)

    Returns: True iff `selected_index` changed this frame (option click on a
        different index than was previously selected). Returns False on every
        other interaction including header-click open/close.
    """
    # 1. id — contextual hash off id_stack top + id_str. Per-option ids are
    #    derived later by pushing this id then hashing the option index.
    var id = ctx.get_id(id_str)

    # 2. rect — the closed header slot.
    var rect = ctx.layout_next()

    # 3. update_control on the closed header.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4a. behavior — header click toggles is_open. Use CTRL_RELEASED (click
    #     semantic) NOT CTRL_PRESSED so a press-and-drag-off doesn't toggle.
    if (flags & CTRL_RELEASED) != 0:
        is_open = not is_open

    # 5a. draw the closed header — bg + border + selected option text + ▼.
    var bg: Color
    if (flags & CTRL_ACTIVE) != 0:
        bg = ctx.theme.active_bg.copy()
    elif (flags & CTRL_HOVERED) != 0:
        bg = ctx.theme.hover_bg.copy()
    else:
        bg = ctx.theme.control_bg.copy()
    ctx.draw_rect(rect.copy(), bg^)

    # Selected text — guarded for out-of-range index. Out-of-range renders
    # as an empty string in the header (no crash). Future M3 could render
    # a placeholder like "(select...)" but for M2 empty is sufficient.
    var disp = String("")
    var n_opts = Int32(len(options))
    if selected_index >= 0 and selected_index < n_opts:
        disp = options[Int(selected_index)]

    # Caller contract: call `ctx.set_default_font(<id>)` before the frame if
    # the header text/glyph should render. When `ctx.theme.font_id == 0` the
    # text draws are SKIPPED — see regression notes FRAGILE
    # #5: emitting CMD_TEXT with font_id=0 would corrupt the M3 renderer
    # adapter's font-id lookup.
    if ctx.theme.font_id != 0:
        var text_pos = Vec2(
            rect.x + Float32(ctx.theme.padding),
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            text_pos^,
            ctx.theme.text.copy(),
            disp,
        )

        # ▼ glyph (rendered as plain "v" for M2 — no Unicode-font guarantee yet).
        # Positioned at the right edge of the header, vertically aligned with
        # the selected text.
        var glyph = String("v")
        var glyph_pos = Vec2(
            rect.x + rect.w - Float32(ctx.theme.padding) - 8.0,
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            glyph_pos^,
            ctx.theme.text.copy(),
            glyph,
        )

    # 4b + 5b. dropdown overlay — only when open AND options is non-empty.
    # Each option row gets its own sub-rect, update_control with a derived
    # id (push_id_str the option index), and draws as background + text.
    # On RELEASED: write the index into selected_index, close the dropdown,
    # flag changed (only if the new index differs from the previous).
    #
    # M5 popup-layer wiring: wrap the dropdown drawing block in
    # `ctx.begin_popup(overlay_rect)` / `ctx.end_popup()`. This routes the
    # row backgrounds + text to `ctx.popup_commands` so they're appended
    # AFTER every base-layer widget at end_frame — the dropdown finally
    # renders on top instead of being occluded by subsequent widgets
    # (see implementation notes "Combobox: dropdown not
    # visibly appearing"). The popup rect is recorded so base-layer widgets
    # whose update_control runs later in the frame skip claiming hover
    # under the dropdown.
    var changed: Bool = False
    if is_open and n_opts > 0:
        # Compute the popup overlay rect (window-space): N rows tall,
        # same width as the header, anchored at the row below the header.
        var row_h = rect.h
        var popup_rect = Rect(
            rect.x, rect.y + rect.h, rect.w, row_h * Float32(n_opts),
        )
        ctx.begin_popup(popup_rect^)

        # Push the header id as the parent of the option ids so re-ordered
        # comboboxes don't cross-collide.
        ctx.push_id_str(id_str)
        var i: Int32 = 0
        while i < n_opts:
            # Dropdown row y: header bottom at rect.y + rect.h; the overlay
            # starts there and extends down N rows STRICTLY BELOW the header
            # (no overlap). The previous "(rect.h / 2.0) + i*row_h" formula
            # caused option 0 to overlap the lower half of the header — a
            # lower-half-header click would steal the active claim from the
            # header and silently select option 0 instead of closing the
            # dropdown. See regression notes FRAGILE #2.
            # New formula places option 0 at y = rect.y + rect.h, option 1
            # at y + row_h, etc. — visually + behaviorally clean.
            var opt_y = rect.y + rect.h + Float32(i) * row_h
            var opt_rect = Rect(rect.x, opt_y, rect.w, row_h)
            var opt_id = ctx.get_id(String(i))
            var opt_flags = ctx.update_control(opt_id, opt_rect.copy(), OPT_NONE)

            # Per-row background — hover/active highlight, else theme.bg
            # so the dropdown is visually distinct from the header.
            var opt_bg: Color
            if (opt_flags & CTRL_ACTIVE) != 0:
                opt_bg = ctx.theme.active_bg.copy()
            elif (opt_flags & CTRL_HOVERED) != 0:
                opt_bg = ctx.theme.hover_bg.copy()
            else:
                opt_bg = ctx.theme.bg.copy()
            ctx.draw_rect(opt_rect.copy(), opt_bg^)

            # Option text — same baseline calc as header. Same font_id==0
            # guard as the header text — see FRAGILE #5 above.
            if ctx.theme.font_id != 0:
                var opt_text_pos = Vec2(
                    opt_rect.x + Float32(ctx.theme.padding),
                    opt_rect.y
                    + (opt_rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
                )
                ctx.draw_text(
                    ctx.theme.font_id,
                    ctx.theme.font_size_pt,
                    opt_text_pos^,
                    ctx.theme.text.copy(),
                    options[Int(i)],
                )

            # Click-to-select. CTRL_RELEASED on this row → select + close.
            # `changed` only flips True if the new index differs from the
            # previous selected_index (re-click of the already-selected
            # option just closes the dropdown without flagging change).
            if (opt_flags & CTRL_RELEASED) != 0:
                if selected_index != i:
                    selected_index = i
                    changed = True
                is_open = False

            i = i + 1
        ctx.pop_id()
        ctx.end_popup()

    # 6. return — `changed` (True only on the frame an option flipped the
    # selection). Header open/close toggles and re-clicks of the same option
    # both return False — those are not value changes from the caller's POV.
    return changed
