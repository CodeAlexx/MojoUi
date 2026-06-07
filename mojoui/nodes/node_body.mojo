"""Default per-node body renderer — the `draw_body` hook seam.

EriGui's `NodeType` trait exposes a `draw_body` method so each node type
renders its own parameter widgets inside the node rect
(`erigui-widgets/src/node_graph/mod.rs`). MojoUI keeps `NodeTypeDef` as
pure data (`architecture plan` Decision 1), so there is no per-type vtable
to dispatch on. Instead the canvas calls this ONE default body renderer
for every node: it lists the node's `fields` as `name: value` text rows
below the title bar.

This function IS the hook seam. A future app-supplied custom body (a
callback registered per `type_id`) slots in by replacing the
`draw_node_body(...)` call in `canvas.begin_node_canvas` with a dispatch
that falls back to this default when no custom renderer is registered.
Keeping the default here means every node already shows its parameters
(the actual Klein-demo need — seeing a sampler's steps/cfg/seed at a
glance) without any per-type code.

Determinism: field keys render in SORTED order, matching the sorted-key
serde convention (`serde/workflow.mojo`) so the body looks identical
frame-to-frame regardless of `Dict` iteration order.

`raises`: reads `node.fields[key]` (Dict `__getitem__` raises in current
beta — see `serde/workflow.mojo:142`). Callers (`begin_node_canvas`) are
already raising. The font_id == 0 guard short-circuits all `draw_text`
under headless tests (FRAGILE #5).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.nodes.node import (
    Node,
    FieldValue,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
)
from mojoui.render.tessellator import tess_rounded_rect


comptime _BODY_LINE_H: Float32 = 26.0
"""Vertical pitch between field rows (screen px at zoom == 1)."""

comptime _BODY_PAD_X: Float32 = 14.0
"""Left inset of field text from the node's left edge."""

comptime _BODY_PAD_Y: Float32 = 8.0
"""Padding below the title bar before the first field row, and above the
node's bottom edge where rows stop."""

comptime _FIELD_RADIUS: Float32 = 6.0
comptime _FIELD_H: Float32 = 24.0
comptime _FIELD_ARROW_W: Float32 = 18.0


def _sorted_field_keys(node: Node) -> List[String]:
    """Field keys in ascending byte order. Insertion sort — key counts
    are tiny (<50 per node) so O(n^2) is irrelevant. Materializes keys
    into a List first (the c37 Dict-aliasing wall: can't index a Dict by
    a key still borrowing from `.keys()`)."""
    var keys = List[String]()
    for k in node.fields.keys():
        keys.append(k.copy())
    var n = len(keys)
    for i in range(1, n):
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            var tmp = keys[j - 1].copy()
            keys[j - 1] = keys[j].copy()
            keys[j] = tmp^
            j = j - 1
    return keys^


def _field_value_str(fv: FieldValue) -> String:
    """Render a FieldValue as a bare display string (no JSON quoting —
    this is a UI label, not serialization)."""
    if fv.kind == FK_NUMBER:
        return String(fv.num_val)
    elif fv.kind == FK_STRING:
        return fv.str_val.copy()
    elif fv.kind == FK_BOOL:
        if fv.bool_val:
            return String("true")
        return String("false")
    elif fv.kind == FK_INT:
        return String(fv.int_val)
    return String("null")


def _truncate_for_width(text: String, width: Float32, font_size: Int32) -> String:
    if text.byte_length() <= 0:
        return String("")
    var approx_chars = Int(width / (Float32(font_size) * Float32(0.54)))
    if approx_chars < 4:
        approx_chars = 4
    if text.byte_length() <= approx_chars:
        return text.copy()
    var keep = approx_chars - 3
    if keep < 1:
        keep = 1
    if keep > text.byte_length():
        keep = text.byte_length()
    return String(text[byte=0:keep]) + String("...")


def _is_image_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/load_image")
        or node.type_id == String("core/save_image")
        or node.type_id == String("SaveImage")
        or node.type_id == String("core/ideogram4_generate")
    )


