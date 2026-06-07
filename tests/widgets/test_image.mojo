"""Smoke tests for `mojoui/widgets/image.mojo` — M2 chunk 27.

Run: `pixi run test-image`

Exercises the three image entry points (`image`, `image_tinted`, `image_rect`):

  * Each emits exactly one `CMD_IMAGE` command.
  * `image_tinted` preserves the caller's tint colour byte-for-byte.
  * `image_rect` paints at the exact rect passed in (does NOT consume a
    layout slot — caller controls geometry).

JIT note: like all widget tests, uses `Context.begin_frame_no_input` to
bypass the FFI poll path (the JIT does not auto-dlopen libmojoui_floor.so
when no runtime path materialises `mojoui_get_mouse_*`). The widget itself
never touches FFI — only `commands.emit_image` (pure Mojo byte writes).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_IMAGE,
    CMD_IMAGE_SIZE,
    read_cmd_image,
)
from mojoui.widgets.image import (
    image,
    image_tinted,
    image_rect,
    image_fit_rect,
    image_pixel_to_screen_rect,
    image_screen_to_pixel_point,
    image_box_hit_test,
    image_rect_fit_boxes,
    ImageOverlayBox,
    image_lightbox,
    image_preview_button,
    media_preview_button,
    video_preview_button,
    video_lightbox,
    MEDIA_LIGHTBOX_OPEN,
    MEDIA_LIGHTBOX_PLAY,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _near(a: Float32, b: Float32) -> Bool:
    var d = a - b
    if d < 0.0:
        d = -d
    return d < 0.001


# ----------------------------------------------------------------------------
# Helpers — 1-column row layout of width 200, height 24. Sequential widget
# calls produce stacked rects at y = 0/24/48 (same layout shape as test_radio).
# ----------------------------------------------------------------------------


def _begin_3_row(mut ctx: Context) raises:
    """Begin a frame with a single 1-column row of width 200, height 24.
    Mouse far from anything so no widget claims hover (image doesn't claim
    hover anyway, but be hermetic)."""
    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(500.0, 500.0), False, False
    )
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_basic_call() raises:
    """Test 1: image() compiles and is callable with the documented
    signature. Texture id 7 (arbitrary), no return value to check."""
    var ctx = Context()
    _begin_3_row(ctx)
    image(ctx, UInt32(7))
    ctx.end_frame()


def test_image_emits_one_command() raises:
    """Test 2: image() emits exactly one CMD_IMAGE (byte_count grows by
    exactly CMD_IMAGE_SIZE = 32, header byte at offset 0 == CMD_IMAGE)."""
    var ctx = Context()
    _begin_3_row(ctx)
    var before = ctx.commands.byte_count()
    image(ctx, UInt32(7))
    var after = ctx.commands.byte_count()
    var delta = after - before
    if delta != Int(CMD_IMAGE_SIZE):
        _fail("image() should emit exactly CMD_IMAGE_SIZE (32) bytes")
    # Header at the emit offset (== `before`) must be CMD_IMAGE.
    var kind = ctx.commands.kind_at(Int32(before))
    if Int(kind) != Int(CMD_IMAGE):
        _fail("first command byte should tag as CMD_IMAGE")
    # Read back and verify texture id + white tint.
    var cmd = read_cmd_image(ctx.commands, Int32(before))
    if UInt32(cmd.texture_id) != UInt32(7):
        _fail("image() should preserve the texture id passed in")
    if (
        Int(cmd.tint.r) != 255
        or Int(cmd.tint.g) != 255
        or Int(cmd.tint.b) != 255
        or Int(cmd.tint.a) != 255
    ):
        _fail("image() should emit a fully-opaque white tint by default")
    ctx.end_frame()


def test_image_tinted_preserves_tint() raises:
    """Test 3: image_tinted(ctx, 7, (255,0,0,128)) — verify the tint is
    written into the command buffer byte-for-byte."""
    var ctx = Context()
    _begin_3_row(ctx)
    var before = ctx.commands.byte_count()
    var t = Color(255, 0, 0, 128)
    image_tinted(ctx, UInt32(7), t.copy())
    var after = ctx.commands.byte_count()
    if (after - before) != Int(CMD_IMAGE_SIZE):
        _fail("image_tinted() should emit exactly one CMD_IMAGE")
    var cmd = read_cmd_image(ctx.commands, Int32(before))
    if UInt32(cmd.texture_id) != UInt32(7):
        _fail("image_tinted() should preserve the texture id")
    if (
        Int(cmd.tint.r) != 255
        or Int(cmd.tint.g) != 0
        or Int(cmd.tint.b) != 0
        or Int(cmd.tint.a) != 128
    ):
        _fail("image_tinted() should preserve the caller's tint byte-for-byte")
    ctx.end_frame()


def test_image_rect_paints_at_explicit_rect() raises:
    """Test 4: image_rect(ctx, Rect(10,20,30,40), 5, white) — verify the
    emitted rect bytes match the explicit input rect (does NOT consume a
    layout slot — so the rect bypasses LayoutStack.next entirely)."""
    var ctx = Context()
    _begin_3_row(ctx)
    var before = ctx.commands.byte_count()
    var r = Rect(10.0, 20.0, 30.0, 40.0)
    var white = Color(255, 255, 255, 255)
    image_rect(ctx, r.copy(), UInt32(5), white.copy())
    var after = ctx.commands.byte_count()
    if (after - before) != Int(CMD_IMAGE_SIZE):
        _fail("image_rect() should emit exactly one CMD_IMAGE")
    var cmd = read_cmd_image(ctx.commands, Int32(before))
    if UInt32(cmd.texture_id) != UInt32(5):
        _fail("image_rect() should preserve the texture id")
    if (
        cmd.rect.x != 10.0
        or cmd.rect.y != 20.0
        or cmd.rect.w != 30.0
        or cmd.rect.h != 40.0
    ):
        _fail("image_rect() should paint at the EXPLICIT rect, not a layout slot")
    if (
        Int(cmd.tint.r) != 255
        or Int(cmd.tint.g) != 255
        or Int(cmd.tint.b) != 255
        or Int(cmd.tint.a) != 255
    ):
        _fail("image_rect() should preserve the caller's tint")
    ctx.end_frame()


def test_image_rect_does_not_consume_layout_slot() raises:
    """Test 5: image_rect does NOT advance the layout cursor — the next
    layout-using widget gets the FIRST slot at y=0 even after image_rect()
    paints somewhere unrelated. Verified by comparing the implicit
    layout_next of a follow-up `image()` call against (0, 0, 200, 24)."""
    var ctx = Context()
    _begin_3_row(ctx)
    var before = ctx.commands.byte_count()
    # Paint an image_rect AT (100, 100, 50, 50) — should NOT consume a slot.
    image_rect(ctx, Rect(100.0, 100.0, 50.0, 50.0), UInt32(3),
               Color(255, 255, 255, 255))
    # Now call image() — its layout slot must still be the FIRST row at y=0,
    # not advanced past where image_rect painted.
    var second_off = Int32(ctx.commands.byte_count())
    image(ctx, UInt32(4))
    var cmd2 = read_cmd_image(ctx.commands, second_off)
    if cmd2.rect.y != 0.0:
        _fail(
            "after image_rect (no-slot), the next image() should still get y=0"
        )
    if cmd2.rect.x != 0.0:
        _fail("first layout slot x should be 0 after a no-slot image_rect")
    # Also confirm both commands were emitted (sanity).
    var total = ctx.commands.byte_count() - before
    if total != 2 * Int(CMD_IMAGE_SIZE):
        _fail("expected exactly two CMD_IMAGE commands in the buffer")
    ctx.end_frame()


def test_image_preview_button_click() raises:
    """Test 6: clickable preview card reports a click on release after a
    press in the same rect."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(40.0, 40.0), True, False
    )
    var widths = List[Int32]()
    widths.append(240)
    ctx.layout_row(widths^, 180)
    var clicked_press = image_preview_button(
        ctx,
        String("preview"),
        UInt32(9),
        String("Preview"),
        String("caption"),
    )
    if not clicked_press:
        _fail("preview button should open on press frame")
    ctx.end_frame()

    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(40.0, 40.0), False, True
    )
    var widths2 = List[Int32]()
    widths2.append(240)
    ctx.layout_row(widths2^, 180)
    var clicked_release = image_preview_button(
        ctx,
        String("preview"),
        UInt32(9),
        String("Preview"),
        String("caption"),
    )
    if not clicked_release:
        _fail("preview button should click on release inside card")
    ctx.end_frame()


