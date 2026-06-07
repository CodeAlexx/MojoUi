"""DragValue widget — egui's killer interaction for numeric parameter editing.

Click+drag horizontally to scrub a `Float32` by `mouse_delta.x * speed`. Returns
True on any frame the value changed. This is the M2 c22 chunk — the seventh
widget in the MojoUI catalog (per `internal audit notes`
"Widget Catalog" row 7, **MUST v1**), the egui-derived alternative to Slider
for unbounded numeric editing — microui has nothing equivalent. Together with
the M1 button it forms the second pillar of the immediate-mode interaction
vocabulary: button = discrete click event, drag_value = continuous scrub event.

Follows the microui 6-step recipe (same as `widgets/basic.mojo::button` —
`get_id → layout_next → update_control → behavior → draw → return`). The
behavior step is the meat: while CTRL_ACTIVE (i.e. the user is currently
holding the mouse button down after having pressed-inside this widget),
read `ctx.input.mouse_delta.x` and accumulate it into the bound `value` at
the configured `speed` rate.

UX contract:
  - Hover-only: no value change, no return (`False`). The cursor *should*
    be hinted as horizontal-resize but M2 has no cursor-shape FFI yet —
    deferred to M3 (when the C floor grows a `mojoui_set_cursor` export).
  - Press-inside: claims CTRL_ACTIVE via `update_control`. The press frame
    itself has no `mouse_delta.x` contribution (delta is computed at
    `poll()` time and would only reflect motion between the press and the
    immediately-prior frame's mouse position — typically near-zero).
  - Drag-while-active: every frame `value += ctx.input.mouse_delta.x * speed`.
    Returns `True` whenever this delta was non-zero. The delta is consumed
    on the spot — `mouse_delta` is reset each frame by `InputState.poll()`,
    so dropping it on the floor (e.g. by skipping the call) effectively
    discards that frame's scrub.
  - Release: drag stops because `update_control` no longer reports
    CTRL_ACTIVE; value stays at whatever it was at the moment of release.
    No re-snap, no momentum, no clamping (no min/max in this M2 stub —
    egui's `.clamp_range()` extension is a NICE-to-have for v2).

Display:
  - Background rect coloured by state (active_bg > hover_bg > primary),
    same precedence as `widgets/basic.mojo::button`.
  - Value text drawn with `String(value)` — Mojo's default `Float32 -> String`
    drops trailing zeros (`5.0` prints as `5.0`, `5.25` as `5.25`, no
    format-spec like `{:.3f}` available in current beta — see Mojo implementation notes
    "No f-string format-spec for floats"). For M2 we accept the rendering
    quirks; a `_round3` helper is documented in Mojo implementation notes if a future
    chunk wants consistent decimal places.

ID strategy:
  - We need a stable ID per call site. The widget signature takes an
    explicit `id_str: String` to make this contextual-hash-friendly — same
    pattern egui uses (`ui.add(DragValue::new(&mut x).id_source("x"))`).
    Two `drag_value(ctx, value, id_str="x")` calls in different parent
    containers will hash to different IDs via the id_stack, exactly as
    `button(ctx, "OK")` does.

`.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Rect`, `Color`, `Vec2`, `DefaultTheme` are all `Copyable, Movable` but NOT
`ImplicitlyCopyable`. Every read of a field-typed value to pass to another
call needs an explicit `.copy()` — the `rect` from `layout_next` is read
twice (once for `update_control`, once for `draw_rect`), so the second use
gets a `.copy()`.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_ACTIVE, OPT_NONE


# ============================================================================
# drag_value — click+drag horizontally to scrub a Float32
# ============================================================================


def drag_value(
    mut ctx: Context,
    mut value: Float32,
    id_str: String,
    speed: Float32 = 1.0,
) -> Bool:
    """DragValue widget. Returns True iff `value` changed this frame.

    Args:
        ctx:    Per-frame Context (owns layout, control, commands, input, theme).
        value:  Bound numeric value, mutated in place when the user drags.
        id_str: Caller-supplied id seed for contextual hashing — two drag_value
                calls in different containers (or with different id_str) get
                distinct ImmediateIds and interact independently. Pass the
                logical variable name (`"x"`, `"learning_rate"`, etc).
        speed:  Scrub rate in value-units-per-pixel of horizontal mouse motion.
                Default 1.0 means one pixel of motion == one unit of value.
                Set to 0.01 for fine control over small ranges, 10.0 for
                coarse control over large ranges.

    Returns: True if `value` changed this frame (drag was active AND mouse
        moved horizontally), False otherwise (hover-only, idle, or vertical-
        only drag).
    """
    # 1. id — contextual hash off id_stack top + id_str. Two callers with
    #    different id_str (or under different push_id_str parents) hash
    #    to different ImmediateIds.
    var id = ctx.get_id(id_str)

    # 2. rect — next layout slot. Advances the cursor.
    var rect = ctx.layout_next()

    # 3. update_control — run the interaction SM. Returns CTRL_* flag bits.
    #    Pass `rect.copy()` because we re-read `rect` for drawing in step 5.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4. behavior — the scrub. While CTRL_ACTIVE (press-inside still holding),
    #    accumulate horizontal mouse delta into `value` at the configured
    #    speed. `ctx.input.mouse_delta.x` is reset each frame by
    #    `InputState.poll()` so consuming it here is correct — the next
    #    frame will see a fresh delta computed relative to this frame's
    #    mouse_pos.
    #
    #    Float32 is ImplicitlyCopyable so `ctx.input.mouse_delta.x` reads
    #    without `.copy()`. The `changed` flag tracks whether we actually
    #    moved value this frame (so a press-only frame with zero delta
    #    returns False — the click *itself* is not a value change).
    var changed: Bool = False
    if (flags & CTRL_ACTIVE) != 0:
        var dx = ctx.input.mouse_delta.x
        if dx != 0.0:
            value = value + dx * speed
            changed = True

    # 5. draw — state-coloured background + value text.
    #    Theme reads are `.copy()`'d (DefaultTheme fields are Copyable-not-
    #    ImplicitlyCopyable). State precedence: ACTIVE > HOVERED > normal.
    var bg: Color
    if (flags & CTRL_ACTIVE) != 0:
        bg = ctx.theme.active_bg.copy()
    elif (flags & CTRL_HOVERED) != 0:
        bg = ctx.theme.hover_bg.copy()
    else:
        bg = ctx.theme.control_bg.copy()
    ctx.draw_rect(rect.copy(), bg^)

    # Value text — formatted via `String(value)`. Mojo's default Float32 ->
    # String drops trailing zeros, so 5.0 prints as "5.0" and 5.25 as "5.25"
    # — acceptable for M2 (no f-string format-spec in current beta per
    # Mojo implementation notes). Position uses the same baseline-y rough vertical-center
    # as `button` / `label`. No real centering (would need text_width FFI).
    # Caller contract: call `ctx.set_default_font(<id>)` before the frame if
    # the value should render. When `ctx.theme.font_id == 0` the text draw is
    # SKIPPED — see regression notes FRAGILE #5.
    if ctx.theme.font_id != 0:
        var text = String(value)
        var label_pos = Vec2(
            rect.x + Float32(ctx.theme.padding),
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            label_pos^,
            ctx.theme.text.copy(),
            text,
        )

    # 6. return — did value change this frame?
    return changed
