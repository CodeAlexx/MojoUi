"""Image widget — display-only textured rect. M2 chunk 27.

The image widget is the simplest of the display-only widgets: it consumes a
layout slot (so subsequent widgets flow past it) and emits a single
`CMD_IMAGE` command that the renderer adapter (M3) will dispatch to
`Backend.draw_image` (textured-quad path through sokol_gfx with the
texture id from `Backend.make_texture` / the C-floor `mojoui_make_texture`).

Three entry points (sized to match the three call-site shapes M2/M2.5 needs):

  * `image(ctx, texture_id)`           — fills the next layout slot with the
                                          texture, white tint (no modulation).
  * `image_tinted(ctx, texture_id, tint)` — same as above with an explicit
                                          per-texel colour modulation (texel
                                          * tint, premultiplied alpha on the
                                          renderer side in M3).
  * `image_rect(ctx, rect, texture_id, tint)` — paints at an EXPLICIT rect
                                          that does NOT consume a layout slot.
                                          Used by the M2.5 node-graph canvas
                                          to draw socket icons at arbitrary
                                          positions inside a single canvas
                                          layout slot.

For M2 simplicity the image always stretches to fill the slot — no
preserve-aspect, no inset, no nine-slice. Aspect-preserving paint lands in
M3 alongside the proper sampler/scissor wiring (the texture's natural size
isn't known at the widget level yet — `Backend.texture_size(id)` is an M3
extension on the FFI surface).

There is NO `update_control` call on this widget — like `label`/`separator`
in `basic.mojo`, it never claims hover/focus/active even when the mouse is
over it. If an app needs a clickable image, the convention is to wrap
`image_rect` inside a manual `update_control` block (or to use a real
`image_button` widget, which is deferred).

The `.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Rect` and `Color` are `Copyable, Movable` but NOT `ImplicitlyCopyable`.
Every read of a function parameter into another call needs explicit
`.copy()` — the body below threads `.copy()` wherever required.
"""

from mojoui.core.context import Context
from mojoui.core.control import CTRL_ACTIVE, CTRL_HOVERED, CTRL_PRESSED, CTRL_RELEASED, OPT_FOCUSABLE, OPT_NONE
from mojoui.core.types import Vec2, Rect, Color


comptime MEDIA_LIGHTBOX_OPEN: Int32 = 0
comptime MEDIA_LIGHTBOX_CLOSE: Int32 = 1
comptime MEDIA_LIGHTBOX_PLAY: Int32 = 2


# ============================================================================
# image — white-tint convenience (no colour modulation by default)
# ============================================================================


def image(mut ctx: Context, texture_id: UInt32):
    """Display-only textured rect. `texture_id` comes from
    `Backend.make_texture` / the C-floor `mojoui_make_texture` entry point.

    Allocates the next layout slot and emits a `CMD_IMAGE` painting that slot
    with the texture and a fully-opaque white tint (texel * white == texel,
    so the texture's own colours pass through unchanged).

    The image fills the slot by stretching — no preserve-aspect mode in M2.
    """
    # 1. layout_next — reserve the next slot from the current row/column flow.
    var rect = ctx.layout_next()

    # 2. (no id — display-only, no update_control invocation)

    # 3. draw — emit a CMD_IMAGE with white tint (no per-pixel modulation).
    #    Local `tint` then `.copy()` into emit_image is the canonical pattern
    #    for Color values per Mojo implementation notes (Color is Copyable-not-
    #    ImplicitlyCopyable, so the read of `tint` for the call needs .copy()).
    var tint = Color(255, 255, 255, 255)
    ctx.draw_image(rect.copy(), texture_id, tint.copy())


# ============================================================================
# image_tinted — explicit per-pixel colour modulation
# ============================================================================


def image_tinted(mut ctx: Context, texture_id: UInt32, tint: Color):
    """Tinted image — paints the next layout slot with `texture_id` and
    multiplies each texel by `tint` (so tint=(255,0,0,255) produces a red-
    only channel pass-through, tint=(255,255,255,128) is a 50%-alpha overlay,
    etc.).

    Identical to `image()` but exposes the tint colour. The two are kept
    separate because the white-tint case is so common at call sites that
    forcing every caller to construct an explicit `Color(255,255,255,255)`
    is noise.
    """
    var rect = ctx.layout_next()
    ctx.draw_image(rect.copy(), texture_id, tint.copy())


