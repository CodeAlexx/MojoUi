"""Smoke tests for `mojoui/nodes/wires.mojo` — cubic bezier wire rendering.

Verifies:
1. `cubic_bezier_point(p0..p3, 0.0)` == p0 exactly.
2. `cubic_bezier_point(p0..p3, 1.0)` == p3 exactly.
3. `cubic_bezier_point(p0..p3, 0.5)` == midpoint formula B(0.5) =
   0.125*P0 + 0.375*P1 + 0.375*P2 + 0.125*P3.
4. `draw_wire` from (10,10) to (200,200) emits exactly `WIRE_SEGMENTS`
   (24) `CMD_RECT` commands.
5. `draw_wire_thick(thickness=8.0)` produces visibly thicker segment
   rects than `draw_wire` (thickness=2.0).
6. `wire_color_for_type(0..10)` returns 11 pairwise distinct colors.
7. `wire_color_for_type(99)` returns the EriGui default amber.

JIT note: the bezier math + wire drawing path is pure Mojo (no FFI in
the call graph), so `Context.begin_frame_no_input` is enough — no
runtime-False JIT guard required.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_RECT, read_cmd_rect
from mojoui.nodes.wires import (
    WIRE_SEGMENTS,
    WIRE_THICKNESS,
    WIRE_TANGENT_FRAC,
    cubic_bezier_point,
    draw_wire,
    draw_wire_thick,
    wire_color_for_type,
    wire_distance_to_point,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _abs(x: Float32) -> Float32:
    if x < Float32(0.0):
        return -x
    return x


def _approx_eq(a: Float32, b: Float32) -> Bool:
    return _abs(a - b) <= Float32(1.0e-4)


def _count_rects(ctx: Context) -> Int:
    """Walk the command buffer and count CMD_RECT commands."""
    var n = 0
    var off: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    while off < total:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_RECT):
            n += 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off += step
    return n


def _max_rect_min_extent(ctx: Context) raises -> Float32:
    """Walk all CMD_RECT records and return the maximum of `min(w, h)`
    across them. With the bounding-rect-pad-by-thickness scheme, the
    smallest axis of every segment rect equals `thickness`; this lets
    the thickness test distinguish 2.0 vs 8.0 stroke widths."""
    var best = Float32(0.0)
    var off: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    while off < total:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_RECT):
            var rc = read_cmd_rect(ctx.commands, off)
            var m = rc.rect.w
            if rc.rect.h < m:
                m = rc.rect.h
            if m > best:
                best = m
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off += step
    return best


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_bezier_at_t0_returns_p0() raises:
    """Test 1: B(0) == P0 exactly."""
    var p0 = Vec2(Float32(10.0), Float32(20.0))
    var p1 = Vec2(Float32(50.0), Float32(60.0))
    var p2 = Vec2(Float32(90.0), Float32(40.0))
    var p3 = Vec2(Float32(130.0), Float32(80.0))
    var b = cubic_bezier_point(
        p0.copy(), p1.copy(), p2.copy(), p3.copy(), Float32(0.0)
    )
    if not _approx_eq(b.x, p0.x) or not _approx_eq(b.y, p0.y):
        _fail("B(0) should equal P0 exactly, got " + String(b))
    print("PASS: test_bezier_at_t0_returns_p0")


def test_bezier_at_t1_returns_p3() raises:
    """Test 2: B(1) == P3 exactly."""
    var p0 = Vec2(Float32(10.0), Float32(20.0))
    var p1 = Vec2(Float32(50.0), Float32(60.0))
    var p2 = Vec2(Float32(90.0), Float32(40.0))
    var p3 = Vec2(Float32(130.0), Float32(80.0))
    var b = cubic_bezier_point(
        p0.copy(), p1.copy(), p2.copy(), p3.copy(), Float32(1.0)
    )
    if not _approx_eq(b.x, p3.x) or not _approx_eq(b.y, p3.y):
        _fail("B(1) should equal P3 exactly, got " + String(b))
    print("PASS: test_bezier_at_t1_returns_p3")


def test_bezier_at_t05_matches_midpoint_formula() raises:
    """Test 3: B(0.5) = 0.125*P0 + 0.375*P1 + 0.375*P2 + 0.125*P3.

    Hand-computed for P0=(0,0), P1=(10,0), P2=(20,0), P3=(30,0):
      x = 0.125*0 + 0.375*10 + 0.375*20 + 0.125*30 = 3.75 + 7.5 + 3.75 = 15.0
      y = 0.0
    """
    var p0 = Vec2(Float32(0.0), Float32(0.0))
    var p1 = Vec2(Float32(10.0), Float32(0.0))
    var p2 = Vec2(Float32(20.0), Float32(0.0))
    var p3 = Vec2(Float32(30.0), Float32(0.0))
    var b = cubic_bezier_point(
        p0.copy(), p1.copy(), p2.copy(), p3.copy(), Float32(0.5)
    )
    var expected_x = Float32(15.0)
    var expected_y = Float32(0.0)
    if not _approx_eq(b.x, expected_x) or not _approx_eq(b.y, expected_y):
        _fail(
            "B(0.5) expected ("
            + String(expected_x)
            + ", "
            + String(expected_y)
            + "), got "
            + String(b)
        )

    # Also verify a non-trivial 2D case: with P0=(0,0), P1=(0,100),
    # P2=(100,100), P3=(100,0):
    #   x = 0.125*0 + 0.375*0 + 0.375*100 + 0.125*100 = 37.5 + 12.5 = 50.0
    #   y = 0.125*0 + 0.375*100 + 0.375*100 + 0.125*0 = 37.5 + 37.5 = 75.0
    var q0 = Vec2(Float32(0.0), Float32(0.0))
    var q1 = Vec2(Float32(0.0), Float32(100.0))
    var q2 = Vec2(Float32(100.0), Float32(100.0))
    var q3 = Vec2(Float32(100.0), Float32(0.0))
    var c = cubic_bezier_point(
        q0.copy(), q1.copy(), q2.copy(), q3.copy(), Float32(0.5)
    )
    if not _approx_eq(c.x, Float32(50.0)) or not _approx_eq(c.y, Float32(75.0)):
        _fail("B(0.5) S-curve expected (50, 75), got " + String(c))

    print("PASS: test_bezier_at_t05_matches_midpoint_formula (2 cases)")


def test_draw_wire_emits_wire_segments_rects() raises:
    """Test 4: `draw_wire` from (10,10) to (200,200) emits exactly
    `WIRE_SEGMENTS` (24) `CMD_RECT` commands."""
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
    )
    draw_wire(
        ctx,
        Vec2(Float32(10.0), Float32(10.0)),
        Vec2(Float32(200.0), Float32(200.0)),
        Color(UInt8(255), UInt8(255), UInt8(255), UInt8(255)),
    )
    var n = _count_rects(ctx)
    var want = Int(WIRE_SEGMENTS)
    if n != want:
        _fail(
            "draw_wire should emit "
            + String(want)
            + " CMD_RECT commands, got "
            + String(n)
        )
    print(
        "PASS: test_draw_wire_emits_wire_segments_rects ("
        + String(n)
        + " rects)"
    )


def test_draw_wire_thick_respects_thickness() raises:
    """Test 5: `draw_wire_thick(thickness=8.0)` produces visibly thicker
    rects than `draw_wire` (thickness=2.0).

    The bounding-rect-pad-by-thickness scheme guarantees the smallest
    axis of every segment rect is at least `thickness` pixels — so the
    maximum across segments of `min(w, h)` is `>= thickness`.
    """
    var ctx_thin = Context()
    ctx_thin.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
    )
    draw_wire(
        ctx_thin,
        Vec2(Float32(10.0), Float32(10.0)),
        Vec2(Float32(200.0), Float32(200.0)),
        Color(UInt8(255), UInt8(255), UInt8(255), UInt8(255)),
    )
    var thin_max = _max_rect_min_extent(ctx_thin)

    var ctx_thick = Context()
    ctx_thick.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
    )
    draw_wire_thick(
        ctx_thick,
        Vec2(Float32(10.0), Float32(10.0)),
        Vec2(Float32(200.0), Float32(200.0)),
        Color(UInt8(255), UInt8(255), UInt8(255), UInt8(255)),
        Float32(8.0),
    )
    var thick_max = _max_rect_min_extent(ctx_thick)

    if not (thick_max > thin_max):
        _fail(
            "thick stroke (max min-extent="
            + String(thick_max)
            + ") should exceed thin stroke (max min-extent="
            + String(thin_max)
            + ")"
        )

    # Also verify the thick path reached the requested thickness floor.
    if thick_max + Float32(1.0e-3) < Float32(8.0):
        _fail(
            "thick max min-extent should reach 8.0, got "
            + String(thick_max)
        )

    print(
        "PASS: test_draw_wire_thick_respects_thickness (thin="
        + String(thin_max)
        + ", thick="
        + String(thick_max)
        + ")"
    )


def test_wire_color_for_type_all_distinct() raises:
    """Test 6: `wire_color_for_type(0..10)` returns 11 pairwise distinct
    Colors (covers every NVT_* tag)."""
    var colors = List[Color]()
    for tag in range(0, 11):
        colors.append(wire_color_for_type(Int32(tag)))

    for i in range(0, 11):
        for j in range(i + 1, 11):
            var ci = colors[i].copy()
            var cj = colors[j].copy()
            if (
                ci.r == cj.r
                and ci.g == cj.g
                and ci.b == cj.b
                and ci.a == cj.a
            ):
                _fail(
                    "wire_color_for_type("
                    + String(i)
                    + ") collides with ("
                    + String(j)
                    + "): "
                    + String(ci)
                )
    print("PASS: test_wire_color_for_type_all_distinct (11 distinct)")


def test_wire_color_for_type_default_amber() raises:
    """Test 7: `wire_color_for_type(99)` returns the EriGui default
    amber `#F59E0B` == (245, 158, 11, 255)."""
    var c = wire_color_for_type(Int32(99))
    if (
        Int(c.r) != 245
        or Int(c.g) != 158
        or Int(c.b) != 11
        or Int(c.a) != 255
    ):
        _fail(
            "wire_color_for_type(99) expected (245, 158, 11, 255), got "
            + String(c)
        )

    # And an arbitrarily-large unknown tag should also fall back.
    var c2 = wire_color_for_type(Int32(1234))
    if (
        Int(c2.r) != 245
        or Int(c2.g) != 158
        or Int(c2.b) != 11
        or Int(c2.a) != 255
    ):
        _fail(
            "wire_color_for_type(1234) expected default amber, got "
            + String(c2)
        )
    print("PASS: test_wire_color_for_type_default_amber (2 unknown tags)")


def test_wire_distance_zero_at_endpoint() raises:
    """Distance from a wire to its own start point is ~0 (the polyline
    begins exactly at `from_pos`)."""
    var a = Vec2(Float32(10.0), Float32(10.0))
    var b = Vec2(Float32(200.0), Float32(120.0))
    var d = wire_distance_to_point(a.copy(), b.copy(), a.copy())
    if d > Float32(0.5):
        _fail("distance at start endpoint should be ~0, got " + String(d))
    var d2 = wire_distance_to_point(a.copy(), b.copy(), b.copy())
    if d2 > Float32(0.5):
        _fail("distance at end endpoint should be ~0, got " + String(d2))
    print("PASS: test_wire_distance_zero_at_endpoint")


def test_wire_distance_zero_on_curve() raises:
    """A point sampled ON the drawn bezier (same control-point layout, at
    t=0.5) is within the tessellation error of the polyline (~0)."""
    var a = Vec2(Float32(10.0), Float32(10.0))
    var b = Vec2(Float32(200.0), Float32(120.0))
    # Reconstruct the exact control points draw_wire uses.
    var dx = b.x - a.x
    var ctrl_dx = dx * WIRE_TANGENT_FRAC
    var p0 = a.copy()
    var p1 = Vec2(a.x + ctrl_dx, a.y)
    var p2 = Vec2(b.x - ctrl_dx, b.y)
    var p3 = b.copy()
    var mid = cubic_bezier_point(p0, p1, p2, p3, Float32(0.5))
    var d = wire_distance_to_point(a.copy(), b.copy(), mid.copy())
    if d > Float32(1.0):
        _fail("on-curve midpoint should be ~0 from wire, got " + String(d))
    print("PASS: test_wire_distance_zero_on_curve")


def test_wire_distance_large_when_far() raises:
    """A point far from the wire reports a large distance (well beyond any
    realistic hit threshold)."""
    var a = Vec2(Float32(10.0), Float32(10.0))
    var b = Vec2(Float32(200.0), Float32(120.0))
    var far = Vec2(Float32(10.0), Float32(500.0))
    var d = wire_distance_to_point(a.copy(), b.copy(), far.copy())
    if d < Float32(100.0):
        _fail("far point should be >100px from wire, got " + String(d))
    print("PASS: test_wire_distance_large_when_far")


def main() raises:
    test_bezier_at_t0_returns_p0()
    test_bezier_at_t1_returns_p3()
    test_bezier_at_t05_matches_midpoint_formula()
    test_draw_wire_emits_wire_segments_rects()
    test_draw_wire_thick_respects_thickness()
    test_wire_color_for_type_all_distinct()
    test_wire_color_for_type_default_amber()
    test_wire_distance_zero_at_endpoint()
    test_wire_distance_zero_on_curve()
    test_wire_distance_large_when_far()
    print("PASS: all 10 smoke tests")
