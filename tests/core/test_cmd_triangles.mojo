"""Smoke tests for the M3 c46-fix Bug 2 CMD_TRIANGLES record on
`mojoui/core/commands.mojo`.

Covers:
  1. Empty triangles: emit + read returns 0 verts / 0 indices.
  2. Single triangle: 3 verts (15 floats), 3 indices, texture_id round-trip.
  3. Multiple emits: per-command offset returned matches walk order; both
     records readable independently.
  4. Mixed walk: RECT + TRIANGLES + TEXT round-trip via kind_at + size_at.

Pure-Mojo round-trip — no FFI in the test call graph. Runs under JIT.

Run: `pixi run test-cmd-triangles`.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.commands import (
    CommandBuffer,
    CMD_RECT,
    CMD_TEXT,
    CMD_TRIANGLES,
    HEADER_SIZE,
    read_cmd_triangles,
    read_cmd_rect,
    read_cmd_text,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error("cmd_triangles smoke")


def _abs_f32(x: Float32) -> Float32:
    if x < Float32(0.0):
        return -x
    return x


def test_empty_triangles_round_trip() raises:
    """Emit 0 verts / 0 indices: header records n_verts=0, n_indices=0; the
    payload byte run is zero-length. read_cmd_triangles returns matching
    empty Lists."""
    var buf = CommandBuffer()
    var verts = List[Float32]()
    var indices = List[UInt16]()
    var off = buf.emit_triangles(verts^, indices^, UInt32(0))
    if Int(off) != 0:
        _fail("expected offset 0 for first emit, got " + String(Int(off)))
    if Int32(buf.kind_at(off)) != Int32(CMD_TRIANGLES):
        _fail("kind_at(0) should be CMD_TRIANGLES")
    # Header(8) + metadata(12) = 20 bytes total.
    if Int(buf.size_at(off)) != 20:
        _fail("empty triangles size should be 20 bytes, got " +
              String(Int(buf.size_at(off))))
    var decoded = read_cmd_triangles(buf, off)
    if Int(decoded.n_verts) != 0:
        _fail("decoded n_verts should be 0")
    if Int(decoded.n_indices) != 0:
        _fail("decoded n_indices should be 0")
    if len(decoded.verts) != 0:
        _fail("decoded verts list should be empty")
    if len(decoded.indices) != 0:
        _fail("decoded indices list should be empty")


def test_single_triangle_round_trip() raises:
    """3 verts (15 Float32 values) + 3 indices + texture_id=7 round-trips
    bit-exact. Verifies layout: header + n_verts + n_indices + texture_id +
    packed Float32 verts + packed UInt16 indices."""
    var buf = CommandBuffer()
    var verts = List[Float32]()
    # Vertex 0: (10, 20, 0, 0, 100.5)
    verts.append(Float32(10.0)); verts.append(Float32(20.0))
    verts.append(Float32(0.0));  verts.append(Float32(0.0))
    verts.append(Float32(100.5))
    # Vertex 1: (30, 40, 1, 0, 200.25)
    verts.append(Float32(30.0)); verts.append(Float32(40.0))
    verts.append(Float32(1.0));  verts.append(Float32(0.0))
    verts.append(Float32(200.25))
    # Vertex 2: (50, 60, 0, 1, 300.125)
    verts.append(Float32(50.0)); verts.append(Float32(60.0))
    verts.append(Float32(0.0));  verts.append(Float32(1.0))
    verts.append(Float32(300.125))

    var indices = List[UInt16]()
    indices.append(UInt16(0))
    indices.append(UInt16(1))
    indices.append(UInt16(2))

    var tex_id: UInt32 = 7
    var off = buf.emit_triangles(verts^, indices^, tex_id)
    if Int(off) != 0:
        _fail("expected offset 0 for first emit")
    # Total size = 20 + 3*5*4 + 3*2 = 20 + 60 + 6 = 86.
    if Int(buf.size_at(off)) != 86:
        _fail("single triangle size should be 86 bytes, got " +
              String(Int(buf.size_at(off))))

    var decoded = read_cmd_triangles(buf, off)
    if Int(decoded.n_verts) != 3:
        _fail("expected n_verts=3, got " + String(Int(decoded.n_verts)))
    if Int(decoded.n_indices) != 3:
        _fail("expected n_indices=3, got " + String(Int(decoded.n_indices)))
    if Int(decoded.texture_id) != 7:
        _fail("texture_id round-trip failed: got " + String(Int(decoded.texture_id)))
    if len(decoded.verts) != 15:
        _fail("expected 15 verts, got " + String(len(decoded.verts)))
    if len(decoded.indices) != 3:
        _fail("expected 3 indices, got " + String(len(decoded.indices)))

    # Spot-check vertex bytes round-trip exactly.
    var eps: Float32 = 1.0e-6
    if _abs_f32(decoded.verts[0] - Float32(10.0)) > eps:
        _fail("verts[0] (x of v0) mismatch")
    if _abs_f32(decoded.verts[4] - Float32(100.5)) > eps:
        _fail("verts[4] (color_bits of v0) mismatch")
    if _abs_f32(decoded.verts[14] - Float32(300.125)) > eps:
        _fail("verts[14] (color_bits of v2) mismatch")

    # Indices round-trip exactly.
    if Int(decoded.indices[0]) != 0:
        _fail("indices[0] mismatch")
    if Int(decoded.indices[2]) != 2:
        _fail("indices[2] mismatch")


def test_two_triangles_independent_offsets() raises:
    """Two consecutive emits return offsets 0 and (size of first). Each
    record decodes independently."""
    var buf = CommandBuffer()
    var v1 = List[Float32]()
    v1.append(Float32(1.0)); v1.append(Float32(2.0))
    v1.append(Float32(0.0)); v1.append(Float32(0.0))
    v1.append(Float32(11.0))
    var i1 = List[UInt16]()
    i1.append(UInt16(0)); i1.append(UInt16(0)); i1.append(UInt16(0))
    var off1 = buf.emit_triangles(v1^, i1^, UInt32(1))
    if Int(off1) != 0:
        _fail("first offset should be 0")
    var first_size = Int(buf.size_at(off1))
    # First record: 20 + 1*20 + 3*2 = 46.
    if first_size != 46:
        _fail("first record size mismatch: " + String(first_size))

    var v2 = List[Float32]()
    v2.append(Float32(3.0)); v2.append(Float32(4.0))
    v2.append(Float32(0.0)); v2.append(Float32(0.0))
    v2.append(Float32(22.0))
    v2.append(Float32(5.0)); v2.append(Float32(6.0))
    v2.append(Float32(0.0)); v2.append(Float32(0.0))
    v2.append(Float32(33.0))
    var i2 = List[UInt16]()
    i2.append(UInt16(0)); i2.append(UInt16(1)); i2.append(UInt16(0))
    var off2 = buf.emit_triangles(v2^, i2^, UInt32(2))
    if Int(off2) != first_size:
        _fail("second offset should equal first record size, got " +
              String(Int(off2)))

    var d1 = read_cmd_triangles(buf, off1)
    if Int(d1.texture_id) != 1:
        _fail("first record texture_id should be 1")
    if len(d1.verts) != 5:
        _fail("first record should have 5 verts (1*5)")

    var d2 = read_cmd_triangles(buf, off2)
    if Int(d2.texture_id) != 2:
        _fail("second record texture_id should be 2")
    if len(d2.verts) != 10:
        _fail("second record should have 10 verts (2*5)")


def test_walker_mixed_rect_triangles_text() raises:
    """Emit RECT + TRIANGLES + TEXT in order; walker via kind_at + size_at
    advances cleanly through each."""
    var buf = CommandBuffer()
    var r_off = buf.emit_rect(
        Rect(0.0, 0.0, 50.0, 50.0), Color(255, 0, 0, 255)
    )
    var v = List[Float32]()
    v.append(Float32(0.0)); v.append(Float32(0.0))
    v.append(Float32(0.0)); v.append(Float32(0.0))
    v.append(Float32(0.0))
    v.append(Float32(10.0)); v.append(Float32(0.0))
    v.append(Float32(0.0)); v.append(Float32(0.0))
    v.append(Float32(0.0))
    v.append(Float32(5.0)); v.append(Float32(10.0))
    v.append(Float32(0.0)); v.append(Float32(0.0))
    v.append(Float32(0.0))
    var i = List[UInt16]()
    i.append(UInt16(0)); i.append(UInt16(1)); i.append(UInt16(2))
    var t_off = buf.emit_triangles(v^, i^, UInt32(0))
    var x_off = buf.emit_text(
        UInt32(1), Int32(14), Vec2(5.0, 12.0),
        Color(255, 255, 255, 255), String("Hi"),
    )

    # Walk and verify each kind appears in order.
    var off: Int32 = 0
    var end_off = Int32(buf.byte_count())
    var seen_kinds = List[Int]()
    while off < end_off:
        seen_kinds.append(Int(buf.kind_at(off)))
        off = off + buf.size_at(off)
    if len(seen_kinds) != 3:
        _fail("expected 3 commands, got " + String(len(seen_kinds)))
    if seen_kinds[0] != Int(CMD_RECT):
        _fail("first command should be CMD_RECT")
    if seen_kinds[1] != Int(CMD_TRIANGLES):
        _fail("second command should be CMD_TRIANGLES")
    if seen_kinds[2] != Int(CMD_TEXT):
        _fail("third command should be CMD_TEXT")

    # Each typed read works at its offset.
    var rect_cmd = read_cmd_rect(buf, r_off)
    if _abs_f32(rect_cmd.rect.w - Float32(50.0)) > Float32(1.0e-6):
        _fail("rect width round-trip")
    var tri_cmd = read_cmd_triangles(buf, t_off)
    if Int(tri_cmd.n_verts) != 3:
        _fail("triangles n_verts round-trip")
    var text_cmd = read_cmd_text(buf, x_off)
    if text_cmd.text != String("Hi"):
        _fail("text round-trip")


def main() raises:
    test_empty_triangles_round_trip()
    test_single_triangle_round_trip()
    test_two_triangles_independent_offsets()
    test_walker_mixed_rect_triangles_text()
    print(
        "PASS: cmd_triangles smoke (empty round-trip + single triangle +",
        "two independent offsets + mixed RECT/TRIANGLES/TEXT walk)",
    )
