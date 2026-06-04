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
from mojoui.widgets.image import image, image_tinted, image_rect


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


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


def main() raises:
    test_compile_and_basic_call()
    test_image_emits_one_command()
    test_image_tinted_preserves_tint()
    test_image_rect_paints_at_explicit_rect()
    test_image_rect_does_not_consume_layout_slot()
    print("PASS: image widget smoke tests (5 tests)")
