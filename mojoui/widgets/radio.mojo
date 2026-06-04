"""Radio button widget — M2 chunk 20.

A radio button is a mutually-exclusive choice in a group. The group is formed
implicitly by N `radio()` calls sharing the same `mut selected: Int32`
reference: clicking a radio writes its `value` into `selected`, so visually
only the matching one shows as filled.

Microui 6-step recipe (same as `widgets/basic.mojo::button`):

    1. id     = ctx.get_id(label)           # derived from label, NOT value
    2. rect   = ctx.layout_next()
    3. flags  = ctx.update_control(id, rect, OPT_NONE)
    4. behavior — on CTRL_RELEASED, write `value` into `selected`; flag
                   `changed` if the previous value was different.
    5. draw   — outer circle (outline), filled inner dot iff selected == value,
                 label text to the right of the circle.
    6. return — `changed` (True on the single frame the selection flipped TO
                 this radio's value).

ID derivation note: the id is hashed from `label`, NOT from `value`. Labels
are user-meaningful and stable across re-renders; integer `value` collisions
between unrelated radio groups would cause cross-group interaction bleed.
Two radios with the same label under the same id_stack parent WILL collide
— callers needing same-label groups should `ctx.push_id_str("group_name")`
around the group, the standard microui pattern.

`.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Color`/`Rect`/`Vec2`/`DefaultTheme` field reads need explicit `.copy()`. The
implementation threads `.copy()` everywhere required; the test suite catches
any regression by exercising every code path that emits a draw command.

M2 simplification — circle as poor-man's stack of horizontal rects:
The "outer circle" and "inner dot" are drawn as small filled rects centred
vertically in the slot, NOT as proper anti-aliased circles. M3 will swap in
the renderer-adapter's tessellated circle primitive once that lands; the
public API (`radio(ctx, label, value, selected) -> Bool`) is unchanged by
that swap. This keeps M2 in the immediate-mode-loop scope and defers vector
AA to M3 where it belongs.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_FOCUSED,
    CTRL_RELEASED,
    OPT_NONE,
)


# ============================================================================
# radio — mutually-exclusive choice in a shared-`selected` group
# ============================================================================


def radio(
    mut ctx: Context,
    label: String,
    value: Int32,
    mut selected: Int32,
) -> Bool:
    """Radio button. If clicked (CTRL_RELEASED), writes `value` into
    `selected`. Returns True ONLY on the frame the selection actually
    changed (i.e. previous `selected` != `value`); returns False when the
    user re-clicks the already-selected radio.

    Group semantics: multiple `radio()` calls sharing the same `mut
    selected: Int32` form a mutually-exclusive group — clicking one sets
    `selected` to its value, visually only the matching one shows as
    filled (because each radio's draw step compares its `value` to the
    shared `selected`).

    Usage:
        var choice: Int32 = 1
        _ = radio(ctx, "Apple",  1, choice)
        _ = radio(ctx, "Banana", 2, choice)
        _ = radio(ctx, "Cherry", 3, choice)
    """
    # 1. id — from label (user-meaningful, stable across re-renders). Using
    #    `value` as the id source would let unrelated radio groups with the
    #    same integer values collide under the same id_stack parent.
    var id = ctx.get_id(label)

    # 2. rect — next layout slot from the current frame.
    var rect = ctx.layout_next()

    # 3. update_control — the standard interaction tick. Pass rect by
    #    `.copy()` since we need rect again in step 5 for drawing.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4. behavior — on release-inside-active, write our value into the
    #    shared `selected` ref. `changed` flips True only when the
    #    previous selected differed from our value (no-op re-click → False).
    var changed: Bool = False
    if (flags & CTRL_RELEASED) != 0:
        if selected != value:
            selected = value
            changed = True

    # 5. draw — outer circle (poor-man's: small filled rect), inner dot
    #    when selected == value, label text to the right.
    #
    #    Geometry: a 14×14 outer "circle" stub at the left of the slot,
    #    vertically centred. The inner "dot" is a 6×6 filled rect centred
    #    in the outer one. Label text starts at outer_right + padding.

    var outer_size: Float32 = 14.0
    var inner_size: Float32 = 6.0
    # Vertical centre of the slot.
    var cy = rect.y + rect.h * 0.5
    # Outer rect — top-left at (rect.x + padding, cy - outer_size/2).
    var outer_x = rect.x + Float32(ctx.theme.padding)
    var outer_y = cy - outer_size * 0.5

    # Outer "circle" color: border by default, primary when focused. The
    # focus ring uses the same primary token as button's border-on-focus.
    var outer_color: Color
    if (flags & CTRL_FOCUSED) != 0:
        outer_color = ctx.theme.primary.copy()
    elif (flags & CTRL_HOVERED) != 0:
        outer_color = ctx.theme.hover_bg.copy()
    else:
        outer_color = ctx.theme.border.copy()
    ctx.draw_rect(Rect(outer_x, outer_y, outer_size, outer_size), outer_color^)

    # Inner dot — only when this radio matches the shared selection. The
    # comparison uses the CURRENT `selected` (which step 4 may have just
    # written), so a freshly-clicked radio paints filled on the same frame.
    if selected == value:
        var dot_x = outer_x + (outer_size - inner_size) * 0.5
        var dot_y = outer_y + (outer_size - inner_size) * 0.5
        ctx.draw_rect(
            Rect(dot_x, dot_y, inner_size, inner_size),
            ctx.theme.primary.copy(),
        )

    # Label text — to the right of the outer circle, baseline at vertical
    # centre (same calc as button/label in basic.mojo).
    # Caller contract: call `ctx.set_default_font(<id>)` before the frame if
    # the label should render. When `ctx.theme.font_id == 0` the text draw is
    # SKIPPED — see regression notes FRAGILE #5.
    if ctx.theme.font_id != 0:
        var label_pos = Vec2(
            outer_x + outer_size + Float32(ctx.theme.padding),
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            label_pos^,
            ctx.theme.text.copy(),
            label,
        )

    # 6. return — `changed` (True on the single frame the selection flipped).
    return changed
