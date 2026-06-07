"""Reusable dense form helpers for trainer-style MojoUI apps."""

from mojoui.core.context import Context
from mojoui.core.textedit import TextEditState
from mojoui.core.types import Vec2, Rect, Color
from mojoui.widgets.basic import separator
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.combobox import combobox
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.progress_bar import progress_bar
from mojoui.widgets.slider import slider
from mojoui.widgets.text_edit import text_edit


def _row1(a: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    return r^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    return r^


def _row3(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    r.append(c)
    return r^


def _draw_border(mut ctx: Context, rect: Rect, color: Color):
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, 1.0), color.copy())
    ctx.draw_rect(Rect(rect.x, rect.y + rect.h - 1.0, rect.w, 1.0), color.copy())
    ctx.draw_rect(Rect(rect.x, rect.y, 1.0, rect.h), color.copy())
    ctx.draw_rect(Rect(rect.x + rect.w - 1.0, rect.y, 1.0, rect.h), color.copy())


def _font_size(ctx: Context, delta: Int32 = 0) -> Int32:
    var size = ctx.theme.font_size_pt + delta
    if size < 10:
        size = 10
    return size


def _fit_text_size(ctx: Context, rect: Rect, text: String, delta: Int32 = 0) -> Int32:
    var size = _font_size(ctx, delta)
    var available = rect.w - Float32(ctx.theme.padding * 2)
    if available < 16.0:
        available = rect.w
    var length = text.byte_length()
    if length <= 0:
        return size
    var estimated = Float32(length) * Float32(size) * 0.54
    while estimated > available and size > 12:
        size = size - 1
        estimated = Float32(length) * Float32(size) * 0.54
    return size


def _draw_slot_text(mut ctx: Context, rect: Rect, text: String, color: Color, inset: Int32 = -1, delta: Int32 = 0):
    if ctx.theme.font_id == 0:
        return
    var size = _fit_text_size(ctx, rect.copy(), text.copy(), delta)
    var pad = ctx.theme.padding
    if inset >= 0:
        pad = inset
    ctx.draw_text(
        ctx.theme.font_id,
        size,
        Vec2(rect.x + Float32(pad), rect.y + (rect.h + Float32(size) * 0.66) * 0.5),
        color,
        text,
    )


def _draw_static_value(mut ctx: Context, rect: Rect, value: String):
    var inner = Rect(rect.x, rect.y + 1.0, rect.w, rect.h - 2.0)
    ctx.draw_rect(inner.copy(), ctx.theme.control_bg.copy())
    _draw_border(ctx, inner.copy(), ctx.theme.border.copy())
    _draw_slot_text(ctx, inner, value, ctx.theme.text.copy(), ctx.theme.padding)


def begin_form_panel(mut ctx: Context, title: String, subtitle: String, pad: Int32 = 14):
    """Consume the next layout slot, draw a panel, and push its inner body."""
    var slot = ctx.layout_next()
    var panel_pad = pad
    if ctx.theme.padding > panel_pad:
        panel_pad = ctx.theme.padding
    var header_h = panel_pad * 3
    var text_header_h = ctx.theme.font_size_pt * 3
    if text_header_h > header_h:
        header_h = text_header_h
    ctx.draw_rect(slot.copy(), ctx.theme.bg.copy())
    _draw_border(ctx, slot.copy(), ctx.theme.border.copy())
    if ctx.theme.font_id != 0:
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(slot.x + Float32(panel_pad), slot.y + Float32(panel_pad) + Float32(ctx.theme.font_size_pt)),
            ctx.theme.text.copy(),
            title,
        )
        if subtitle.byte_length() > 0:
            ctx.draw_text(
                ctx.theme.font_id,
                _font_size(ctx, -3),
                Vec2(slot.x + Float32(panel_pad), slot.y + Float32(panel_pad) + Float32(ctx.theme.font_size_pt) * 2.1),
                ctx.theme.fg.copy(),
                subtitle,
            )
    ctx.draw_rect(
        Rect(slot.x, slot.y + Float32(header_h), slot.w, 1.0),
        ctx.theme.border.copy(),
    )
    var body_h = slot.h - Float32(header_h + panel_pad * 2)
    if body_h < Float32(ctx.theme.row_height):
        body_h = Float32(ctx.theme.row_height)
    ctx.begin_panel(
        Rect(
            slot.x + Float32(panel_pad),
            slot.y + Float32(header_h + panel_pad),
            slot.w - Float32(panel_pad * 2),
            body_h,
        )
    )