def test_image_lightbox_emits_popup_commands() raises:
    """Test 7: lightbox overlay emits image commands and can be left open."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(1200.0, 800.0), Vec2(10.0, 10.0), False, False
    )
    var close = image_lightbox(
        ctx,
        String("lightbox"),
        UInt32(11),
        String("Large preview"),
        String("image path"),
    )
    if close:
        _fail("lightbox should not close without a release")
    ctx.end_frame()
    if ctx.commands.byte_count() <= 0:
        _fail("lightbox should emit popup draw commands")


def test_media_and_video_preview_button_click() raises:
    """Test 8: explicit media/video preview wrappers report clicks."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(40.0, 40.0), True, False
    )
    var widths = List[Int32]()
    widths.append(240)
    ctx.layout_row(widths^, 180)
    var media_clicked = media_preview_button(
        ctx,
        String("media_preview"),
        UInt32(9),
        String("Media"),
        String("caption"),
        128,
        96,
        True,
    )
    if not media_clicked:
        _fail("media preview button should click on press frame")
    ctx.end_frame()

    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(40.0, 40.0), True, False
    )
    var widths2 = List[Int32]()
    widths2.append(240)
    ctx.layout_row(widths2^, 180)
    var video_clicked = video_preview_button(
        ctx,
        String("video_preview"),
        UInt32(10),
        String("Video"),
        String("clip.mp4"),
        480,
        288,
    )
    if not video_clicked:
        _fail("video preview button should click on press frame")
    ctx.end_frame()


