"""Backend smoke test — static methods + tessellation correctness without opening a window.

Tests the new pure-Mojo logic introduced in chunk 9 (the rectangle tessellator
and the color-packing helper), plus a compile-time sanity check that every
Backend.* method is callable with the expected signature.

What this does NOT test (deferred to M0-gate where the GPU is available):
  - Actually opening a window (would block on sapp_run / fight serenitymojo
    training for the GPU).
  - Actually drawing pixels (same).
  - End-to-end font load + draw (same).

Run: cd /home/alex/MojoUI && pixi run test-backend
"""

from mojoui.render.backend import (
    Backend,
    _pack_color_aabbggrr,
    _u32_to_f32_bits,
    _tessellate_rect,
    _tessellate_image_rect,
)
from mojoui.core.types import Vec2, Rect, Color


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error("backend smoke")


# ============================================================
# Color packing tests
# ============================================================


def test_color_packing_red() raises:
    """Red (255,0,0,255) -> 0xAABBGGRR = 0xFF0000FF.

    AABBGGRR layout: A in high byte, then B, G, R in the low byte.
        A = 0xFF
        B = 0x00
        G = 0x00
        R = 0xFF
    UInt32 = 0xFF00_00FF.
    """
    var red = Color(255, 0, 0, 255)
    var got = _pack_color_aabbggrr(red)
    var want: UInt32 = 0xFF0000FF
    if got != want:
        print("got: ", got, " want: ", want)
        _fail("_pack_color_aabbggrr(red)")


def test_color_packing_green() raises:
    """Green (0,255,0,255) -> A=FF B=00 G=FF R=00 -> 0xFF00FF00."""
    var green = Color(0, 255, 0, 255)
    var got = _pack_color_aabbggrr(green)
    var want: UInt32 = 0xFF00FF00
    if got != want:
        print("got: ", got, " want: ", want)
        _fail("_pack_color_aabbggrr(green)")


def test_color_packing_blue() raises:
    """Blue (0,0,255,255) -> A=FF B=FF G=00 R=00 -> 0xFFFF0000."""
    var blue = Color(0, 0, 255, 255)
    var got = _pack_color_aabbggrr(blue)
    var want: UInt32 = 0xFFFF0000
    if got != want:
        print("got: ", got, " want: ", want)
        _fail("_pack_color_aabbggrr(blue)")


def test_color_packing_alpha() raises:
    """Half-alpha gray (128,128,128,128) -> A=80 B=80 G=80 R=80 -> 0x80808080."""
    var gray = Color(128, 128, 128, 128)
    var got = _pack_color_aabbggrr(gray)
    var want: UInt32 = 0x80808080
    if got != want:
        print("got: ", got, " want: ", want)
        _fail("_pack_color_aabbggrr(gray)")


def test_u32_to_f32_roundtrip() raises:
    """Bit-reinterpret round-trip: U32 -> F32 -> U32 must preserve bits."""
    var src: UInt32 = 0xDEADBEEF
    var as_f = _u32_to_f32_bits(src)
    # Round-trip back via the same trick
    var roundtrip: UInt32 = 0
    var rp = UnsafePointer(to=roundtrip).bitcast[Float32]()
    rp[] = as_f
    if roundtrip != src:
        print("src:", src, " roundtrip:", roundtrip)
        _fail("_u32_to_f32_bits round-trip")


# ============================================================
# Rectangle tessellation tests
# ============================================================


def test_tessellate_rect_corners() raises:
    """Rect(10, 20, 30, 40) -> 4 vertices at the four corners.

        v0=top-left    = (10, 20)
        v1=top-right   = (40, 20)
        v2=bottom-right= (40, 60)
        v3=bottom-left = (10, 60)
    """
    var r = Rect(10.0, 20.0, 30.0, 40.0)
    var c = Color(128, 64, 32, 200)
    var verts = InlineArray[Float32, 20](fill=0.0)
    var idx = InlineArray[UInt16, 6](fill=0)
    _tessellate_rect(r, c, verts, idx)

    # v0 top-left (10, 20)
    if verts[0] != 10.0:
        _fail("v0.x")
    if verts[1] != 20.0:
        _fail("v0.y")
    # v1 top-right (40, 20)
    if verts[5] != 40.0:
        _fail("v1.x")
    if verts[6] != 20.0:
        _fail("v1.y")
    # v2 bottom-right (40, 60)
    if verts[10] != 40.0:
        _fail("v2.x")
    if verts[11] != 60.0:
        _fail("v2.y")
    # v3 bottom-left (10, 60)
    if verts[15] != 10.0:
        _fail("v3.x")
    if verts[16] != 60.0:
        _fail("v3.y")


def test_tessellate_rect_uvs_zero() raises:
    """All UV pairs must be (0, 0) — built-in white texture binding."""
    var r = Rect(0.0, 0.0, 100.0, 100.0)
    var c = Color.white()
    var verts = InlineArray[Float32, 20](fill=-1.0)
    var idx = InlineArray[UInt16, 6](fill=0)
    _tessellate_rect(r, c, verts, idx)
    # u, v slots are 2,3 / 7,8 / 12,13 / 17,18.
    if verts[2] != 0.0 or verts[3] != 0.0:
        _fail("v0 uv")
    if verts[7] != 0.0 or verts[8] != 0.0:
        _fail("v1 uv")
    if verts[12] != 0.0 or verts[13] != 0.0:
        _fail("v2 uv")
    if verts[17] != 0.0 or verts[18] != 0.0:
        _fail("v3 uv")


