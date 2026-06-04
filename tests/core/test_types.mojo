"""Smoke tests for mojoui.core.types."""

from std.math import sqrt
from mojoui.core.types import Vec2, Rect, Color


def _abs_f32(x: Float32) -> Float32:
    if x < 0.0:
        return -x
    return x


def main() raises:
    var failures = 0

    # 1) Vec2 arithmetic
    var a = Vec2(1.0, 2.0) + Vec2(3.0, 4.0)
    if not (a == Vec2(4.0, 6.0)):
        print("FAIL: Vec2 add (1,2)+(3,4) =>", String(a))
        failures += 1

    var b = Vec2(5.0, 5.0) - Vec2(2.0, 3.0)
    if not (b == Vec2(3.0, 2.0)):
        print("FAIL: Vec2 sub (5,5)-(2,3) =>", String(b))
        failures += 1

    var c = Vec2(2.0, 3.0) * Float32(4.0)
    if not (c == Vec2(8.0, 12.0)):
        print("FAIL: Vec2 mul (2,3)*4 =>", String(c))
        failures += 1

    # 2) Vec2 length: (3,4) -> 5
    var l = Vec2(3.0, 4.0).length()
    if _abs_f32(l - 5.0) > Float32(1e-5):
        print("FAIL: Vec2.length (3,4) =>", l)
        failures += 1

    # 3) Rect.contains
    var r10 = Rect(0.0, 0.0, 10.0, 10.0)
    if not r10.contains(Vec2(5.0, 5.0)):
        print("FAIL: Rect.contains(5,5) should be True")
        failures += 1
    if r10.contains(Vec2(15.0, 15.0)):
        print("FAIL: Rect.contains(15,15) should be False")
        failures += 1

    # 4) Rect.intersects
    if not r10.intersects(Rect(5.0, 5.0, 10.0, 10.0)):
        print("FAIL: Rect intersects(5,5,10,10) should be True")
        failures += 1
    if r10.intersects(Rect(20.0, 20.0, 5.0, 5.0)):
        print("FAIL: Rect intersects(20,20,5,5) should be False")
        failures += 1

    # 5) Rect.intersect
    var ix = r10.intersect(Rect(5.0, 5.0, 10.0, 10.0))
    var want_ix = Rect(5.0, 5.0, 5.0, 5.0)
    if not (ix == want_ix):
        print("FAIL: Rect.intersect =>", String(ix))
        failures += 1

    # 6) Color.from_rgb_hex(0xFF8800) -> r=255 g=136 b=0 a=255
    var col = Color.from_rgb_hex(0xFF8800)
    if not (Int(col.r) == 255 and Int(col.g) == 136 and Int(col.b) == 0 and Int(col.a) == 255):
        print("FAIL: Color.from_rgb_hex(0xFF8800) =>", String(col))
        failures += 1

    # 7) Color round-trip via rgba hex
    var packed: UInt32 = 0xDEADBEEF
    var rt = Color.from_rgba_hex(packed).to_u32_rgba()
    if rt != packed:
        print("FAIL: Color rgba round-trip =>", rt)
        failures += 1

    # 8) Color.lerp(black, white, 0.5) -> (127,127,127,255)
    var mid = Color.black().lerp(Color.white(), Float32(0.5))
    if not (Int(mid.r) == 127 and Int(mid.g) == 127 and Int(mid.b) == 127 and Int(mid.a) == 255):
        print("FAIL: Color.lerp(black,white,0.5) =>", String(mid))
        failures += 1

    # Trait conformance: put values into Lists (exercises Copyable+Movable)
    var vlist: List[Vec2] = [Vec2(1.0, 2.0), Vec2(3.0, 4.0)]
    var rlist: List[Rect] = [Rect(0.0, 0.0, 1.0, 1.0)]
    var clist: List[Color] = [Color.white(), Color.black()]
    if len(vlist) != 2 or len(rlist) != 1 or len(clist) != 2:
        print("FAIL: List trait conformance lengths")
        failures += 1

    # Writable: just verify str conversion doesn't crash
    var _s1 = String(Vec2(1.0, 2.0))
    var _s2 = String(Rect(0.0, 0.0, 10.0, 10.0))
    var _s3 = String(Color.white())

    if failures == 0:
        print("PASS: all", 8, "smoke tests")
    else:
        print("FAILED:", failures, "test(s)")
        raise Error("test_types failures")