# ============================================================================
# image_rect — explicit rect, does NOT consume a layout slot
# ============================================================================


def image_rect(mut ctx: Context, rect: Rect, texture_id: UInt32, tint: Color):
    """Image at an EXPLICIT screen-space rect. Does NOT call `layout_next` —
    the caller has already computed the rect themselves (typically by adding
    an offset to the parent's already-claimed canvas rect).

    Used by the M2.5 node-graph canvas to draw socket icons and node-header
    glyphs at arbitrary positions inside ONE container layout slot. Also
    useful for sprite-style overlays on top of other widgets (the renderer
    walks commands in emit order, so a later `image_rect` paints on top).
    """
    ctx.draw_image(rect.copy(), texture_id, tint.copy())


def _fit_rect(bounds: Rect, image_width: Int32, image_height: Int32) -> Rect:
    if image_width <= 0 or image_height <= 0 or bounds.w <= 0.0 or bounds.h <= 0.0:
        return bounds.copy()
    var iw = Float32(image_width)
    var ih = Float32(image_height)
    var scale = bounds.w / iw
    var scale_h = bounds.h / ih
    if scale_h < scale:
        scale = scale_h
    var draw_w = iw * scale
    var draw_h = ih * scale
    return Rect(
        bounds.x + (bounds.w - draw_w) * 0.5,
        bounds.y + (bounds.h - draw_h) * 0.5,
        draw_w,
        draw_h,
    )


def image_rect_fit(
    mut ctx: Context,
    rect: Rect,
    texture_id: UInt32,
    image_width: Int32,
    image_height: Int32,
    tint: Color,
):
    """Image at an explicit rect, preserving source aspect ratio when the
    decoded texture dimensions are known."""
    var draw_rect = _fit_rect(rect.copy(), image_width, image_height)
    ctx.draw_image(draw_rect.copy(), texture_id, tint.copy())


def _draw_preview_border(mut ctx: Context, slot: Rect, color: Color):
    ctx.draw_rect(Rect(slot.x, slot.y, slot.w, 1.0), color.copy())
    ctx.draw_rect(Rect(slot.x, slot.y + slot.h - 1.0, slot.w, 1.0), color.copy())
    ctx.draw_rect(Rect(slot.x, slot.y, 1.0, slot.h), color.copy())
    ctx.draw_rect(Rect(slot.x + slot.w - 1.0, slot.y, 1.0, slot.h), color.copy())


def _draw_video_badge(mut ctx: Context, rect: Rect):
    var w = Float32(ctx.theme.font_size_pt * 3 + ctx.theme.padding * 2)
    var h = Float32(ctx.theme.row_height)
    if w > rect.w - 8.0:
        w = rect.w - 8.0
    if h > rect.h - 8.0:
        h = rect.h - 8.0
    if w <= 20.0 or h <= 12.0:
        return
    var badge = Rect(rect.x + rect.w - w - 6.0, rect.y + 6.0, w, h)
    ctx.draw_rect(badge.copy(), Color(8, 7, 6, 220))
    _draw_preview_border(ctx, badge.copy(), ctx.theme.primary.copy())
    if ctx.theme.font_id != 0:
        var size = ctx.theme.font_size_pt - 6
        if size < 10:
            size = 10
        ctx.draw_text(
            ctx.theme.font_id,
            size,
            Vec2(badge.x + Float32(ctx.theme.padding), badge.y + (badge.h + Float32(size) * 0.64) * 0.5),
            ctx.theme.primary.copy(),
            String("VIDEO"),
        )


def _truncate_for_width(text: String, width: Float32, font_size: Int32) -> String:
    if text.byte_length() <= 0:
        return String("")
    var approx_chars = Int(width / (Float32(font_size) * 0.56))
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