def _is_video_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/load_video")
        or node.type_id == String("core/preview_video")
        or node.type_id == String("core/save_video")
    )


def _is_bbox_node(node: Node) -> Bool:
    return node.type_id == String("core/ideogram4_prompt_builder")


def _draw_media_placeholder(
    mut ctx: Context,
    rect: Rect,
    title: String,
    subtitle: String,
    accent: Color,
):
    if rect.w < Float32(72.0) or rect.h < Float32(42.0):
        return
    tess_rounded_rect(ctx, rect.copy(), Float32(7.0), Color(12, 15, 22, 236), 5)
    _draw_field_outline(ctx, rect.copy(), Color(accent.r, accent.g, accent.b, UInt8(190)))
    var image_rect = Rect(
        rect.x + Float32(8.0),
        rect.y + Float32(8.0),
        rect.w - Float32(16.0),
        rect.h - Float32(42.0),
    )
    if image_rect.h < Float32(16.0):
        image_rect.h = Float32(16.0)
    ctx.draw_rect(image_rect.copy(), Color(18, 22, 31, 255))
    var stripe_h = image_rect.h / Float32(5.0)
    for i in range(5):
        var a = UInt8(28 + i * 8)
        ctx.draw_rect(
            Rect(
                image_rect.x,
                image_rect.y + Float32(i) * stripe_h,
                image_rect.w,
                stripe_h,
            ),
            Color(accent.r, accent.g, accent.b, a),
        )
    if ctx.theme.font_id == 0:
        return
    var title_size = ctx.theme.font_size_pt
    var caption_size = title_size - 3
    if caption_size < 10:
        caption_size = 10
    ctx.draw_text(
        ctx.theme.font_id,
        title_size,
        Vec2(rect.x + Float32(12.0), rect.y + rect.h - Float32(24.0)),
        Color(236, 240, 250, 245),
        _truncate_for_width(title.copy(), rect.w - Float32(24.0), title_size),
    )
    if subtitle.byte_length() > 0 and rect.h > Float32(86.0):
        ctx.draw_text(
            ctx.theme.font_id,
            caption_size,
            Vec2(rect.x + Float32(12.0), rect.y + rect.h - Float32(8.0)),
            Color(164, 174, 196, 238),
            _truncate_for_width(subtitle.copy(), rect.w - Float32(24.0), caption_size),
        )


def _draw_bbox_placeholder(mut ctx: Context, rect: Rect):
    if rect.w < Float32(120.0) or rect.h < Float32(72.0):
        return
    tess_rounded_rect(ctx, rect.copy(), Float32(7.0), Color(13, 17, 24, 238), 5)
    _draw_field_outline(ctx, rect.copy(), Color(88, 145, 230, 190))
    var stage = Rect(
        rect.x + Float32(10.0),
        rect.y + Float32(10.0),
        rect.w - Float32(20.0),
        rect.h - Float32(38.0),
    )
    ctx.draw_rect(stage.copy(), Color(18, 23, 34, 255))
    ctx.draw_rect(
        Rect(stage.x, stage.y, stage.w, Float32(1.0)),
        Color(52, 72, 104, 180),
    )
    ctx.draw_rect(
        Rect(stage.x, stage.y + stage.h - Float32(1.0), stage.w, Float32(1.0)),
        Color(52, 72, 104, 180),
    )
    if ctx.theme.font_id != 0:
        var size = ctx.theme.font_size_pt - 2
        if size < 10:
            size = 10
        ctx.draw_text(
            ctx.theme.font_id,
            size,
            Vec2(rect.x + Float32(12.0), rect.y + rect.h - Float32(10.0)),
            Color(180, 196, 225, 240),
            String("bbox composition preview"),
        )


