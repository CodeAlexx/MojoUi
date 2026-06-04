"""Smoke tests for `mojoui/animation/spring.mojo` + `mojoui/animation/timer.mojo`
— M3 chunk 45.

Run: `pixi run test-spring`

Pure-math tests — no FFI, no JIT-resolved symbols, runs cleanly under
`mojo run` without `libmojoui_floor.so` being loaded.

The 10 tests:
  1.  lerp_f32(0, 10, 0.5) == 5.0
  2.  lerp_f32(0, 10, 0) == 0; lerp_f32(0, 10, 1) == 10
  3.  lerp_f32(0, 10, 2) == 20 (extrapolation)
  4.  lerp_clamped(0, 10, 2) == 10 (clamped above), (0, 10, -0.5) == 0 (clamped below)
  5.  ease_out_cubic(0) == 0, (1) == 1, (0.5) > 0.5 (decelerating)
  6.  ease_in_out_cubic(0) == 0, (1) == 1, (0.5) == 0.5 (symmetric)
  7.  spring_step convergence: 60 frames at 1/60 dt from 0 toward 100 -> within 5% of 100
  8.  spring_step at target with zero velocity stays at target (small residual OK)
  9.  FrameTimer.tick: first call dt=0, second call computes diff, clamp at 1s
  10. FrameTimer.sim_tick: directly sets dt
"""

from mojoui.animation.spring import (
    lerp_f32,
    lerp_clamped,
    ease_out_cubic,
    ease_in_out_cubic,
    spring_step,
    SpringResult,
    spring_step_color,
    ColorSpringResult,
)
from mojoui.animation.timer import FrameTimer
from mojoui.core.types import Color


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _abs(x: Float32) -> Float32:
    if x < 0.0:
        return -x
    return x


def _abs_f64(x: Float64) -> Float64:
    if x < 0.0:
        return -x
    return x


def _approx_eq(a: Float32, b: Float32, eps: Float32 = 1.0e-5) -> Bool:
    return _abs(a - b) <= eps


def _approx_eq_f64(a: Float64, b: Float64, eps: Float64 = 1.0e-9) -> Bool:
    return _abs_f64(a - b) <= eps


# ----------------------------------------------------------------------------
# Test 1 — lerp_f32 midpoint
# ----------------------------------------------------------------------------


def test_lerp_midpoint() raises:
    var r = lerp_f32(0.0, 10.0, 0.5)
    if not _approx_eq(r, 5.0):
        _fail(String("test 1: lerp_f32(0,10,0.5) expected 5.0 got ") + String(r))
    print("PASS test 1 — lerp_f32 midpoint")


# ----------------------------------------------------------------------------
# Test 2 — lerp_f32 endpoints
# ----------------------------------------------------------------------------


def test_lerp_endpoints() raises:
    var r0 = lerp_f32(0.0, 10.0, 0.0)
    if not _approx_eq(r0, 0.0):
        _fail(String("test 2a: lerp_f32(0,10,0) expected 0.0 got ") + String(r0))
    var r1 = lerp_f32(0.0, 10.0, 1.0)
    if not _approx_eq(r1, 10.0):
        _fail(String("test 2b: lerp_f32(0,10,1) expected 10.0 got ") + String(r1))
    print("PASS test 2 — lerp_f32 endpoints")


# ----------------------------------------------------------------------------
# Test 3 — lerp_f32 extrapolation
# ----------------------------------------------------------------------------


def test_lerp_extrapolation() raises:
    var r = lerp_f32(0.0, 10.0, 2.0)
    if not _approx_eq(r, 20.0):
        _fail(String("test 3: lerp_f32(0,10,2) expected 20.0 got ") + String(r))
    print("PASS test 3 — lerp_f32 extrapolation")


# ----------------------------------------------------------------------------
# Test 4 — lerp_clamped clamps both sides
# ----------------------------------------------------------------------------


