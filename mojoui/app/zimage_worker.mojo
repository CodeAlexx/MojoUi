"""MojoUI m8 — real Z-Image worker (mirrors inference-flame worker/zimage.rs).

FFI-FREE, `mojo run`-testable protocol + state machine for the REAL Z-Image
backend, kept SEPARATE from the default mock worker in `inference_model.mojo`.
The mock stays the m8 default (so `pixi run inference` builds without
serenitymojo); this worker is opt-in behind the `_zimage_backend` adapter seam.

## Protocol (mirrors worker/zimage.rs run()/run_inner)

  Started{id, total_steps}
    → Progress{id, step, total}  per denoise step (cancel-check BETWEEN steps)
    → Done{id} (decoded image attached) | Failed{id, error}

Honors job.steps / job.cfg / job.seed / job.width / job.height (the user's
panel values win; the Rust reference's variant defaults are a fallback when a
field is 0 / ≤0). Like the mock, the actual stepping is FRAME-DRIVEN — the m8
frame loop calls `zimage_tick(worker)` once per frame — so there are no threads.
The serenitymojo `zimage_generate` is a single blocking GPU call; in this
frame-driven shell we model it as: emit Started, advance one logical step per
N frames emitting Progress, then on the final step invoke the adapter and emit
Done (or Failed). When the real backend is wired, the adapter's blocking call
replaces the per-step simulation (the events still fire; see Z-Image wiring notes).

## Cancel policy

Cancel is checked BETWEEN steps only (matches the Rust `drain_pending` between
denoise steps). `zimage_cancel(worker)` sets a cooperative flag; the next tick
emits Failed{"cancelled"} and stops.
"""

from mojoui.app._zimage_backend import (
    ZImageResult,
    adapter_zimage_generate,
    backend_is_real,
)


# ---------------------------------------------------------------------------
# Event kinds (mirror WorkerEvent::{Started,Progress,Done,Failed}).
# ---------------------------------------------------------------------------

comptime ZW_STARTED: Int = 0
comptime ZW_PROGRESS: Int = 1
comptime ZW_DONE: Int = 2
comptime ZW_FAILED: Int = 3

comptime ZW_FRAMES_PER_STEP: Int = 6
"""Frames between logical denoise steps (matches the mock FRAMES_PER_STEP)."""

# Variant defaults (mirror ZImageVariant::default_steps/default_cfg for Base).
comptime ZW_DEFAULT_STEPS: Int = 28
comptime ZW_DEFAULT_CFG: Float32 = 4.0


# ---------------------------------------------------------------------------
# ZImageJob — param snapshot the worker runs (mirrors GenerateJob fields the
# Rust worker reads: id/prompt/negative/steps/cfg/seed/width/height).
# ---------------------------------------------------------------------------


struct ZImageJob(Copyable, Movable):
    var id: UInt64
    var prompt: String
    var negative: String
    var steps: Int
    var cfg: Float32
    var seed: Int64
    var width: Int
    var height: Int
    var color_seed: UInt32

    def __init__(
        out self,
        id: UInt64,
        prompt: String,
        negative: String,
        steps: Int,
        cfg: Float32,
        seed: Int64,
        width: Int,
        height: Int,
        color_seed: UInt32,
    ):
        self.id = id
        self.prompt = prompt
        self.negative = negative
        # Honor job values; fall back to Base defaults like the Rust worker.
        self.steps = steps if steps > 0 else ZW_DEFAULT_STEPS
        self.cfg = cfg if cfg > Float32(0.0) else ZW_DEFAULT_CFG
        self.seed = seed
        self.width = width
        self.height = height
        self.color_seed = color_seed


# ---------------------------------------------------------------------------
# ZImageEvent — one protocol event (drained by the m8 frame loop / tests).
# ---------------------------------------------------------------------------


struct ZImageEvent(Copyable, Movable):
    var kind: Int      # ZW_STARTED | ZW_PROGRESS | ZW_DONE | ZW_FAILED
    var id: UInt64
    var step: Int      # 1-based step for ZW_PROGRESS, else 0
    var total: Int
    var message: String

    def __init__(out self, kind: Int, id: UInt64, step: Int, total: Int, message: String):
        self.kind = kind
        self.id = id
        self.step = step
        self.total = total
        self.message = message


# ---------------------------------------------------------------------------
# ZImageWorker — the real-backend state machine. Frame-driven, no threads.
# ---------------------------------------------------------------------------


