"""Reusable media preview controls for node bodies.

The graph layer stays pure data; apps load thumbnails/textures through
`Backend.load_texture_file_info` or `Backend.load_video_thumbnail_info`, then
pass the texture id into this module while drawing a custom node body.
"""

from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_ACTIVE,
    CTRL_HOVERED,
    CTRL_PRESSED,
    CTRL_RELEASED,
    OPT_FOCUSABLE,
)
from mojoui.core.types import Vec2, Rect, Color
from mojoui.widgets.image import (
    ImageOverlayBox,
    draw_image_box_overlays,
    image_box_hit_test,
    image_fit_rect,
    image_rect_fit,
    image_rect_fit_boxes,
)


comptime NODE_MEDIA_NONE: Int32 = 0
comptime NODE_MEDIA_PREVIEW: Int32 = 1
comptime NODE_MEDIA_PLAY: Int32 = 2
comptime NODE_MEDIA_BOX: Int32 = 3


struct NodeMediaPreview(Copyable, Movable):
    """Drawable media payload for a node-body preview card."""

    var texture_id: UInt32
    var image_width: Int32
    var image_height: Int32
    var title: String
    var subtitle: String
    var media_path: String
    var is_video: Bool

    def __init__(out self):
        self.texture_id = UInt32(0)
        self.image_width = 0
        self.image_height = 0
        self.title = String("")
        self.subtitle = String("")
        self.media_path = String("")
        self.is_video = False

    def __init__(
        out self,
        texture_id: UInt32,
        image_width: Int32,
        image_height: Int32,
        title: String,
        subtitle: String,
        media_path: String,
        is_video: Bool,
    ):
        self.texture_id = texture_id
        self.image_width = image_width
        self.image_height = image_height
        self.title = title.copy()
        self.subtitle = subtitle.copy()
        self.media_path = media_path.copy()
        self.is_video = is_video


struct NodeImagePreviewAction(Copyable, Movable):
    """Result from an image-node preview draw."""

    var action: Int32
    var box_id: Int64
    var fitted_rect: Rect

    def __init__(out self):
        self.action = NODE_MEDIA_NONE
        self.box_id = Int64(-1)
        self.fitted_rect = Rect()

    def __init__(out self, action: Int32, box_id: Int64, fitted_rect: Rect):
        self.action = action
        self.box_id = box_id
        self.fitted_rect = fitted_rect.copy()


def _draw_preview_border(mut ctx: Context, rect: Rect, color: Color):
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


def _text_w_est(text: String, size_pt: Int32) -> Float32:
    return Float32(text.byte_length()) * Float32(size_pt) * Float32(0.52)


def _truncate_for_width(text: String, width: Float32, font_size: Int32) -> String:
    if text.byte_length() <= 0:
        return String("")
    var approx_chars = Int(width / (Float32(font_size) * Float32(0.56)))
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


def _draw_video_badge(mut ctx: Context, rect: Rect):
    var badge_w = Float32(48.0)
    var badge_h = Float32(18.0)
    if badge_w > rect.w - Float32(8.0):
        badge_w = rect.w - Float32(8.0)
    if badge_h > rect.h - Float32(8.0):
        badge_h = rect.h - Float32(8.0)
    if badge_w <= Float32(18.0) or badge_h <= Float32(10.0):
        return
    var badge = Rect(
        rect.x + rect.w - badge_w - Float32(5.0),
        rect.y + Float32(5.0),
        badge_w,
        badge_h,
    )
    ctx.draw_rect(badge.copy(), Color(7, 8, 12, 226))
    _draw_preview_border(ctx, badge.copy(), Color(90, 170, 240, 230))
    if ctx.theme.font_id != UInt32(0):
        var size = ctx.theme.font_size_pt - 7
        if size < 9:
            size = 9
        ctx.draw_text(
            ctx.theme.font_id,
            size,
            Vec2(
                badge.x + Float32(5.0),
                badge.y + (badge.h + Float32(size) * Float32(0.64)) * Float32(0.5),
            ),
            Color(220, 236, 255, 245),
            String("VIDEO"),
        )


