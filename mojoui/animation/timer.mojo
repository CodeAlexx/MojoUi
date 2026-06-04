"""Frame-relative time tracking for MojoUI animation primitives.

`FrameTimer` is FED by the application: each frame the app passes a
monotonically-increasing wall-clock time (in seconds) to `tick(wall_time_secs)`,
and the timer computes the per-frame delta available via `dt()`.

Why FED rather than self-sourced: M3 has no portable monotonic-clock FFI yet
(deferred to M5). The C floor knows wall time through sokol_app but that's
plumbed into the app's frame callback signature directly, so a higher layer
(the app loop, or the c47 Context wiring) is the natural place to read it
and forward it here. For pure-Mojo tests/demos that don't have any clock at
all, `sim_tick(dt_secs)` directly sets the delta without any wall-time book-
keeping (the canonical "60 Hz" test idiom is `timer.sim_tick(1.0 / 60.0)`).

Clamps applied in `tick`:
  * dt > 1 second collapses to 1 second (prevents huge jumps after pause/
    breakpoint/window-minimise — every animation snaps forward by at most one
    frame's worth even after a long stall).
  * dt < 0 collapses to 0 (defensive — wall_time should be monotonic, but if
    the caller passes a regressed value we don't want a negative dt poisoning
    the spring integrator).

Owned by the application (or future `Context` wiring in c47). NOT a singleton:
multiple timers can coexist (e.g. one for UI animation, one for a game loop)
without interference.
"""


struct FrameTimer(Movable):
    """Tracks time elapsed since the last frame. Movable-only (Copyable would
    duplicate the timer state and let two callers drift apart silently).

    Per-frame contract:
      * Call `tick(wall_time_secs)` (or `sim_tick(dt_secs)`) ONCE at the start
        of every frame.
      * Read `dt()` (or `dt_f32()`) anywhere downstream for the spring step
        and the per-frame integration.
    """

    var last_wall_time: Float64
    """Most recent wall-clock time reported to `tick`. Undefined before the
    first `tick`/`sim_tick` call (gated by `initialized`)."""

    var current_dt: Float64
    """Most recent delta in seconds. Zero before the first tick + zero on the
    very first tick (no prior reference frame to subtract from)."""

    var initialized: Bool
    """False until the first `tick`/`sim_tick`. Prevents the first call from
    computing a huge bogus delta against the default `last_wall_time = 0`."""

    def __init__(out self):
        self.last_wall_time = 0.0
        self.current_dt = 0.0
        self.initialized = False

    def tick(mut self, wall_time_secs: Float64):
        """Called once at the start of each frame with the current wall-clock
        time (typically from a monotonic OS clock via the app loop).

        First call seeds `last_wall_time` and reports `dt = 0` (no prior
        frame to diff against). Subsequent calls report `dt = wall_time -
        last_wall_time` clamped to `[0, 1]` seconds.
        """
        if not self.initialized:
            self.last_wall_time = wall_time_secs
            self.current_dt = 0.0
            self.initialized = True
            return
        var dt = wall_time_secs - self.last_wall_time
        self.last_wall_time = wall_time_secs
        if dt > 1.0:
            dt = 1.0
        if dt < 0.0:
            dt = 0.0
        self.current_dt = dt

    def sim_tick(mut self, dt_secs: Float64):
        """Test/demo override — set `dt` directly without any wall-time book-
        keeping. The canonical "60 Hz" test pattern is `timer.sim_tick(1.0 /
        60.0)` per simulated frame. Marks the timer initialized."""
        self.current_dt = dt_secs
        self.initialized = True

    def dt(self) -> Float64:
        """Most recent delta in seconds (Float64). Zero before the first tick."""
        return self.current_dt

    def dt_f32(self) -> Float32:
        """Most recent delta in seconds as Float32 (the canonical type for
        spring integration and per-frame UI math)."""
        return Float32(self.current_dt)
