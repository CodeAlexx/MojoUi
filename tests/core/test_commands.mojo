"""Smoke tests for `mojoui/core/commands.mojo`.

Run: `pixi run test-commands`
"""

from mojoui.core.commands import (
    CMD_JUMP,
    CMD_JUMP_SIZE,
    CMD_RECT,
    CMD_RECT_SIZE,
    CMD_TEXT,
    CMD_TEXT_FIXED_SIZE,
    CommandBuffer,
    HEADER_SIZE,
    read_cmd_rect,
    read_cmd_text,
)
from mojoui.core.types import Color, Rect, Vec2


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_empty_buffer() raises:
    """Fresh CommandBuffer has zero bytes."""
    var buf = CommandBuffer()
    if buf.byte_count() != 0:
        _fail("empty buffer should have byte_count == 0")


def test_single_rect() raises:
    """Emit_rect returns offset 0, byte_count grows by CMD_RECT_SIZE,
    kind_at(0) == CMD_RECT, size_at(0) == CMD_RECT_SIZE."""
    var buf = CommandBuffer()
    var off = buf.emit_rect(Rect(1.0, 2.0, 3.0, 4.0), Color(10, 20, 30, 40))
    if Int32(off) != Int32(0):
        _fail("first emit should return offset 0")
    if buf.byte_count() != Int(CMD_RECT_SIZE):
        _fail("byte_count after one RECT should equal CMD_RECT_SIZE (28)")
    if Int32(buf.kind_at(0)) != Int32(CMD_RECT):
        _fail("kind_at(0) should be CMD_RECT")
    if Int32(buf.size_at(0)) != Int32(CMD_RECT_SIZE):
        _fail("size_at(0) should be CMD_RECT_SIZE")


def test_two_rects() raises:
    """Second emit returns the previous byte_count; both rects have correct
    kinds and sizes."""
    var buf = CommandBuffer()
    var off1 = buf.emit_rect(Rect(0, 0, 1, 1), Color(0, 0, 0, 0))
    var off2 = buf.emit_rect(Rect(5, 5, 10, 10), Color(255, 255, 255, 255))
    if Int32(off2) != Int32(CMD_RECT_SIZE):
        _fail("second emit offset should equal first command's size")
    if Int32(off1) >= Int32(off2):
        _fail("offsets should be strictly increasing")
    if Int32(buf.kind_at(off1)) != Int32(CMD_RECT):
        _fail("first kind wrong")
    if Int32(buf.kind_at(off2)) != Int32(CMD_RECT):
        _fail("second kind wrong")
    if Int32(buf.size_at(off1)) != Int32(CMD_RECT_SIZE):
        _fail("first size wrong")
    if Int32(buf.size_at(off2)) != Int32(CMD_RECT_SIZE):
        _fail("second size wrong")


def test_jump_emit_and_patch() raises:
    """Emit_jump stores dst_offset and patch_jump can update it."""
    var buf = CommandBuffer()
    var jump_off = buf.emit_jump(Int32(999))
    if Int32(buf.kind_at(jump_off)) != Int32(CMD_JUMP):
        _fail("JUMP kind wrong")
    if Int32(buf.size_at(jump_off)) != Int32(CMD_JUMP_SIZE):
        _fail("JUMP size wrong (should be 12)")
    if Int32(buf.read_jump_dst(jump_off)) != Int32(999):
        _fail("JUMP dst_offset not stored correctly")
    # Patch it to a new destination.
    buf.patch_jump(jump_off, Int32(123))
    if Int32(buf.read_jump_dst(jump_off)) != Int32(123):
        _fail("patch_jump did not update dst_offset")


def test_text_growth() raises:
    """Emit_text with 5-byte 'Hello' grows the buffer by CMD_TEXT_FIXED_SIZE
    + 5; reading back text_byte_len returns 5; text round-trips."""
    var buf = CommandBuffer()
    var off = buf.emit_text(
        UInt32(7), Int32(16), Vec2(100.0, 200.0),
        Color(255, 128, 64, 200), "Hello"
    )
    if Int32(off) != Int32(0):
        _fail("first text emit should be at offset 0")
    var expected_size = Int(CMD_TEXT_FIXED_SIZE) + 5
    if buf.byte_count() != expected_size:
        _fail(String("text buffer growth wrong: got ") + String(buf.byte_count())
              + String(", expected ") + String(expected_size))
    if Int32(buf.kind_at(off)) != Int32(CMD_TEXT):
        _fail("text kind wrong")
    if Int32(buf.size_at(off)) != Int32(CMD_TEXT_FIXED_SIZE + Int32(5)):
        _fail("text cmd size_at wrong")
    var cmd = read_cmd_text(buf, off)
    if Int32(cmd.text_byte_len) != Int32(5):
        _fail("text_byte_len should be 5")
    if cmd.text != String("Hello"):
        _fail("text string did not round-trip")
    if UInt32(cmd.font_id) != UInt32(7):
        _fail("font_id did not round-trip")
    if Int32(cmd.size_pt) != Int32(16):
        _fail("size_pt did not round-trip")