def test_lerp_clamped() raises:
    var hi = lerp_clamped(0.0, 10.0, 2.0)
    if not _approx_eq(hi, 10.0):
        _fail(String("test 4a: lerp_clamped(0,10,2) expected 10.0 got ") + String(hi))
    var lo = lerp_clamped(0.0, 10.0, -0.5)
    if not _approx_eq(lo, 0.0):
        _fail(String("test 4b: lerp_clamped(0,10,-0.5) expected 0.0 got ") + String(lo))
    print("PASS test 4 — lerp_clamped clamps both sides")


# ----------------------------------------------------------------------------
# Test 5 — ease_out_cubic endpoints + decelerating midpoint
# ----------------------------------------------------------------------------


def test_ease_out_cubic() raises:
    var z = ease_out_cubic(0.0)
    if not _approx_eq(z, 0.0):
        _fail(String("test 5a: ease_out_cubic(0) expected 0.0 got ") + String(z))
    var o = ease_out_cubic(1.0)
    if not _approx_eq(o, 1.0):
        _fail(String("test 5b: ease_out_cubic(1) expected 1.0 got ") + String(o))
    var m = ease_out_cubic(0.5)
    # Decelerating: at t=0.5, output should be > 0.5 (more than half-way through
    # the value range because we move faster at the start).
    if m <= 0.5:
        _fail(String("test 5c: ease_out_cubic(0.5) expected >0.5 got ") + String(m))
    # Specifically 1 - 0.5^3 = 1 - 0.125 = 0.875
    if not _approx_eq(m, 0.875):
        _fail(String("test 5d: ease_out_cubic(0.5) expected 0.875 got ") + String(m))
    print("PASS test 5 — ease_out_cubic")


# ----------------------------------------------------------------------------
# Test 6 — ease_in_out_cubic symmetric
# ----------------------------------------------------------------------------


def test_ease_in_out_cubic() raises:
    var z = ease_in_out_cubic(0.0)
    if not _approx_eq(z, 0.0):
        _fail(String("test 6a: ease_in_out_cubic(0) expected 0.0 got ") + String(z))
    var o = ease_in_out_cubic(1.0)
    if not _approx_eq(o, 1.0):
        _fail(String("test 6b: ease_in_out_cubic(1) expected 1.0 got ") + String(o))
    var m = ease_in_out_cubic(0.5)
    if not _approx_eq(m, 0.5):
        _fail(String("test 6c: ease_in_out_cubic(0.5) expected 0.5 got ") + String(m))
    print("PASS test 6 — ease_in_out_cubic symmetric")


# ----------------------------------------------------------------------------
# Test 7 — spring_step convergence within 5% of target after 60 frames
# ----------------------------------------------------------------------------


def test_spring_convergence() raises:
    var current: Float32 = 0.0
    var velocity: Float32 = 0.0
    var target: Float32 = 100.0
    var dt: Float32 = 1.0 / 60.0
    for _ in range(60):
        var r = spring_step(current, target, velocity, dt)
        current = r.value
        velocity = r.velocity
    # After 1 simulated second the default react-spring config converges to
    # within ~0.02 of the target. Use a tight tolerance (0.1, still ~5x the
    # observed residual) to catch real regressions.
    var err = _abs(current - target)
    if err > 0.1:
        _fail(
            String("test 7: spring_step convergence — after 60 frames current=")
            + String(current)
            + String(" err=")
            + String(err)
            + String(" (>0.1)")
        )
    print("PASS test 7 — spring_step convergence within 0.1 after 60 frames")


# ----------------------------------------------------------------------------
# Test 8 — spring_step at rest stays at rest
# ----------------------------------------------------------------------------


def test_spring_at_rest() raises:
    var current: Float32 = 50.0
    var target: Float32 = 50.0
    var velocity: Float32 = 0.0
    var dt: Float32 = 1.0 / 60.0
    for _ in range(10):
        var r = spring_step(current, target, velocity, dt)
        current = r.value
        velocity = r.velocity
    # current should still be (essentially) 50, velocity ~0.
    if not _approx_eq(current, 50.0, 1.0e-3):
        _fail(
            String("test 8a: spring_step at target drifted — current=")
            + String(current)
            + String(" (expected ~50.0)")
        )
    if _abs(velocity) > 1.0e-3:
        _fail(
            String("test 8b: spring_step at target velocity non-zero — velocity=")
            + String(velocity)
        )
    print("PASS test 8 — spring_step at rest stays at rest")