def draw_node_media_preview(
    mut ctx: Context,
    id_str: String,
    rect: Rect,
    preview: NodeMediaPreview,
) -> Int32:
    """Draw a clickable media thumbnail inside an explicit node-body rect.

    Returns:
      - NODE_MEDIA_NONE: no action
      - NODE_MEDIA_PREVIEW: card clicked; caller can open a lightbox
      - NODE_MEDIA_PLAY: video play button clicked; caller can open/play path
    """
    if rect.w <= Float32(8.0) or rect.h <= Float32(8.0):
        return NODE_MEDIA_NONE

    var card_id = ctx.get_id(id_str)
    var card_flags = ctx.update_control(card_id, rect.copy(), OPT_FOCUSABLE)
    var bg = Color(19, 21, 28, 238)
    var border = Color(86, 90, 112, 210)
    if (card_flags & CTRL_HOVERED) != 0:
        bg = Color(28, 31, 40, 244)
        border = ctx.theme.primary.copy()
    if (card_flags & CTRL_ACTIVE) != 0:
        bg = Color(34, 37, 48, 248)
        border = ctx.theme.primary_hover.copy()
    ctx.draw_rect(rect.copy(), bg)
    _draw_preview_border(ctx, rect.copy(), border.copy())

    var pad = Float32(6.0)
    var caption_h = Float32(30.0)
    if rect.h < Float32(80.0):
        caption_h = Float32(18.0)
    var image_rect = Rect(
        rect.x + pad,
        rect.y + pad,
        rect.w - pad * Float32(2.0),
        rect.h - caption_h - pad * Float32(2.0),
    )
    if image_rect.h < Float32(12.0):
        image_rect.h = Float32(12.0)
    if preview.texture_id == UInt32(0):
        ctx.draw_rect(image_rect.copy(), Color(12, 14, 20, 255))
    else:
        image_rect_fit(
            ctx,
            image_rect.copy(),
            preview.texture_id,
            preview.image_width,
            preview.image_height,
            Color(255, 255, 255, 255),
        )
    if preview.is_video:
        _draw_video_badge(ctx, image_rect.copy())

    var play_flags: Int32 = 0
    if preview.is_video:
        var play_size = Float32(34.0)
        if play_size > image_rect.w - Float32(12.0):
            play_size = image_rect.w - Float32(12.0)
        if play_size > image_rect.h - Float32(12.0):
            play_size = image_rect.h - Float32(12.0)
        if play_size > Float32(14.0):
            var play_rect = Rect(
                image_rect.x + (image_rect.w - play_size) * Float32(0.5),
                image_rect.y + (image_rect.h - play_size) * Float32(0.5),
                play_size,
                play_size,
            )
            var play_id = ctx.get_id(id_str + String("_play"))
            play_flags = ctx.update_control(play_id, play_rect.copy(), OPT_FOCUSABLE)
            var play_bg = Color(20, 23, 31, 214)
            if (play_flags & CTRL_HOVERED) != 0:
                play_bg = Color(44, 51, 68, 230)
            if (play_flags & CTRL_ACTIVE) != 0:
                play_bg = Color(58, 70, 94, 242)
            ctx.draw_rect(play_rect.copy(), play_bg)
            _draw_preview_border(ctx, play_rect.copy(), Color(190, 220, 255, 220))
            if ctx.theme.font_id != UInt32(0):
                var size = ctx.theme.font_size_pt + 2
                ctx.draw_text(
                    ctx.theme.font_id,
                    size,
                    Vec2(
                        play_rect.x + play_rect.w * Float32(0.38),
                        play_rect.y + (play_rect.h + Float32(size) * Float32(0.62)) * Float32(0.5),
                    ),
                    Color(238, 246, 255, 245),
                    String(">"),
                )

    if ctx.theme.font_id != UInt32(0):
        var title_size = ctx.theme.font_size_pt - 4
        if title_size < 10:
            title_size = 10
        var title_text = _truncate_for_width(
            preview.title.copy(),
            rect.w - pad * Float32(2.0),
            title_size,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            title_size,
            Vec2(rect.x + pad, rect.y + rect.h - Float32(15.0)),
            Color(232, 235, 245, 245),
            title_text,
        )
        if preview.subtitle.byte_length() > 0 and rect.h >= Float32(92.0):
            var sub_size = ctx.theme.font_size_pt - 7
            if sub_size < 9:
                sub_size = 9
            var subtitle = _truncate_for_width(
                preview.subtitle.copy(),
                rect.w - pad * Float32(2.0),
                sub_size,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                sub_size,
                Vec2(rect.x + pad, rect.y + rect.h - Float32(4.0)),
                Color(160, 168, 185, 235),
                subtitle,
            )

    if preview.is_video and ((play_flags & CTRL_RELEASED) != 0 or (play_flags & CTRL_PRESSED) != 0):
        return NODE_MEDIA_PLAY
    if (card_flags & CTRL_RELEASED) != 0 or (card_flags & CTRL_PRESSED) != 0:
        return NODE_MEDIA_PREVIEW
    return NODE_MEDIA_NONE