def draw_node_body(
    mut ctx: Context,
    node: Node,
    node_rect: Rect,
    title_h_screen: Float32,
) raises:
    """Render every field of `node` as a `name: value` text row inside the
    node body, below the title bar.

    Args:
        ctx:            Per-frame Context (reads `theme.font_id` /
                        `font_size_pt` / `text`).
        node:           The node whose fields to render.
        node_rect:      The node's SCREEN-space rect (already pan/zoom
                        transformed by the canvas).
        title_h_screen: Screen-space title-bar height (so rows start just
                        below it).

    Rows past the node's bottom edge are not drawn (cheap overflow guard;
    the canvas's viewport CMD_CLIP also clips anything that escapes). No-op
    when `font_id == 0` (headless tests / font not yet loaded).
    """
    if ctx.theme.font_id == 0:
        return
    var body_font = ctx.theme.font_size_pt + 2
    var keys = _sorted_field_keys(node)
    var n = len(keys)
    var x = node_rect.x + _BODY_PAD_X
    var row_w = node_rect.w - _BODY_PAD_X * Float32(2.0)
    if row_w < Float32(24.0):
        return
    var y0 = node_rect.y + title_h_screen + _BODY_PAD_Y
    var max_y = node_rect.y + node_rect.h - _BODY_PAD_Y
    var next_y = y0
    var rendered_rows = 0
    for i in range(n):
        var key = keys[i].copy()
        var fv = node.fields[key].copy()
        if fv.kind == FK_STRING and fv.str_val.byte_length() == 0:
            continue
        var row_y = y0 + Float32(rendered_rows) * (_BODY_LINE_H + Float32(3.0))
        if row_y + _FIELD_H > max_y:
            break
        var label_w = row_w * Float32(0.38)
        if label_w < Float32(78.0):
            label_w = Float32(78.0)
        if label_w > Float32(190.0):
            label_w = Float32(190.0)
        var value_w = row_w - label_w - Float32(12.0)
        if value_w < Float32(24.0):
            value_w = Float32(24.0)
        var key_label = _truncate_for_width(key.copy(), label_w - Float32(12.0), body_font)
        var value_label = _truncate_for_width(_field_value_str(fv), value_w, body_font)
        var pill = Rect(x, row_y, row_w, _FIELD_H)
        tess_rounded_rect(
            ctx,
            pill.copy(),
            _FIELD_RADIUS,
            Color(18, 21, 28, 224),
            4,
        )
        _draw_field_outline(ctx, pill.copy(), Color(78, 88, 112, 210))
        ctx.draw_rect(
            Rect(
                pill.x + label_w,
                pill.y + Float32(2.0),
                Float32(1.0),
                pill.h - Float32(4.0),
            ),
            Color(72, 78, 96, 240),
        )
        ctx.draw_text(
            ctx.theme.font_id,
            body_font,
            Vec2(x + Float32(9.0), row_y + Float32(17.0)),
            Color(168, 176, 196, 255),
            key_label,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            body_font,
            Vec2(pill.x + label_w + Float32(8.0), row_y + Float32(17.0)),
            Color(232, 235, 244, 255),
            value_label,
        )
        next_y = row_y + _FIELD_H + Float32(10.0)
        rendered_rows = rendered_rows + 1

    var media_rect = Rect(x, next_y + Float32(2.0), row_w, max_y - next_y - Float32(2.0))
    if _is_bbox_node(node):
        _draw_bbox_placeholder(ctx, media_rect.copy())
    elif _is_image_node(node):
        _draw_media_placeholder(
            ctx,
            media_rect.copy(),
            String("IMAGE"),
            String("source / preview"),
            Color(95, 200, 135, 255),
        )
    elif _is_video_node(node):
        _draw_media_placeholder(
            ctx,
            media_rect.copy(),
            String("VIDEO"),
            String("playback preview"),
            Color(85, 180, 245, 255),
        )


def _draw_field_outline(mut ctx: Context, rect: Rect, color: Color):
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, Float32(1.0)), color.copy())
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - Float32(1.0), rect.w, Float32(1.0)),
        color.copy(),
    )
    ctx.draw_rect(Rect(rect.x, rect.y, Float32(1.0), rect.h), color.copy())
    ctx.draw_rect(
        Rect(rect.x + rect.w - Float32(1.0), rect.y, Float32(1.0), rect.h),
        color.copy(),
    )
