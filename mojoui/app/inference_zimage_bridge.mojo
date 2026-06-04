"""Bridge between the m8 inference UI state and the Z-Image worker seam.

This module is FFI-free and GPU-free by default. It keeps the app-level queue
and progress model in `InferenceState`, while the backend-specific work is
owned by `ZImageWorker`. The only production backend switch remains in
`_zimage_backend.mojo`.
"""

from mojoui.app.inference_model import (
    InferenceState,
    QueueJob,
    HistoryItem,
    _color_seed_for,
)
from mojoui.app.zimage_worker import (
    ZImageWorker,
    ZImageJob,
    zimage_start,
    zimage_tick,
    zimage_cancel,
    ZW_STARTED,
    ZW_PROGRESS,
    ZW_DONE,
    ZW_FAILED,
)


struct ZImageUiRuntime(Movable):
    """Live-only Z-Image UI runtime.

    `queued_jobs` mirrors `InferenceState.queued` with backend-complete job
    snapshots. Keep it here instead of extending QueueJob with backend-only
    fields, so the visible queue stays model-neutral for future graph/trainer
    jobs.
    """

    var worker: ZImageWorker
    var event_cursor: Int
    var queued_jobs: List[ZImageJob]

    # Last completed decoded image, copied out of the worker before any queued
    # job can reuse/reset the worker result.
    var result_pixels: List[UInt8]
    var result_width: Int
    var result_height: Int
    var result_job_id: UInt64
    var uploaded_job_id: UInt64
    var texture_id: UInt32

    def __init__(out self):
        self.worker = ZImageWorker()
        self.event_cursor = 0
        self.queued_jobs = List[ZImageJob]()
        self.result_pixels = List[UInt8]()
        self.result_width = 0
        self.result_height = 0
        self.result_job_id = 0
        self.uploaded_job_id = 0
        self.texture_id = UInt32(0)


def _steps_from_state(state: InferenceState) -> Int32:
    var steps_i = Int32(Int(state.steps))
    if steps_i < Int32(1):
        steps_i = Int32(1)
    return steps_i


def _seed_from_state(state: InferenceState) -> Int64:
    return Int64(Int(state.seed))


def _snapshot_display_job(state: InferenceState) -> QueueJob:
    var seed_i64 = _seed_from_state(state)
    var steps_i = _steps_from_state(state)
    return QueueJob(
        state.next_job_id,
        state.prompt.copy(),
        Int32(Int(state.width)),
        Int32(Int(state.height)),
        steps_i,
        state.sampler_label(),
        seed_i64,
        _color_seed_for(state.prompt, seed_i64, state.next_job_id),
    )


def _snapshot_backend_job(state: InferenceState, display: QueueJob) -> ZImageJob:
    return ZImageJob(
        display.id,
        display.prompt.copy(),
        state.negative.copy(),
        Int(display.steps),
        state.cfg,
        display.seed,
        Int(display.width),
        Int(display.height),
        display.color_seed,
    )


def _mirror_started(mut state: InferenceState, total_steps: Int):
    state.generating = True
    state.current_step = 0
    state.total_steps = Int32(total_steps)
    state.frame_counter = 0
    state.result_ready = False
    state.perf.gpu_util_pct = 62.0
    if state.has_running:
        state.running.current_step = 0
        state.running.steps = Int32(total_steps)


def _finish_failed(mut state: InferenceState):
    state.has_running = False
    state.generating = False
    state.current_step = 0
    state.total_steps = 0
    state.frame_counter = 0
    state.perf.gpu_util_pct = 0.0


def _start_pair(mut state: InferenceState, mut rt: ZImageUiRuntime, var display: QueueJob, var backend: ZImageJob):
    state.running = display^
    state.running.current_step = 0
    state.has_running = True
    state.generating = True
    state.current_step = 0
    state.total_steps = state.running.steps
    state.frame_counter = 0
    state.result_ready = False
    state.perf.gpu_util_pct = 62.0

    rt.event_cursor = len(rt.worker.events)
    zimage_start(rt.worker, backend^)
    zimage_drain_events(state, rt)


def _start_next(mut state: InferenceState, mut rt: ZImageUiRuntime):
    if len(state.queued) == 0 or len(rt.queued_jobs) == 0:
        return
    var display = state.queued[0].copy()
    var backend = rt.queued_jobs[0].copy()

    var rest_display = List[QueueJob]()
    for i in range(1, len(state.queued)):
        rest_display.append(state.queued[i].copy())
    state.queued = rest_display^

    var rest_backend = List[ZImageJob]()
    for i in range(1, len(rt.queued_jobs)):
        rest_backend.append(rt.queued_jobs[i].copy())
    rt.queued_jobs = rest_backend^

    _start_pair(state, rt, display^, backend^)


def zimage_submit_current(mut state: InferenceState, mut rt: ZImageUiRuntime):
    """Snapshot current UI params and submit a Z-Image job.

    If another job is running, append to both the visible queue and the backend
    queue. Otherwise start immediately.
    """
    var display = _snapshot_display_job(state)
    var backend = _snapshot_backend_job(state, display)
    state.next_job_id = state.next_job_id + 1

    if state.has_running or rt.worker.running:
        state.queued.append(display^)
        rt.queued_jobs.append(backend^)
    else:
        _start_pair(state, rt, display^, backend^)


def zimage_cancel_all(mut state: InferenceState, mut rt: ZImageUiRuntime):
    """Cancel the active job and drop queued backend/display jobs."""
    state.queued = List[QueueJob]()
    rt.queued_jobs = List[ZImageJob]()
    if rt.worker.running:
        zimage_cancel(rt.worker)
        zimage_tick(rt.worker)
        zimage_drain_events(state, rt)
    else:
        _finish_failed(state)


def zimage_drain_events(mut state: InferenceState, mut rt: ZImageUiRuntime):
    """Apply worker events emitted since the last drain to the visible UI state."""
    while rt.event_cursor < len(rt.worker.events):
        var ev = rt.worker.events[rt.event_cursor].copy()
        rt.event_cursor = rt.event_cursor + 1

        if ev.kind == ZW_STARTED:
            _mirror_started(state, ev.total)
        elif ev.kind == ZW_PROGRESS:
            state.current_step = Int32(ev.step)
            state.total_steps = Int32(ev.total)
            if state.has_running:
                state.running.current_step = Int32(ev.step)
                state.running.steps = Int32(ev.total)
        elif ev.kind == ZW_DONE:
            if rt.worker.has_result and rt.worker.result.ok:
                rt.result_pixels = rt.worker.result.pixels.copy()
                rt.result_width = rt.worker.result.width
                rt.result_height = rt.worker.result.height
                rt.result_job_id = ev.id
            if state.has_running:
                var item = HistoryItem(
                    state.running.id,
                    state.running.prompt.copy(),
                    state.running.seed,
                    state.running.color_seed,
                )
                state.history.append(item^)
            state.has_running = False
            state.generating = False
            state.current_step = state.total_steps
            state.result_ready = True
            state.perf.gpu_util_pct = 0.0
            _start_next(state, rt)
        elif ev.kind == ZW_FAILED:
            _finish_failed(state)


def zimage_tick_and_apply(mut state: InferenceState, mut rt: ZImageUiRuntime):
    """Advance the worker one frame and apply any new events."""
    zimage_tick(rt.worker)
    zimage_drain_events(state, rt)


def zimage_progress_fraction(state: InferenceState) -> Float32:
    if state.total_steps <= 0:
        return 0.0
    var f = Float32(Int(state.current_step)) / Float32(Int(state.total_steps))
    if f > 1.0:
        return 1.0
    return f