def _draw_grid_scrollbar(
    mut ctx: Context,
    viewport: Rect,
    scroll_y: Float32,
    max_scroll: Float32,
):
    if max_scroll <= 0.0 or viewport.h <= 24.0:
        return
    var track_w: Float32 = 4.0
    var track = Rect(
        viewport.x + viewport.w - track_w - 2.0,
        viewport.y + 2.0,
        track_w,
        viewport.h - 4.0,
    )
    ctx.draw_rect(track.copy(), ctx.theme.border.copy())
    var ratio = viewport.h / (viewport.h + max_scroll)
    var thumb_h = track.h * ratio
    if thumb_h < 32.0:
        thumb_h = 32.0
    if thumb_h > track.h:
        thumb_h = track.h
    var thumb_y = track.y
    if max_scroll > 0.0:
        thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll)
    ctx.draw_rect(Rect(track.x, thumb_y, track.w, thumb_h), ctx.theme.primary.copy())


def _draw_preview_card_body(
    mut ctx: Context,
    slot: Rect,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    hovered: Bool = False,
    active: Bool = False,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
    is_video: Bool = False,
):
    var bg = ctx.theme.bg.copy()
    if hovered:
        bg = ctx.theme.hover_bg.copy()
    if active:
        bg = ctx.theme.active_bg.copy()
    ctx.draw_rect(slot.copy(), bg)
    var border = ctx.theme.border.copy()
    if hovered or active:
        border = ctx.theme.primary.copy()
    _draw_preview_border(ctx, slot.copy(), border.copy())

    var pad = Float32(ctx.theme.padding)
    var caption_h = Float32(ctx.theme.row_height) * 1.35
    var preview_rect = Rect(
        slot.x + pad,
        slot.y + pad,
        slot.w - pad * 2.0,
        slot.h - caption_h - pad * 2.0,
    )
    if preview_rect.h < 10.0:
        preview_rect.h = 10.0
    if texture_id == UInt32(0):
        ctx.draw_rect(preview_rect.copy(), ctx.theme.control_bg.copy())
    else:
        image_rect_fit(
            ctx,
            preview_rect.copy(),
            texture_id,
            image_width,
            image_height,
            Color(255, 255, 255, 255),
        )
    if is_video:
        _draw_video_badge(ctx, preview_rect.copy())

    if ctx.theme.font_id != 0:
        var title_size = ctx.theme.font_size_pt - 4
        if title_size < 12:
            title_size = 12
        var title_text = _truncate_for_width(
            title.copy(),
            slot.w - pad * 2.0,
            title_size,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            title_size,
            Vec2(slot.x + pad, slot.y + slot.h - caption_h + Float32(title_size) * 1.1),
            ctx.theme.text.copy(),
            title_text,
        )
        if subtitle.byte_length() > 0:
            var sub_size = ctx.theme.font_size_pt - 8
            if sub_size < 10:
                sub_size = 10
            var subtitle_text = _truncate_for_width(
                subtitle.copy(),
                slot.w - pad * 2.0,
                sub_size,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                sub_size,
                Vec2(slot.x + pad, slot.y + slot.h - pad),
                ctx.theme.fg.copy(),
                subtitle_text,
            )


def image_preview_card(mut ctx: Context, texture_id: UInt32, title: String, subtitle: String):
    """Framed image preview card for dataset/sample/gallery surfaces."""
    var slot = ctx.layout_next()
    _draw_preview_card_body(ctx, slot.copy(), texture_id, title, subtitle)


def media_preview_card(
    mut ctx: Context,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
    is_video: Bool = False,
):
    """Framed media preview card with an optional video badge."""
    var slot = ctx.layout_next()
    _draw_preview_card_body(
        ctx,
        slot.copy(),
        texture_id,
        title,
        subtitle,
        False,
        False,
        image_width,
        image_height,
        is_video,
    )


def image_preview_button(
    mut ctx: Context,
    id_str: String,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
    is_video: Bool = False,
) -> Bool:
    """Clickable framed image preview card. Returns True on click."""
    var slot = ctx.layout_next()
    var id = ctx.get_id(id_str)
    var flags = ctx.update_control(id, slot.copy(), OPT_FOCUSABLE)
    _draw_preview_card_body(
        ctx,
        slot.copy(),
        texture_id,
        title,
        subtitle,
        (flags & CTRL_HOVERED) != 0,
        (flags & CTRL_ACTIVE) != 0,
        image_width,
        image_height,
        is_video,
    )
    return (flags & CTRL_RELEASED) != 0 or (flags & CTRL_PRESSED) != 0