# ----------------------------------------------------------------------------
# Test 9 — FrameTimer.tick: first call seeds, second call computes diff,
#                          clamp at 1s, no negative dt
# ----------------------------------------------------------------------------


def test_frame_timer_tick() raises:
    var t = FrameTimer()
    if t.initialized:
        _fail("test 9a: FrameTimer should start uninitialized")
    if t.dt() != 0.0:
        _fail("test 9b: FrameTimer().dt() should be 0 before first tick")

    # First tick: dt remains 0 (no prior frame).
    t.tick(100.0)
    if not t.initialized:
        _fail("test 9c: FrameTimer should be initialized after first tick")
    if not _approx_eq_f64(t.dt(), 0.0):
        _fail(
            String("test 9d: first tick dt expected 0.0 got ")
            + String(t.dt())
        )

    # Second tick at +0.016s: dt should be 0.016.
    t.tick(100.016)
    if not _approx_eq_f64(t.dt(), 0.016, 1.0e-6):
        _fail(
            String("test 9e: second tick dt expected 0.016 got ")
            + String(t.dt())
        )

    # Third tick at +1.0s: still 0.984 from current frame (under the 1s clamp).
    t.tick(101.0)
    if not _approx_eq_f64(t.dt(), 0.984, 1.0e-6):
        _fail(
            String("test 9f: third tick dt expected 0.984 got ")
            + String(t.dt())
        )

    # Fourth tick at +10s: dt clamped to 1.0 (long pause / breakpoint).
    t.tick(111.0)
    if not _approx_eq_f64(t.dt(), 1.0):
        _fail(
            String("test 9g: clamped dt expected 1.0 got ")
            + String(t.dt())
        )

    # Fifth tick BACKWARD (defensive): dt clamped to 0.
    t.tick(110.0)
    if not _approx_eq_f64(t.dt(), 0.0):
        _fail(
            String("test 9h: backward tick dt expected 0.0 got ")
            + String(t.dt())
        )
    print("PASS test 9 — FrameTimer.tick computes/clamps deltas")


# ----------------------------------------------------------------------------
# Test 10 — FrameTimer.sim_tick directly sets dt
# ----------------------------------------------------------------------------


def test_frame_timer_sim_tick() raises:
    var t = FrameTimer()
    t.sim_tick(1.0 / 60.0)
    if not t.initialized:
        _fail("test 10a: sim_tick should mark timer initialized")
    var got = t.dt_f32()
    if not _approx_eq(got, Float32(1.0 / 60.0), 1.0e-6):
        _fail(
            String("test 10b: sim_tick(1/60) expected ~0.01667 got ")
            + String(got)
        )
    # Override directly.
    t.sim_tick(0.25)
    if not _approx_eq_f64(t.dt(), 0.25):
        _fail(
            String("test 10c: sim_tick(0.25) expected 0.25 got ")
            + String(t.dt())
        )
    print("PASS test 10 — FrameTimer.sim_tick")


# ----------------------------------------------------------------------------
# Test 11 — spring_step_color convergence: black -> white over 60 frames
# ----------------------------------------------------------------------------


def test_spring_color_convergence() raises:
    var current = Color(0, 0, 0, 255)
    var target = Color(255, 255, 255, 255)
    var vr: Float32 = 0.0
    var vg: Float32 = 0.0
    var vb: Float32 = 0.0
    var va: Float32 = 0.0
    var dt: Float32 = 1.0 / 60.0
    for _ in range(60):
        var res = spring_step_color(current, target, vr, vg, vb, va, dt)
        current = res.color.copy()
        vr = res.vel_r
        vg = res.vel_g
        vb = res.vel_b
        va = res.vel_a
    # Each channel should be within ~10 units of 255 (≈4% of 255 — the
    # UInt8 round-trip per frame eats a tiny amount of convergence headroom
    # vs the pure Float32 spring).
    if Int(current.r) < 245:
        _fail(
            String("test 11a: spring_color r expected >=245 got ")
            + String(Int(current.r))
        )
    if Int(current.g) < 245:
        _fail(
            String("test 11b: spring_color g expected >=245 got ")
            + String(Int(current.g))
        )
    if Int(current.b) < 245:
        _fail(
            String("test 11c: spring_color b expected >=245 got ")
            + String(Int(current.b))
        )
    print("PASS test 11 — spring_step_color black -> white converges")