def end_form_panel(mut ctx: Context):
    ctx.end_panel()


def form_rule(mut ctx: Context, width: Int32, title: String):
    ctx.layout_row(_row1(width), ctx.theme.row_height)
    var rect = ctx.layout_next()
    _draw_slot_text(ctx, rect, title, ctx.theme.fg.copy(), 0, -1)
    ctx.layout_row(_row1(width), 4)
    separator(ctx)


def field_row(mut ctx: Context, label_w: Int32, value_w: Int32, name: String, value: String):
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    var value_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    _draw_static_value(ctx, value_rect, value)


def edit_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    name: String,
    id_str: String,
    mut value: String,
    mut edit_state: TextEditState,
) raises -> Bool:
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    return text_edit(ctx, id_str, value, edit_state)


def combo_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    name: String,
    id_str: String,
    options: List[String],
    mut selected_index: Int32,
    mut is_open: Bool,
) -> Bool:
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    return combobox(ctx, id_str, options, selected_index, is_open)


def toggle_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    name: String,
    label_text: String,
    mut value: Bool,
) -> Bool:
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    return checkbox(ctx, label_text, value)


def slider_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    name: String,
    id_str: String,
    mut value: Float32,
    low: Float32,
    high: Float32,
) -> Bool:
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    return slider(ctx, value, low, high, id_str)


def drag_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    name: String,
    id_str: String,
    mut value: Float32,
    step: Float32,
) -> Bool:
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    return drag_value(ctx, value, id_str, step)


def pill(mut ctx: Context, text: String, tone: Int32):
    var slot = ctx.layout_next()
    var bg = ctx.theme.control_bg.copy()
    var fg = ctx.theme.text.copy()
    if tone == 1:
        bg = ctx.theme.active_bg.copy()
        fg = ctx.theme.primary.copy()
    elif tone == 2:
        bg = Color(30, 55, 40, 255)
        fg = Color(110, 195, 148, 255)
    elif tone == 3:
        bg = Color(65, 54, 27, 255)
        fg = Color(215, 185, 94, 255)
    elif tone == 4:
        bg = Color(62, 33, 27, 255)
        fg = Color(217, 106, 84, 255)
    ctx.draw_rect(slot.copy(), bg)
    if ctx.theme.font_id != 0:
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt - 2,
            Vec2(slot.x + Float32(ctx.theme.padding), slot.y + (slot.h + Float32(ctx.theme.font_size_pt) * 0.55) * 0.5),
            fg,
            text,
        )


def metric_row(mut ctx: Context, label_w: Int32, value_w: Int32, name: String, value: String):
    field_row(ctx, label_w, value_w, name, value)


def progress_row(mut ctx: Context, label_w: Int32, value_w: Int32, name: String, fraction: Float32):
    ctx.layout_row(_row2(label_w, value_w), ctx.theme.row_height)
    var name_rect = ctx.layout_next()
    _draw_slot_text(ctx, name_rect, name, ctx.theme.fg.copy(), 0, -2)
    progress_bar(ctx, fraction)


def console_line(
    mut ctx: Context,
    time_w: Int32,
    level_w: Int32,
    message_w: Int32,
    time_text: String,
    level_text: String,
    message: String,
    tone: Int32 = 0,
):
    """Dense three-column console/log row for trainer and inference output."""
    ctx.layout_row(_row3(time_w, level_w, message_w), ctx.theme.row_height)
    var time_rect = ctx.layout_next()
    var level_rect = ctx.layout_next()
    var message_rect = ctx.layout_next()
    var bg = Color(8, 7, 6, 255)
    ctx.draw_rect(time_rect.copy(), bg.copy())
    ctx.draw_rect(level_rect.copy(), bg.copy())
    ctx.draw_rect(message_rect.copy(), bg.copy())
    var level_color = ctx.theme.fg.copy()
    if tone == 1:
        level_color = Color(110, 195, 148, 255)
    elif tone == 2:
        level_color = Color(215, 185, 94, 255)
    elif tone == 3:
        level_color = Color(217, 106, 84, 255)
    elif tone == 4:
        level_color = ctx.theme.primary.copy()
    _draw_slot_text(ctx, time_rect, time_text, Color(122, 111, 99, 255), ctx.theme.padding, -3)
    _draw_slot_text(ctx, level_rect, level_text, level_color, 0, -3)
    _draw_slot_text(ctx, message_rect, message, ctx.theme.text.copy(), 0, -3)