def media_virtual_grid(
    mut ctx: Context,
    id_str: String,
    viewport_height: Int32,
    columns: Int32,
    cell_width: Int32,
    cell_height: Int32,
    total_count: Int32,
    mut scroll_y: Float32,
    textures: List[UInt32],
    widths: List[Int32],
    heights: List[Int32],
    titles: List[String],
    subtitles: List[String],
    is_videos: List[Bool],
) -> Int32:
    """Virtualized preview grid for large mixed-media folders. Only visible rows
    are drawn and hit-tested. Returns the clicked item index, or -1."""
    var cols = columns
    if cols < 1:
        cols = 1
    var count = total_count
    if count < 0:
        count = 0
    var gap = ctx.theme.spacing
    if gap < 6:
        gap = 6
    var row_pitch = cell_height + gap
    if row_pitch < 1:
        row_pitch = 1
    var total_rows = (count + cols - 1) // cols
    var content_h = total_rows * row_pitch
    var max_scroll = Float32(content_h - viewport_height)
    if max_scroll < 0.0:
        max_scroll = 0.0

    var outer = ctx.layout_next()
    var viewport = Rect(outer.x, outer.y, outer.w, Float32(viewport_height))
    ctx.draw_rect(viewport.copy(), ctx.theme.bg.copy())
    _draw_preview_border(ctx, viewport.copy(), ctx.theme.border.copy())

    var grid_id = ctx.get_id(id_str)
    var grid_flags = ctx.update_control(grid_id, viewport.copy(), OPT_NONE)
    if (grid_flags & CTRL_ACTIVE) != 0:
        var dy = ctx.input.mouse_delta.y
        if dy != 0.0:
            scroll_y = scroll_y - dy
    if (grid_flags & CTRL_HOVERED) != 0:
        var wheel_y = ctx.input.scroll_delta.y
        if wheel_y != 0.0:
            scroll_y = scroll_y - wheel_y * 96.0
    if scroll_y < 0.0:
        scroll_y = 0.0
    if scroll_y > max_scroll:
        scroll_y = max_scroll

    var start_row = Int(scroll_y / Float32(row_pitch))
    if start_row < 0:
        start_row = 0
    var visible_rows = Int(viewport_height // row_pitch) + 3
    if visible_rows < 3:
        visible_rows = 3
    var end_row = start_row + visible_rows
    if end_row > Int(total_rows):
        end_row = Int(total_rows)

    ctx.draw_clip(viewport.copy())
    ctx.push_id_str(id_str)
    var clicked: Int32 = -1
    for row in range(start_row, end_row):
        for col in range(Int(cols)):
            var idx = row * Int(cols) + col
            if idx >= Int(count):
                break
            var cell_x = viewport.x + Float32(col * Int(cell_width + gap))
            var cell_y = viewport.y - scroll_y + Float32(row * Int(row_pitch))
            var slot = Rect(cell_x, cell_y, Float32(cell_width), Float32(cell_height))
            var tex = UInt32(0)
            var iw: Int32 = 0
            var ih: Int32 = 0
            var title = String("Image ") + String(idx + 1)
            var subtitle = String("")
            if idx < len(textures):
                tex = textures[idx]
            if idx < len(widths):
                iw = widths[idx]
            if idx < len(heights):
                ih = heights[idx]
            if idx < len(titles):
                title = titles[idx].copy()
            if idx < len(subtitles):
                subtitle = subtitles[idx].copy()
            var is_video = False
            if idx < len(is_videos):
                is_video = is_videos[idx]
            var cell_id = ctx.get_id(String("item_") + String(idx))
            var flags = ctx.update_control(cell_id, slot.copy(), OPT_FOCUSABLE)
            _draw_preview_card_body(
                ctx,
                slot.copy(),
                tex,
                title,
                subtitle,
                (flags & CTRL_HOVERED) != 0,
                (flags & CTRL_ACTIVE) != 0,
                iw,
                ih,
                is_video,
            )
            if (flags & CTRL_RELEASED) != 0 or (flags & CTRL_PRESSED) != 0:
                clicked = Int32(idx)
    ctx.pop_id()
    ctx.draw_clip(ctx.window_rect.copy())
    _draw_grid_scrollbar(ctx, viewport.copy(), scroll_y, max_scroll)
    if ctx.theme.font_id != 0 and count > 0:
        var first = start_row * Int(cols) + 1
        var last = end_row * Int(cols)
        if last > Int(count):
            last = Int(count)
        var status_size = ctx.theme.font_size_pt - 8
        if status_size < 10:
            status_size = 10
        var status = String(first) + String("-") + String(last) + String(" / ") + String(count)
        var status_w = Float32(status.byte_length()) * Float32(status_size) * 0.56
        ctx.draw_rect(
            Rect(
                viewport.x + viewport.w - status_w - Float32(ctx.theme.padding * 2) - 12.0,
                viewport.y + viewport.h - Float32(status_size + ctx.theme.padding * 2),
                status_w + Float32(ctx.theme.padding * 2),
                Float32(status_size + ctx.theme.padding),
            ),
            Color(8, 7, 6, 210),
        )
        ctx.draw_text(
            ctx.theme.font_id,
            status_size,
            Vec2(
                viewport.x + viewport.w - status_w - Float32(ctx.theme.padding) - 12.0,
                viewport.y + viewport.h - Float32(ctx.theme.padding),
            ),
            ctx.theme.text_subdued.copy(),
            status,
        )
    return clicked


def image_virtual_grid(
    mut ctx: Context,
    id_str: String,
    viewport_height: Int32,
    columns: Int32,
    cell_width: Int32,
    cell_height: Int32,
    total_count: Int32,
    mut scroll_y: Float32,
    textures: List[UInt32],
    widths: List[Int32],
    heights: List[Int32],
    titles: List[String],
    subtitles: List[String],
) -> Int32:
    """Virtualized preview grid for image folders. Only visible rows are
    drawn and hit-tested. Returns the clicked item index, or -1."""
    var no_videos = List[Bool]()
    return media_virtual_grid(
        ctx,
        id_str,
        viewport_height,
        columns,
        cell_width,
        cell_height,
        total_count,
        scroll_y,
        textures,
        widths,
        heights,
        titles,
        subtitles,
        no_videos,
    )


def media_lightbox(
    mut ctx: Context,
    id_str: String,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    media_path: String,
    is_video: Bool,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
) -> Int32:
    """Full-window preview overlay for a selected image or video thumbnail.
    Returns MEDIA_LIGHTBOX_* so the caller can close or play a video."""
    var full = ctx.window_rect.copy()
    var panel_w = full.w * 0.72
    var panel_h = full.h * 0.78
    if panel_w < 720.0:
        panel_w = 720.0
    if panel_h < 520.0:
        panel_h = 520.0
    if panel_w > full.w - 80.0:
        panel_w = full.w - 80.0
    if panel_h > full.h - 80.0:
        panel_h = full.h - 80.0
    var panel = Rect(
        full.x + (full.w - panel_w) * 0.5,
        full.y + (full.h - panel_h) * 0.5,
        panel_w,
        panel_h,
    )
    var close_size = Float32(ctx.theme.row_height)
    var close_rect = Rect(
        panel.x + panel.w - close_size - Float32(ctx.theme.padding),
        panel.y + Float32(ctx.theme.padding),
        close_size,
        close_size,
    )
    var play_w = Float32(ctx.theme.font_size_pt * 4 + ctx.theme.padding * 2)
    if play_w < 110.0:
        play_w = 110.0
    var play_rect = Rect(
        close_rect.x - play_w - Float32(ctx.theme.spacing),
        close_rect.y,
        play_w,
        close_size,
    )
    var image_top = panel.y + Float32(ctx.theme.row_height) + Float32(ctx.theme.padding * 2)
    var preview_rect = Rect(
        panel.x + Float32(ctx.theme.padding),
        image_top,
        panel.w - Float32(ctx.theme.padding * 2),
        panel.h - Float32(ctx.theme.row_height * 2 + ctx.theme.padding * 4),
    )
    if preview_rect.h < 120.0:
        preview_rect.h = 120.0

    ctx.begin_popup(full.copy())
    ctx.draw_rect(full.copy(), Color(0, 0, 0, 190))
    ctx.draw_rect(panel.copy(), ctx.theme.bg.copy())
    _draw_preview_border(ctx, panel.copy(), ctx.theme.primary.copy())

    var close_id = ctx.get_id(id_str + String("_close"))
    var close_flags = ctx.update_control(close_id, close_rect.copy(), OPT_FOCUSABLE)
    var close_bg = ctx.theme.control_bg.copy()
    if (close_flags & CTRL_HOVERED) != 0:
        close_bg = ctx.theme.hover_bg.copy()
    if (close_flags & CTRL_ACTIVE) != 0:
        close_bg = ctx.theme.active_bg.copy()
    ctx.draw_rect(close_rect.copy(), close_bg)
    _draw_preview_border(ctx, close_rect.copy(), ctx.theme.border.copy())

    var play_flags: Int32 = 0
    if is_video:
        var play_id = ctx.get_id(id_str + String("_play"))
        play_flags = ctx.update_control(play_id, play_rect.copy(), OPT_FOCUSABLE)
        var play_bg = ctx.theme.primary.copy()
        var play_fg = Color(22, 12, 3, 255)
        if (play_flags & CTRL_HOVERED) != 0:
            play_bg = ctx.theme.active_bg.copy()
            play_fg = ctx.theme.text.copy()
        if (play_flags & CTRL_ACTIVE) != 0:
            play_bg = ctx.theme.hover_bg.copy()
            play_fg = ctx.theme.text.copy()
        ctx.draw_rect(play_rect.copy(), play_bg)
        _draw_preview_border(ctx, play_rect.copy(), ctx.theme.border.copy())
        if ctx.theme.font_id != 0:
            var play_size = ctx.theme.font_size_pt - 2
            if play_size < 12:
                play_size = 12
            ctx.draw_text(
                ctx.theme.font_id,
                play_size,
                Vec2(play_rect.x + Float32(ctx.theme.padding), play_rect.y + (play_rect.h + Float32(play_size) * 0.64) * 0.5),
                play_fg,
                String("Play"),
            )

    if texture_id == UInt32(0):
        ctx.draw_rect(preview_rect.copy(), ctx.theme.control_bg.copy())
    else:
        image_rect_fit(
            ctx,
            preview_rect.copy(),
            texture_id,
            image_width,
            image_height,
            Color(255, 255, 255, 255),
        )
    if is_video:
        _draw_video_badge(ctx, preview_rect.copy())

    if ctx.theme.font_id != 0:
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(panel.x + Float32(ctx.theme.padding), panel.y + Float32(ctx.theme.padding) + Float32(ctx.theme.font_size_pt)),
            ctx.theme.text.copy(),
            title,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(close_rect.x + Float32(ctx.theme.padding), close_rect.y + (close_rect.h + Float32(ctx.theme.font_size_pt) * 0.64) * 0.5),
            ctx.theme.text.copy(),
            String("X"),
        )
        var bottom_text = subtitle.copy()
        if is_video and media_path.byte_length() > 0:
            bottom_text = media_path.copy()
        if bottom_text.byte_length() > 0:
            var sub_size = ctx.theme.font_size_pt - 6
            if sub_size < 12:
                sub_size = 12
            var bottom_fit = _truncate_for_width(
                bottom_text.copy(),
                panel.w - Float32(ctx.theme.padding * 2),
                sub_size,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                sub_size,
                Vec2(panel.x + Float32(ctx.theme.padding), panel.y + panel.h - Float32(ctx.theme.padding)),
                ctx.theme.fg.copy(),
                bottom_fit,
            )

    var action = MEDIA_LIGHTBOX_OPEN
    if (close_flags & CTRL_RELEASED) != 0:
        action = MEDIA_LIGHTBOX_CLOSE
    if is_video and (play_flags & CTRL_RELEASED) != 0:
        action = MEDIA_LIGHTBOX_PLAY
    if ctx.input.mouse_released(0) and not panel.contains(ctx.input.mouse_pos):
        action = MEDIA_LIGHTBOX_CLOSE
    ctx.end_popup()
    return action


def image_lightbox(
    mut ctx: Context,
    id_str: String,
    texture_id: UInt32,
    title: String,
    subtitle: String,
    image_width: Int32 = 0,
    image_height: Int32 = 0,
) -> Bool:
    """Full-window preview overlay for a selected image. Returns True when
    the caller should close it."""
    return media_lightbox(
        ctx,
        id_str,
        texture_id,
        title,
        subtitle,
        String(""),
        False,
        image_width,
        image_height,
    ) == MEDIA_LIGHTBOX_CLOSE