def draw_node_image_preview_boxes(
    mut ctx: Context,
    id_str: String,
    rect: Rect,
    preview: NodeMediaPreview,
    boxes: List[ImageOverlayBox],
) -> NodeImagePreviewAction:
    """Draw an image-node preview with source-pixel annotation boxes.

    Returns `NODE_MEDIA_BOX` plus the clicked box id when a region is clicked;
    otherwise returns the same preview/no-op actions as `draw_node_media_preview`.
    """
    if rect.w <= Float32(8.0) or rect.h <= Float32(8.0):
        return NodeImagePreviewAction()

    var card_id = ctx.get_id(id_str)
    var card_flags = ctx.update_control(card_id, rect.copy(), OPT_FOCUSABLE)
    var bg = Color(19, 21, 28, 238)
    var border = Color(86, 90, 112, 210)
    if (card_flags & CTRL_HOVERED) != 0:
        bg = Color(28, 31, 40, 244)
        border = ctx.theme.primary.copy()
    if (card_flags & CTRL_ACTIVE) != 0:
        bg = Color(34, 37, 48, 248)
        border = ctx.theme.primary_hover.copy()
    ctx.draw_rect(rect.copy(), bg)
    _draw_preview_border(ctx, rect.copy(), border.copy())

    var pad = Float32(6.0)
    var caption_h = Float32(30.0)
    if rect.h < Float32(80.0):
        caption_h = Float32(18.0)
    var image_rect = Rect(
        rect.x + pad,
        rect.y + pad,
        rect.w - pad * Float32(2.0),
        rect.h - caption_h - pad * Float32(2.0),
    )
    if image_rect.h < Float32(12.0):
        image_rect.h = Float32(12.0)

    var fitted = image_fit_rect(
        image_rect.copy(),
        preview.image_width,
        preview.image_height,
    )
    if preview.texture_id == UInt32(0):
        ctx.draw_rect(fitted.copy(), Color(12, 14, 20, 255))
    else:
        fitted = image_rect_fit_boxes(
            ctx,
            image_rect.copy(),
            preview.texture_id,
            preview.image_width,
            preview.image_height,
            boxes,
            Color(255, 255, 255, 255),
        )
    if preview.texture_id == UInt32(0):
        # Still draw boxes on the placeholder so image-to-prompt data can be
        # inspected before a texture is loaded.
        draw_image_box_overlays(
            ctx,
            fitted.copy(),
            preview.image_width,
            preview.image_height,
            boxes,
        )

    if ctx.theme.font_id != UInt32(0):
        var title_size = ctx.theme.font_size_pt - 4
        if title_size < 10:
            title_size = 10
        var title_text = _truncate_for_width(
            preview.title.copy(),
            rect.w - pad * Float32(2.0),
            title_size,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            title_size,
            Vec2(rect.x + pad, rect.y + rect.h - Float32(15.0)),
            Color(232, 235, 245, 245),
            title_text,
        )
        if preview.subtitle.byte_length() > 0 and rect.h >= Float32(92.0):
            var sub_size = ctx.theme.font_size_pt - 7
            if sub_size < 9:
                sub_size = 9
            var subtitle = _truncate_for_width(
                preview.subtitle.copy(),
                rect.w - pad * Float32(2.0),
                sub_size,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                sub_size,
                Vec2(rect.x + pad, rect.y + rect.h - Float32(4.0)),
                Color(160, 168, 185, 235),
                subtitle,
            )

    var box_id = image_box_hit_test(
        fitted.copy(),
        preview.image_width,
        preview.image_height,
        boxes,
        ctx.control.mouse_pos.copy(),
    )
    if ((card_flags & CTRL_RELEASED) != 0 or (card_flags & CTRL_PRESSED) != 0) and box_id >= Int64(0):
        return NodeImagePreviewAction(NODE_MEDIA_BOX, box_id, fitted.copy())
    if (card_flags & CTRL_RELEASED) != 0 or (card_flags & CTRL_PRESSED) != 0:
        return NodeImagePreviewAction(NODE_MEDIA_PREVIEW, Int64(-1), fitted.copy())
    return NodeImagePreviewAction(NODE_MEDIA_NONE, Int64(-1), fitted.copy())


def draw_node_video_preview(
    mut ctx: Context,
    id_str: String,
    rect: Rect,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    media_path: String,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
) -> Int32:
    """Convenience wrapper for a video thumbnail node preview."""
    var preview = NodeMediaPreview(
        texture_id,
        image_width,
        image_height,
        title,
        subtitle,
        media_path,
        True,
    )
    return draw_node_media_preview(ctx, id_str, rect, preview)
