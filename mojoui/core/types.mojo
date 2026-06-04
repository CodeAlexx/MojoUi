"""Core value primitives for MojoUI: Vec2, Rect, Color."""

from std.math import sqrt, floor, min, max


@always_inline
def _round3(x: Float32) -> Float32:
    return floor(x * 1000.0 + 0.5) / 1000.0


struct Vec2(Copyable, Movable, Writable):
    var x: Float32
    var y: Float32

    @always_inline
    def __init__(out self):
        self.x = 0.0
        self.y = 0.0

    @always_inline
    def __init__(out self, x: Float32, y: Float32):
        self.x = x
        self.y = y

    @always_inline
    def __init__(out self, both: Float32):
        self.x = both
        self.y = both

    @staticmethod
    @always_inline
    def zero() -> Vec2:
        return Vec2(0.0, 0.0)

    @staticmethod
    @always_inline
    def one() -> Vec2:
        return Vec2(1.0, 1.0)

    @always_inline
    def __add__(self, other: Vec2) -> Vec2:
        return Vec2(self.x + other.x, self.y + other.y)

    @always_inline
    def __sub__(self, other: Vec2) -> Vec2:
        return Vec2(self.x - other.x, self.y - other.y)

    @always_inline
    def __mul__(self, s: Float32) -> Vec2:
        return Vec2(self.x * s, self.y * s)

    @always_inline
    def __truediv__(self, s: Float32) -> Vec2:
        return Vec2(self.x / s, self.y / s)

    @always_inline
    def __eq__(self, other: Vec2) -> Bool:
        return self.x == other.x and self.y == other.y

    @always_inline
    def __ne__(self, other: Vec2) -> Bool:
        return not self.__eq__(other)

    @always_inline
    def length_sq(self) -> Float32:
        return self.x * self.x + self.y * self.y

    @always_inline
    def length(self) -> Float32:
        return sqrt(self.length_sq())

    def normalized(self) -> Vec2:
        var l = self.length()
        if l == 0.0:
            return Vec2(0.0, 0.0)
        return Vec2(self.x / l, self.y / l)

    @always_inline
    def dot(self, other: Vec2) -> Float32:
        return self.x * other.x + self.y * other.y

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Vec2(", _round3(self.x), ", ", _round3(self.y), ")")


struct Rect(Copyable, Movable, Writable):
    var x: Float32
    var y: Float32
    var w: Float32
    var h: Float32

    @always_inline
    def __init__(out self):
        self.x = 0.0
        self.y = 0.0
        self.w = 0.0
        self.h = 0.0

    @always_inline
    def __init__(out self, x: Float32, y: Float32, w: Float32, h: Float32):
        self.x = x
        self.y = y
        self.w = w
        self.h = h

    @staticmethod
    def from_min_max(min: Vec2, max: Vec2) -> Rect:
        return Rect(min.x, min.y, max.x - min.x, max.y - min.y)

    @staticmethod
    def from_center_size(center: Vec2, size: Vec2) -> Rect:
        return Rect(
            center.x - size.x * 0.5,
            center.y - size.y * 0.5,
            size.x,
            size.y,
        )

    @always_inline
    def right(self) -> Float32:
        return self.x + self.w

    @always_inline
    def bottom(self) -> Float32:
        return self.y + self.h

    @always_inline
    def min(self) -> Vec2:
        return Vec2(self.x, self.y)

    @always_inline
    def max(self) -> Vec2:
        return Vec2(self.right(), self.bottom())

    @always_inline
    def center(self) -> Vec2:
        return Vec2(self.x + self.w * 0.5, self.y + self.h * 0.5)

    @always_inline
    def size(self) -> Vec2:
        return Vec2(self.w, self.h)

    @always_inline
    def is_empty(self) -> Bool:
        return self.w <= 0.0 or self.h <= 0.0

    def contains(self, p: Vec2) -> Bool:
        return (
            p.x >= self.x
            and p.x <= self.right()
            and p.y >= self.y
            and p.y <= self.bottom()
        )

    def intersects(self, other: Rect) -> Bool:
        return not (
            self.right() < other.x
            or other.right() < self.x
            or self.bottom() < other.y
            or other.bottom() < self.y
        )

    def intersect(self, other: Rect) -> Rect:
        var x0 = max(self.x, other.x)
        var y0 = max(self.y, other.y)
        var x1 = min(self.right(), other.right())
        var y1 = min(self.bottom(), other.bottom())
        var w = x1 - x0
        var h = y1 - y0
        if w < 0.0:
            w = 0.0
        if h < 0.0:
            h = 0.0
        return Rect(x0, y0, w, h)

    def union(self, other: Rect) -> Rect:
        var x0 = min(self.x, other.x)
        var y0 = min(self.y, other.y)
        var x1 = max(self.right(), other.right())
        var y1 = max(self.bottom(), other.bottom())
        return Rect(x0, y0, x1 - x0, y1 - y0)

    def inflate(self, dx: Float32, dy: Float32) -> Rect:
        return Rect(self.x - dx, self.y - dy, self.w + dx * 2.0, self.h + dy * 2.0)

    def offset(self, dx: Float32, dy: Float32) -> Rect:
        return Rect(self.x + dx, self.y + dy, self.w, self.h)

    def __eq__(self, other: Rect) -> Bool:
        return (
            self.x == other.x
            and self.y == other.y
            and self.w == other.w
            and self.h == other.h
        )

    def __ne__(self, other: Rect) -> Bool:
        return not self.__eq__(other)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "Rect(",
            _round3(self.x),
            ", ",
            _round3(self.y),
            ", ",
            _round3(self.w),
            ", ",
            _round3(self.h),
            ")",
        )


