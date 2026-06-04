"""Checkbox widget — boolean toggle. M2 chunk 19.

Microui 6-step recipe (same shape as `basic.mojo::button`, c17):
    1. id = ctx.get_id(label)
    2. rect = ctx.layout_next()
    3. flags = ctx.update_control(id, rect, OPT_NONE)
    4. behavior — on CTRL_RELEASED toggle `value`, mark `changed = True`
    5. draw — 16×16 box on the left (filled when value=True) + check-mark
              inset + label text to the right
    6. return — `changed` Bool (True only on the single release frame)

`mut value: Bool` is read AND written — caller stores the boolean state
externally (microui-style, no widget retained state). `Bool` is
`ImplicitlyCopyable` (no `.copy()` needed); Color/Rect/Vec2 reads still
need `.copy()` per MOJO_NOTES.md "Copyable ≠ ImplicitlyCopyable".
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_FOCUSED, CTRL_RELEASED, OPT_NONE


# Visual constants. `comptime` per current beta. Module-private.
comptime _BOX_PX: Float32 = 16.0
"""Square edge length of the checkbox box (px)."""

comptime _CHECK_INSET: Float32 = 3.0
"""Inset of the filled check-mark rect from the box edges (px)."""


def checkbox(mut ctx: Context, label: String, mut value: Bool) -> Bool:
    """Boolean toggle widget. `value` is read AND written. Returns True on
    the frame the user RELEASES the mouse over the widget — at which point
    `value` has already been flipped.

    Layout: 16×16 box on the LEFT of the rect (vertically centered) + label
    text to the right. The full rect is the click target.

    Visual: box bg = theme.primary (on) / hover_bg (hovered) / bg (off);
    box border = theme.primary (focused) / theme.border (else); check mark
    = thin filled rect inside the box when value=True; label = text right
    of the box, baseline aligned.
    """
    # 1. id from the label string under the current id_stack top.
    var id = ctx.get_id(label)

    # 2. layout slot — the whole rect is the click target.
    var rect = ctx.layout_next()

    # 3. update_control — .copy() rect because we need it again for drawing.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4. behavior — CTRL_RELEASED is the click; flip value, mark changed.
    var changed: Bool = False
    if (flags & CTRL_RELEASED) != 0:
        value = not value
        changed = True

    # 5. draw — box geometry first: 16×16 square, left-aligned with padding,
    # vertically centered within rect.h.
    var box_pad: Float32 = Float32(ctx.theme.padding)
    var box_x: Float32 = rect.x + box_pad
    var box_y: Float32 = rect.y + (rect.h - _BOX_PX) * 0.5
    var box = Rect(box_x, box_y, _BOX_PX, _BOX_PX)

    # Box background: primary (on) / hover_bg (hovered) / bg (off).
    var box_bg: Color
    if value:
        box_bg = ctx.theme.primary.copy()
    elif (flags & CTRL_HOVERED) != 0:
        box_bg = ctx.theme.hover_bg.copy()
    else:
        box_bg = ctx.theme.bg.copy()
    ctx.draw_rect(box.copy(), box_bg^)

    # Box border: primary (focused) / border (else).
    var border_color: Color
    if (flags & CTRL_FOCUSED) != 0:
        border_color = ctx.theme.primary.copy()
    else:
        border_color = ctx.theme.border.copy()
    _draw_border(ctx, box.copy(), border_color^, 1.0)

    # Check mark — single inset filled rect when value=True. M3 will swap
    # this for a proper vector check glyph via the AA tessellator.
    if value:
        var check = Rect(
            box_x + _CHECK_INSET,
            box_y + _CHECK_INSET,
            _BOX_PX - 2.0 * _CHECK_INSET,
            _BOX_PX - 2.0 * _CHECK_INSET,
        )
        ctx.draw_rect(check^, ctx.theme.text.copy())

    # Label text — right of the box with one padding gap. Baseline-y mirrors
    # button's vertical-center calc.
    # Caller contract: call `ctx.set_default_font(<id>)` before the frame if
    # the label should render. When `ctx.theme.font_id == 0` the text draw is
    # SKIPPED — see SKEPTIC_FINDINGS_M1_2026-05-28.md FRAGILE #5: emitting
    # CMD_TEXT with font_id=0 would corrupt the M3 renderer adapter's
    # font-id lookup.
    if ctx.theme.font_id != 0:
        var label_x: Float32 = box_x + _BOX_PX + box_pad
        var label_y: Float32 = rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5
        var label_pos = Vec2(label_x, label_y)
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            label_pos^,
            ctx.theme.text.copy(),
            label,
        )

    # 6. return — changed Bool.
    return changed


def _draw_border(mut ctx: Context, rect: Rect, color: Color, thickness: Float32):
    """4-thin-rects rectangular outline. Mirrors basic.mojo::_draw_border;
    kept private to avoid cross-module coupling between widget files. Proper
    AA outline drawing arrives with the M3 tessellator. Color is read 4× via
    `.copy()` (Color is Copyable-not-ImplicitlyCopyable)."""
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    ctx.draw_rect(
        Rect(rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness),
        color.copy(),
    )
    ctx.draw_rect(
        Rect(
            rect.x + rect.w - thickness,
            rect.y + thickness,
            thickness,
            rect.h - 2.0 * thickness,
        ),
        color.copy(),
    )