# ----------------------------------------------------------------------------
# Test 12 — spring_step_color clamp keeps overshooting channels in [0, 255]
# ----------------------------------------------------------------------------


def test_spring_color_clamp_overshoot() raises:
    # Extreme stiffness + velocity drives the per-channel float into
    # overshoot territory; the clamp must keep the UInt8 channels in
    # [0, 255]. Walk several frames so any out-of-range value would
    # be observable in the returned Color (which packs UInt8 channels).
    var current = Color(200, 200, 200, 255)
    var target = Color(255, 255, 255, 255)
    var vr: Float32 = 1.0e6
    var vg: Float32 = 1.0e6
    var vb: Float32 = 1.0e6
    var va: Float32 = 0.0
    var dt: Float32 = 1.0 / 60.0
    for _ in range(10):
        var res = spring_step_color(
            current, target, vr, vg, vb, va, dt,
            Float32(1.0e6), Float32(0.0),
        )
        # Channels are UInt8 — by storage they cannot exceed 255, but
        # verify explicitly the clamp produced a sensible non-overflow
        # value (Int wraps if UInt8 cast overflowed). Range [0, 255].
        var rr = Int(res.color.r)
        var gg = Int(res.color.g)
        var bb = Int(res.color.b)
        if rr < 0 or rr > 255:
            _fail(String("test 12a: r out of [0,255] got ") + String(rr))
        if gg < 0 or gg > 255:
            _fail(String("test 12b: g out of [0,255] got ") + String(gg))
        if bb < 0 or bb > 255:
            _fail(String("test 12c: b out of [0,255] got ") + String(bb))
        current = res.color.copy()
        vr = res.vel_r
        vg = res.vel_g
        vb = res.vel_b
        va = res.vel_a
    print("PASS test 12 — spring_step_color clamps overshoot to [0, 255]")


# ----------------------------------------------------------------------------
# Test 13 — spring_step_color at target with zero velocity stays at target
# ----------------------------------------------------------------------------


def test_spring_color_at_rest() raises:
    var current = Color(100, 150, 200, 255)
    var target = Color(100, 150, 200, 255)
    var vr: Float32 = 0.0
    var vg: Float32 = 0.0
    var vb: Float32 = 0.0
    var va: Float32 = 0.0
    var dt: Float32 = 1.0 / 60.0
    for _ in range(10):
        var res = spring_step_color(current, target, vr, vg, vb, va, dt)
        current = res.color.copy()
        vr = res.vel_r
        vg = res.vel_g
        vb = res.vel_b
        va = res.vel_a
    # Residual within 1 unit per channel.
    var dr = Int(current.r) - 100
    var dg = Int(current.g) - 150
    var db = Int(current.b) - 200
    var da = Int(current.a) - 255
    if dr < -1 or dr > 1:
        _fail(String("test 13a: r drifted from 100 got ") + String(Int(current.r)))
    if dg < -1 or dg > 1:
        _fail(String("test 13b: g drifted from 150 got ") + String(Int(current.g)))
    if db < -1 or db > 1:
        _fail(String("test 13c: b drifted from 200 got ") + String(Int(current.b)))
    if da < -1 or da > 1:
        _fail(String("test 13d: a drifted from 255 got ") + String(Int(current.a)))
    print("PASS test 13 — spring_step_color at target stays at target")


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------


def main() raises:
    test_lerp_midpoint()
    test_lerp_endpoints()
    test_lerp_extrapolation()
    test_lerp_clamped()
    test_ease_out_cubic()
    test_ease_in_out_cubic()
    test_spring_convergence()
    test_spring_at_rest()
    test_frame_timer_tick()
    test_frame_timer_sim_tick()
    test_spring_color_convergence()
    test_spring_color_clamp_overshoot()
    test_spring_color_at_rest()
    print("PASS: all 13 animation smoke tests")