struct Color(Copyable, Movable, Writable):
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    @always_inline
    def __init__(out self):
        self.r = 0
        self.g = 0
        self.b = 0
        self.a = 0

    @always_inline
    def __init__(out self, r: UInt8, g: UInt8, b: UInt8):
        self.r = r
        self.g = g
        self.b = b
        self.a = 255

    @always_inline
    def __init__(out self, r: UInt8, g: UInt8, b: UInt8, a: UInt8):
        self.r = r
        self.g = g
        self.b = b
        self.a = a

    @staticmethod
    def from_rgb_hex(hex: UInt32) -> Color:
        var r = UInt8((hex >> 16) & 0xFF)
        var g = UInt8((hex >> 8) & 0xFF)
        var b = UInt8(hex & 0xFF)
        return Color(r, g, b, 255)

    @staticmethod
    def from_rgba_hex(hex: UInt32) -> Color:
        var r = UInt8((hex >> 24) & 0xFF)
        var g = UInt8((hex >> 16) & 0xFF)
        var b = UInt8((hex >> 8) & 0xFF)
        var a = UInt8(hex & 0xFF)
        return Color(r, g, b, a)

    @staticmethod
    @always_inline
    def white() -> Color:
        return Color(255, 255, 255, 255)

    @staticmethod
    @always_inline
    def black() -> Color:
        return Color(0, 0, 0, 255)

    @staticmethod
    @always_inline
    def transparent() -> Color:
        return Color(0, 0, 0, 0)

    def to_u32_rgba(self) -> UInt32:
        return (
            (UInt32(self.r) << 24)
            | (UInt32(self.g) << 16)
            | (UInt32(self.b) << 8)
            | UInt32(self.a)
        )

    @always_inline
    def with_alpha(self, a: UInt8) -> Color:
        return Color(self.r, self.g, self.b, a)

    def lerp(self, other: Color, t: Float32) -> Color:
        var tt = t
        if tt < 0.0:
            tt = 0.0
        if tt > 1.0:
            tt = 1.0
        var r = Float32(Int(self.r)) + (Float32(Int(other.r)) - Float32(Int(self.r))) * tt
        var g = Float32(Int(self.g)) + (Float32(Int(other.g)) - Float32(Int(self.g))) * tt
        var b = Float32(Int(self.b)) + (Float32(Int(other.b)) - Float32(Int(self.b))) * tt
        var a = Float32(Int(self.a)) + (Float32(Int(other.a)) - Float32(Int(self.a))) * tt
        return Color(UInt8(Int(r)), UInt8(Int(g)), UInt8(Int(b)), UInt8(Int(a)))

    def __eq__(self, other: Color) -> Bool:
        return (
            self.r == other.r
            and self.g == other.g
            and self.b == other.b
            and self.a == other.a
        )

    def __ne__(self, other: Color) -> Bool:
        return not self.__eq__(other)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "Color(",
            Int(self.r),
            ", ",
            Int(self.g),
            ", ",
            Int(self.b),
            ", ",
            Int(self.a),
            ")",
        )
