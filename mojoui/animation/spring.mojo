"""Animation primitives — lerp, easing, and spring physics for MojoUI.

Pure-math, no FFI, no global state. All functions are caller-stateless:
spring integration returns the new `(value, velocity)` pair and the caller is
responsible for storing the velocity between frames (typically alongside the
animated value in widget-local state — c47 will wire `id -> velocity` into
Context).

Default spring constants (`stiffness=170`, `damping=26`) match react-spring's
"default" config — a snappy, near-critically-damped UI feel. Increase
`stiffness` for snappier motion, increase `damping` for less oscillation.
For a critically-damped spring at a given stiffness `k`, set `damping = 2 *
sqrt(k)` (so k=170 gives damping ≈ 26.08).
"""

from mojoui.core.types import Color


# ============================================================================
# Linear interpolation
# ============================================================================


def lerp_f32(a: Float32, b: Float32, t: Float32) -> Float32:
    """Linear interpolation between `a` and `b` at parameter `t`.

    `t = 0` returns `a`; `t = 1` returns `b`; values outside `[0, 1]`
    extrapolate (useful for momentum / overshoot effects).
    """
    return a + (b - a) * t


def lerp_clamped(a: Float32, b: Float32, t: Float32) -> Float32:
    """Linear interpolation with `t` clamped to `[0, 1]` so the result never
    leaves the `[a, b]` (or `[b, a]`) interval."""
    var tc = t
    if tc < 0.0:
        tc = 0.0
    if tc > 1.0:
        tc = 1.0
    return a + (b - a) * tc


# ============================================================================
# Easing functions (all operate on t in [0, 1] -> output in [0, 1])
# ============================================================================


def ease_out_cubic(t: Float32) -> Float32:
    """Cubic easing-out: fast start, slow end. `ease(0) = 0`, `ease(1) = 1`,
    decelerating curve. Useful for "settle-in" UI motion (e.g. a panel
    sliding to rest)."""
    var u = 1.0 - t
    return 1.0 - u * u * u


def ease_in_out_cubic(t: Float32) -> Float32:
    """Symmetric cubic easing: slow start, fast middle, slow end. `ease(0) =
    0`, `ease(0.5) = 0.5`, `ease(1) = 1`. The S-curve shape is the default
    "natural-feel" easing for value-change transitions."""
    if t < 0.5:
        return 4.0 * t * t * t
    var p = 2.0 * t - 2.0
    return 1.0 + p * p * p * 0.5


# ============================================================================
# Spring physics (mass-spring-damper with mass=1, implicit Euler)
# ============================================================================


struct SpringResult(Copyable, Movable):
    """Output of a single `spring_step` — the new value and velocity to feed
    back into the next call. POD; auto-copy via the Copyable conformance."""

    var value: Float32
    var velocity: Float32

    def __init__(out self):
        self.value = 0.0
        self.velocity = 0.0

    def __init__(out self, value: Float32, velocity: Float32):
        self.value = value
        self.velocity = velocity


def spring_step(
    current: Float32,
    target: Float32,
    velocity: Float32,
    dt: Float32,
    stiffness: Float32 = 170.0,
    damping: Float32 = 26.0,
) -> SpringResult:
    """One implicit-Euler step of a mass-spring-damper system with mass=1.

    Algorithm:
        force        = stiffness * (target - current) - damping * velocity
        new_velocity = velocity + force * dt
        new_value    = current + new_velocity * dt

    Defaults `stiffness=170`, `damping=26` match react-spring's "default"
    config — snappy near-critically-damped feel. Caller stores the returned
    `(value, velocity)` pair for the next frame; first call uses
    `velocity = 0`.
    """
    var force = stiffness * (target - current) - damping * velocity
    var new_velocity = velocity + force * dt
    var new_value = current + new_velocity * dt
    return SpringResult(new_value, new_velocity)


# ----------------------------------------------------------------------------
# Per-channel Color spring (RGBA via four independent Float32 velocities)
# ----------------------------------------------------------------------------
#
# We pass the 4 channel velocities as separate Float32 parameters rather than
# a SIMD[DType.float32, 4] because (a) the SIMD construction syntax in
# current Mojo beta is awkward at module boundaries (the explicit
# four-argument constructor `SIMD[DType.float32, 4](r, g, b, a)` works in
# some contexts but not others), and (b) the call-site ergonomics are
# essentially identical: callers store 4 Float32 velocity scalars next to
# the Color regardless of the wire format. If a future beta makes SIMD
# packing more ergonomic the API can grow a `spring_step_color_simd`
# variant without breaking this one.


struct ColorSpringResult(Copyable, Movable):
    """Output of a `spring_step_color` — the new Color and the four per-
    channel velocities (R, G, B, A) to feed back into the next call."""

    var color: Color
    var vel_r: Float32
    var vel_g: Float32
    var vel_b: Float32
    var vel_a: Float32

    def __init__(out self):
        self.color = Color()
        self.vel_r = 0.0
        self.vel_g = 0.0
        self.vel_b = 0.0
        self.vel_a = 0.0

    def __init__(
        out self,
        color: Color,
        vel_r: Float32,
        vel_g: Float32,
        vel_b: Float32,
        vel_a: Float32,
    ):
        self.color = color.copy()
        self.vel_r = vel_r
        self.vel_g = vel_g
        self.vel_b = vel_b
        self.vel_a = vel_a


def spring_step_color(
    current: Color,
    target: Color,
    vel_r: Float32,
    vel_g: Float32,
    vel_b: Float32,
    vel_a: Float32,
    dt: Float32,
    stiffness: Float32 = 170.0,
    damping: Float32 = 26.0,
) -> ColorSpringResult:
    """Per-channel spring on an RGBA `Color`. Channels integrate independ-
    ently; each result is clamped to `[0, 255]` before being repacked into
    the UInt8 Color storage. Caller stores the four velocity scalars next
    to the Color for the next call.
    """
    var cur_r = Float32(Int(current.r))
    var cur_g = Float32(Int(current.g))
    var cur_b = Float32(Int(current.b))
    var cur_a = Float32(Int(current.a))
    var tgt_r = Float32(Int(target.r))
    var tgt_g = Float32(Int(target.g))
    var tgt_b = Float32(Int(target.b))
    var tgt_a = Float32(Int(target.a))

    var sr = spring_step(cur_r, tgt_r, vel_r, dt, stiffness, damping)
    var sg = spring_step(cur_g, tgt_g, vel_g, dt, stiffness, damping)
    var sb = spring_step(cur_b, tgt_b, vel_b, dt, stiffness, damping)
    var sa = spring_step(cur_a, tgt_a, vel_a, dt, stiffness, damping)

    var nr = sr.value
    if nr < 0.0:
        nr = 0.0
    if nr > 255.0:
        nr = 255.0
    var ng = sg.value
    if ng < 0.0:
        ng = 0.0
    if ng > 255.0:
        ng = 255.0
    var nb = sb.value
    if nb < 0.0:
        nb = 0.0
    if nb > 255.0:
        nb = 255.0
    var na = sa.value
    if na < 0.0:
        na = 0.0
    if na > 255.0:
        na = 255.0

    var new_color = Color(UInt8(Int(nr)), UInt8(Int(ng)), UInt8(Int(nb)), UInt8(Int(na)))
    return ColorSpringResult(new_color^, sr.velocity, sg.velocity, sb.velocity, sa.velocity)