def test_reset() raises:
    """Reset clears the buffer; subsequent emits start at offset 0 again."""
    var buf = CommandBuffer()
    _ = buf.emit_rect(Rect(0, 0, 1, 1), Color(1, 2, 3, 4))
    _ = buf.emit_rect(Rect(5, 5, 6, 6), Color(5, 6, 7, 8))
    if buf.byte_count() == 0:
        _fail("pre-reset byte_count should be non-zero")
    buf.reset()
    if buf.byte_count() != 0:
        _fail("post-reset byte_count should be zero")
    var off = buf.emit_rect(Rect(9, 9, 9, 9), Color(9, 9, 9, 9))
    if Int32(off) != Int32(0):
        _fail("first emit after reset should return offset 0")


def test_walk_with_jump() raises:
    """Emit a JUMP-to-past-a-rect, then a rect after it.

    Walking from offset 0: kind is JUMP → follow dst_offset → land at the
    next rect (which is right after the rect we jumped over). This proves
    the JUMP semantics work end-to-end.
    """
    var buf = CommandBuffer()
    # Emit JUMP placeholder, then a target rect, then another rect.
    var jump_off = buf.emit_jump(Int32(0))  # placeholder; will patch below
    var rect_a_off = buf.emit_rect(Rect(1, 1, 1, 1), Color(11, 11, 11, 11))
    var rect_b_off = buf.emit_rect(Rect(2, 2, 2, 2), Color(22, 22, 22, 22))
    # Patch the JUMP to skip rect_a and land on rect_b.
    buf.patch_jump(jump_off, rect_b_off)
    # Walk: start at 0 (the JUMP).
    var off: Int32 = 0
    if Int32(buf.kind_at(off)) != Int32(CMD_JUMP):
        _fail("walk: first cmd should be JUMP")
    # Follow the JUMP.
    off = buf.read_jump_dst(off)
    if Int32(off) != Int32(rect_b_off):
        _fail("walk: JUMP should have landed on rect_b")
    if Int32(buf.kind_at(off)) != Int32(CMD_RECT):
        _fail("walk: should land on a RECT after the JUMP")
    # Verify the rect we skipped is indeed there in the buffer (just not visited).
    if Int32(buf.kind_at(rect_a_off)) != Int32(CMD_RECT):
        _fail("rect_a should still exist in the buffer, just skipped by JUMP")
    # After visiting rect_b, the next offset should be end of buffer.
    off = off + buf.size_at(off)
    if Int(off) != buf.byte_count():
        _fail("walk: after visiting rect_b we should be at end-of-buffer")


def test_rect_roundtrip() raises:
    """Round-trip a CmdRect: emit, then read_cmd_rect, fields match."""
    var buf = CommandBuffer()
    var r = Rect(10.0, 20.0, 30.0, 40.0)
    var c = Color(1, 2, 3, 4)
    var off = buf.emit_rect(r, c)
    var cmd = read_cmd_rect(buf, off)
    if Int32(cmd.header.kind) != Int32(CMD_RECT):
        _fail("round-trip: kind wrong")
    if Int32(cmd.header.size) != Int32(CMD_RECT_SIZE):
        _fail("round-trip: size wrong")
    if cmd.rect.x != Float32(10.0) or cmd.rect.y != Float32(20.0):
        _fail("round-trip: rect x/y wrong")
    if cmd.rect.w != Float32(30.0) or cmd.rect.h != Float32(40.0):
        _fail("round-trip: rect w/h wrong")
    if (
        UInt8(cmd.color.r) != UInt8(1)
        or UInt8(cmd.color.g) != UInt8(2)
        or UInt8(cmd.color.b) != UInt8(3)
        or UInt8(cmd.color.a) != UInt8(4)
    ):
        _fail("round-trip: color rgba wrong")


def main() raises:
    test_empty_buffer()
    test_single_rect()
    test_two_rects()
    test_jump_emit_and_patch()
    test_text_growth()
    test_reset()
    test_walk_with_jump()
    test_rect_roundtrip()
    print("PASS: commands smoke tests (8 tests)")