def test_video_lightbox_play_action() raises:
    """Test 9: video lightbox returns MEDIA_LIGHTBOX_PLAY on play release."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(1200.0, 800.0), Vec2(900.0, 100.0), True, False
    )
    var action_press = video_lightbox(
        ctx,
        String("video_lightbox"),
        UInt32(12),
        String("Video preview"),
        String("caption"),
        String("/tmp/clip.mp4"),
        480,
        288,
    )
    if action_press != MEDIA_LIGHTBOX_OPEN:
        _fail("video lightbox should stay open on play press frame")
    ctx.end_frame()

    ctx.begin_frame_no_input(
        Vec2(1200.0, 800.0), Vec2(900.0, 100.0), False, True
    )
    var action_release = video_lightbox(
        ctx,
        String("video_lightbox"),
        UInt32(12),
        String("Video preview"),
        String("caption"),
        String("/tmp/clip.mp4"),
        480,
        288,
    )
    if action_release != MEDIA_LIGHTBOX_PLAY:
        _fail("video lightbox should return MEDIA_LIGHTBOX_PLAY on play release")
    ctx.end_frame()


def test_image_overlay_box_mapping_and_hit_test() raises:
    """Test 10: pixel-space overlay boxes map to fitted screen space."""
    var fitted = image_fit_rect(Rect(0.0, 0.0, 300.0, 300.0), 1000, 500)
    if not _near(fitted.x, 0.0) or not _near(fitted.y, 75.0) or not _near(fitted.w, 300.0) or not _near(fitted.h, 150.0):
        _fail("1000x500 image should fit into 300x300 at 300x150 centered vertically")
    var screen = image_pixel_to_screen_rect(
        fitted.copy(),
        1000,
        500,
        Rect(100.0, 50.0, 200.0, 100.0),
    )
    if not _near(screen.x, 30.0) or not _near(screen.y, 90.0) or not _near(screen.w, 60.0) or not _near(screen.h, 30.0):
        _fail("pixel box should map through fitted image scale")
    var px = image_screen_to_pixel_point(fitted.copy(), 1000, 500, Vec2(60.0, 105.0))
    if not _near(px.x, 200.0) or not _near(px.y, 100.0):
        _fail("screen point should map back into source image pixels")

    var boxes = List[ImageOverlayBox]()
    boxes.append(
        ImageOverlayBox(
            Int64(1),
            Rect(100.0, 50.0, 200.0, 100.0),
            String("01"),
            String("subject"),
            Color(80, 180, 255, 220),
        )
    )
    boxes.append(
        ImageOverlayBox(
            Int64(2),
            Rect(150.0, 75.0, 100.0, 50.0),
            String("02"),
            String("detail"),
            Color(255, 210, 80, 220),
        )
    )
    var hit = image_box_hit_test(fitted.copy(), 1000, 500, boxes, Vec2(55.0, 100.0))
    if hit != Int64(2):
        _fail("hit test should return topmost matching overlay id")
    var miss = image_box_hit_test(fitted.copy(), 1000, 500, boxes, Vec2(10.0, 10.0))
    if miss != Int64(-1):
        _fail("hit test should return -1 outside overlays")
    print("  PASS test_image_overlay_box_mapping_and_hit_test")


def test_image_rect_fit_boxes_emits_commands() raises:
    """Test 11: drawing an image with boxes emits image + overlay commands."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(500.0, 500.0), False, False
    )
    var boxes = List[ImageOverlayBox]()
    boxes.append(
        ImageOverlayBox(
            Int64(1),
            Rect(10.0, 20.0, 50.0, 60.0),
            String("01"),
            String("region"),
            Color(80, 180, 255, 220),
            True,
        )
    )
    var before = ctx.commands.byte_count()
    var fitted = image_rect_fit_boxes(
        ctx,
        Rect(0.0, 0.0, 200.0, 200.0),
        UInt32(17),
        100,
        100,
        boxes,
        Color(255, 255, 255, 255),
    )
    var after = ctx.commands.byte_count()
    if fitted.w != 200.0 or fitted.h != 200.0:
        _fail("square image should fill square fitted rect")
    if (after - before) <= Int(CMD_IMAGE_SIZE):
        _fail("image_rect_fit_boxes should emit overlay draw commands beyond image")
    ctx.end_frame()
    print("  PASS test_image_rect_fit_boxes_emits_commands")


def main() raises:
    test_compile_and_basic_call()
    test_image_emits_one_command()
    test_image_tinted_preserves_tint()
    test_image_rect_paints_at_explicit_rect()
    test_image_rect_does_not_consume_layout_slot()
    test_image_preview_button_click()
    test_image_lightbox_emits_popup_commands()
    test_media_and_video_preview_button_click()
    test_video_lightbox_play_action()
    test_image_overlay_box_mapping_and_hit_test()
    test_image_rect_fit_boxes_emits_commands()
    print("PASS: image widget smoke tests (11 tests)")