struct ZImageWorker(Movable):
    var has_job: Bool
    var job: ZImageJob
    var running: Bool
    var done: Bool
    var failed: Bool
    var cancel_requested: Bool
    var current_step: Int
    var total_steps: Int
    var frame_counter: Int
    var events: List[ZImageEvent]   # appended-to; caller drains
    var result: ZImageResult        # valid when `done`
    var has_result: Bool

    def __init__(out self):
        self.has_job = False
        self.job = ZImageJob(0, String(""), String(""), 0, Float32(0.0), -1, 1024, 1024, 0)
        self.running = False
        self.done = False
        self.failed = False
        self.cancel_requested = False
        self.current_step = 0
        self.total_steps = 0
        self.frame_counter = 0
        self.events = List[ZImageEvent]()
        var empty = List[UInt8]()
        self.result = ZImageResult(0, 0, empty^)
        self.has_result = False


# ---------------------------------------------------------------------------
# Worker actions (mirror run() / drain_pending / Done|Failed).
# ---------------------------------------------------------------------------


def zimage_start(mut w: ZImageWorker, var job: ZImageJob):
    """Begin a job: emit Started, arm the per-step driver. Mirrors the Rust
    `run()` Started send + steps/cfg resolution (already done in ZImageJob)."""
    w.total_steps = job.steps
    w.job = job^
    w.has_job = True
    w.running = True
    w.done = False
    w.failed = False
    w.cancel_requested = False
    w.current_step = 0
    w.frame_counter = 0
    w.has_result = False
    w.events.append(
        ZImageEvent(ZW_STARTED, w.job.id, 0, w.total_steps, String("started"))
    )


def zimage_cancel(mut w: ZImageWorker):
    """Cooperative cancel (checked between steps, matching drain_pending)."""
    if w.running:
        w.cancel_requested = True


def _finish_failed(mut w: ZImageWorker, msg: String):
    w.running = False
    w.failed = True
    w.events.append(ZImageEvent(ZW_FAILED, w.job.id, 0, w.total_steps, msg))


def _finish_done(mut w: ZImageWorker):
    """Invoke the backend adapter and emit Done with the decoded image. In stub
    mode this returns a deterministic gradient; under the real backend it calls
    serenitymojo's zimage_generate (see _zimage_backend)."""
    var res = adapter_zimage_generate(
        w.job.prompt, w.job.negative,
        w.job.steps, w.job.cfg, w.job.seed,
        w.job.width, w.job.height, w.job.color_seed,
    )
    if not res.ok:
        _finish_failed(w, res.error)
        return
    w.result = res^
    w.has_result = True
    w.running = False
    w.done = True
    w.current_step = w.total_steps
    w.events.append(ZImageEvent(ZW_DONE, w.job.id, w.total_steps, w.total_steps, String("done")))


def zimage_tick(mut w: ZImageWorker):
    """Advance the worker one frame. No-op when not running. Cancel is honored
    BETWEEN steps (matches the Rust drain_pending placement). Every
    ZW_FRAMES_PER_STEP frames advances one logical denoise step and emits
    Progress; on reaching total_steps it invokes the backend + emits Done."""
    if not w.running:
        return
    # Cancel-check between steps (before advancing).
    if w.cancel_requested:
        _finish_failed(w, String("cancelled"))
        return
    w.frame_counter = w.frame_counter + 1
    if w.frame_counter < ZW_FRAMES_PER_STEP:
        return
    w.frame_counter = 0
    if w.current_step < w.total_steps:
        w.current_step = w.current_step + 1
        w.events.append(
            ZImageEvent(ZW_PROGRESS, w.job.id, w.current_step, w.total_steps, String("denoise"))
        )
    if w.current_step >= w.total_steps:
        _finish_done(w)


def zimage_progress_fraction(w: ZImageWorker) -> Float32:
    """0.0..1.0 of the running job (0 when idle)."""
    if w.total_steps <= 0:
        return 0.0
    var f = Float32(w.current_step) / Float32(w.total_steps)
    if f > 1.0:
        return 1.0
    return f


def zimage_drain_event_kinds(w: ZImageWorker) -> List[Int]:
    """Snapshot of emitted event kinds in order (for tests / UI mapping)."""
    var out = List[Int]()
    for i in range(len(w.events)):
        out.append(w.events[i].kind)
    return out^