def test_tessellate_rect_indices() raises:
    """Indices form two CCW triangles: 0,1,2  and  0,2,3.

    Y grows DOWN in our coord system; sokol's default winding for the inline
    GLSL pipeline doesn't cull, so CCW vs CW is purely a convention choice
    here. We picked CCW-in-screen-space to match the comment in the source.
    """
    var r = Rect(0.0, 0.0, 1.0, 1.0)
    var c = Color.white()
    var verts = InlineArray[Float32, 20](fill=0.0)
    var idx = InlineArray[UInt16, 6](fill=99)
    _tessellate_rect(r, c, verts, idx)
    if idx[0] != 0 or idx[1] != 1 or idx[2] != 2:
        print("tri0:", idx[0], idx[1], idx[2])
        _fail("triangle 0")
    if idx[3] != 0 or idx[4] != 2 or idx[5] != 3:
        print("tri1:", idx[3], idx[4], idx[5])
        _fail("triangle 1")


def test_tessellate_rect_color_in_slot4() raises:
    """All 4 vertices must carry the SAME packed color in slot 4 of their tuple
    (offsets 4, 9, 14, 19 in the flat layout)."""
    var r = Rect(0.0, 0.0, 10.0, 10.0)
    var c = Color(255, 0, 0, 255)  # red
    var verts = InlineArray[Float32, 20](fill=0.0)
    var idx = InlineArray[UInt16, 6](fill=0)
    _tessellate_rect(r, c, verts, idx)
    var c0 = verts[4]
    if verts[9] != c0:
        _fail("vertex 1 color != vertex 0 color")
    if verts[14] != c0:
        _fail("vertex 2 color != vertex 0 color")
    if verts[19] != c0:
        _fail("vertex 3 color != vertex 0 color")
    # And it must round-trip back to the AABBGGRR uint32 we expected.
    var u: UInt32 = 0
    var up = UnsafePointer(to=u).bitcast[Float32]()
    up[] = c0
    if u != 0xFF0000FF:
        print("packed:", u, " expected: 0xFF0000FF")
        _fail("packed color round-trip")


def test_tessellate_image_rect_uvs() raises:
    """Image rects must span full UV space: TL(0,0), TR(1,0), BR(1,1), BL(0,1)."""
    var r = Rect(0.0, 0.0, 64.0, 32.0)
    var tint = Color(255, 255, 255, 255)
    var verts = InlineArray[Float32, 20](fill=-1.0)
    var idx = InlineArray[UInt16, 6](fill=0)
    _tessellate_image_rect(r, tint, verts, idx)
    if verts[2] != 0.0 or verts[3] != 0.0:
        _fail("image v0 uv")
    if verts[7] != 1.0 or verts[8] != 0.0:
        _fail("image v1 uv")
    if verts[12] != 1.0 or verts[13] != 1.0:
        _fail("image v2 uv")
    if verts[17] != 0.0 or verts[18] != 1.0:
        _fail("image v3 uv")


# ============================================================
# Static-method existence checks (compile-only)
# ============================================================


def test_static_methods_exist():
    """Every Backend.* method must compile-time-resolve to a real symbol.

    No method is actually invoked (no window is open in this test — GPU is
    busy). The point is to catch import errors / signature drift at module
    load time. Wrapped in a runtime-False guard so the type checker still
    sees the calls but they never execute.
    """
    var never = False
    if never:
        _ = Backend.init(Int32(0), Int32(0), String(""))
        Backend.shutdown()
        Backend.request_close()
        _ = Backend.should_close()
        _ = Backend.window_size()
        Backend.frame_begin(Color.black())
        Backend.frame_end()
        var px = List[UInt8]()
        _ = Backend.make_texture_rgba(Int32(1), Int32(1), px)
        Backend.draw_image_rect(
            Rect(0.0, 0.0, 1.0, 1.0),
            UInt32(0),
            Color.white(),
        )
        Backend.destroy_texture(UInt32(0))
        _ = Backend.mouse_pos()
        _ = Backend.mouse_button(Int32(0))
        _ = Backend.key_pressed(Int32(0))
        # input_text() raises — covered by a separate raising path in main.
        Backend.draw_rect(Rect(0.0, 0.0, 1.0, 1.0), Color.white())
        _ = Backend.draw_text(
            UInt32(1), Int32(16), String("x"), Vec2(0.0, 0.0), Color.white()
        )
        _ = Backend.text_width(UInt32(1), Int32(16), String("x"))
        _ = Backend.text_height(UInt32(1), Int32(16))
        _ = Backend.load_font(String(""))
        Backend.destroy_font(UInt32(1))


def test_input_text_signature() raises:
    """The input_text() method returns String and raises — compile-only proof guard."""
    var never = False
    if never:
        var _s = Backend.input_text()


# ============================================================
# Entry
# ============================================================


def main() raises:
    test_color_packing_red()
    test_color_packing_green()
    test_color_packing_blue()
    test_color_packing_alpha()
    test_u32_to_f32_roundtrip()
    test_tessellate_rect_corners()
    test_tessellate_rect_uvs_zero()
    test_tessellate_rect_indices()
    test_tessellate_rect_color_in_slot4()
    test_tessellate_image_rect_uvs()
    test_static_methods_exist()
    test_input_text_signature()
    print("PASS: backend smoke (color packing + rect tessellation + API surface)")
