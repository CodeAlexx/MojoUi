"""CPU-only trainer runtime bridge for MojoUI trainer screens.

This is a frame-driven stub backend. It does not train a model; it emits the
same normalized job events a real trainer adapter should emit later. That lets
the trainer UI be built and tested before `mojodiffusion` is ready.
"""

from mojoui.app.job_runtime import (
    JobRuntime,
    ArtifactRef,
    JOB_KIND_TRAINER,
    JOB_PHASE_RUNNING,
    JOB_PHASE_PAUSED,
    ARTIFACT_IMAGE,
    ARTIFACT_CHECKPOINT,
    ARTIFACT_METRICS,
    JOB_LOG_INFO,
    JOB_LOG_WARN,
    submit_job,
    start_job,
    update_progress,
    add_artifact,
    add_log,
    complete_job,
    cancel_job,
    pause_job,
    resume_job,
    job_progress,
    find_job_index,
)
from mojoui.app.model_backend import (
    TrainerRequest,
    TrainerBackendCommand,
    TRAINER_BACKEND_CMD_SUBMIT,
    TRAINER_BACKEND_CMD_PAUSE,
    TRAINER_BACKEND_CMD_RESUME,
    TRAINER_BACKEND_CMD_CANCEL,
    TRAINER_BACKEND_CMD_SAMPLE_NOW,
    TRAINER_BACKEND_CMD_SAVE_CHECKPOINT,
    make_trainer_capability,
    validate_trainer_request,
    backend_validation_error_count,
    backend_validation_summary,
    trainer_total_steps,
    trainer_job_label,
)
from mojoui.app.trainer_model import TrainerState, trainer_request_from_state


comptime TRAINER_FRAMES_PER_STEP: Int32 = 4


struct TrainerLiveStats(Copyable, Movable):
    """Status-rail data derived from runtime events."""

    var phase: Int32
    var step: Int32
    var total_steps: Int32
    var epoch: Int32
    var total_epochs: Int32
    var loss: Float32
    var learning_rate: Float32
    var speed_it_s: Float32
    var eta_secs: Int32
    var gpu_util: Float32
    var vram_gb: Float32
    var vram_total_gb: Float32
    var temp_c: Int32
    var cpu_util: Float32
    var ram_gb: Float32

    def __init__(out self):
        self.phase = 0
        self.step = 0
        self.total_steps = 0
        self.epoch = 0
        self.total_epochs = 0
        self.loss = 0.0
        self.learning_rate = 0.0
        self.speed_it_s = 0.0
        self.eta_secs = 0
        self.gpu_util = 0.0
        self.vram_gb = 0.0
        self.vram_total_gb = 24.0
        self.temp_c = 42
        self.cpu_util = 0.0
        self.ram_gb = 0.0


struct TrainerUiRuntime(Movable):
    """Live trainer runtime state and normalized job ledger."""

    var jobs: JobRuntime
    var backend_capability_id: String
    var backend_label: String
    var last_backend_command: TrainerBackendCommand
    var last_validation_summary: String
    var queued_requests: List[TrainerRequest]
    var running_request: TrainerRequest
    var has_running: Bool
    var paused: Bool
    var current_job_id: UInt64
    var frame_counter: Int32
    var live: TrainerLiveStats
    var samples: List[ArtifactRef]
    var checkpoints: List[ArtifactRef]
    var metrics: List[ArtifactRef]
    var logs: List[String]

    def __init__(out self):
        self.jobs = JobRuntime()
        self.backend_capability_id = String("mojoui.trainer.stub")
        self.backend_label = String("MojoUI CPU Trainer Stub")
        self.last_backend_command = TrainerBackendCommand()
        self.last_validation_summary = String("Ready")
        self.queued_requests = List[TrainerRequest]()
        self.running_request = TrainerRequest()
        self.has_running = False
        self.paused = False
        self.current_job_id = 0
        self.frame_counter = 0
        self.live = TrainerLiveStats()
        self.samples = List[ArtifactRef]()
        self.checkpoints = List[ArtifactRef]()
        self.metrics = List[ArtifactRef]()
        self.logs = List[String]()


def _artifact_path(req: TrainerRequest, prefix: String, step: Int32, ext: String) -> String:
    return req.output_dir.copy() + String("/") + prefix.copy() + String("-") + String(step) + ext.copy()


def _record_backend_command(mut rt: TrainerUiRuntime, kind: Int32, job_id: UInt64, req: TrainerRequest, reason: String):
    rt.last_backend_command = TrainerBackendCommand(kind, job_id, req, reason.copy())


def _set_idle(mut rt: TrainerUiRuntime):
    rt.has_running = False
    rt.paused = False
    rt.current_job_id = 0
    rt.frame_counter = 0
    rt.live.phase = 0
    rt.live.step = 0
    rt.live.total_steps = 0
    rt.live.gpu_util = 0.0
    rt.live.cpu_util = 0.0


def _start_request(mut rt: TrainerUiRuntime, var req: TrainerRequest):
    var total = trainer_total_steps(req)
    rt.current_job_id = req.id
    rt.running_request = req^
    rt.has_running = True
    rt.paused = False
    rt.frame_counter = 0
    _ = start_job(rt.jobs, rt.current_job_id, total)
    _ = add_log(rt.jobs, rt.current_job_id, JOB_LOG_INFO, String("Creating trainer run"))
    rt.logs.append(String("started ") + trainer_job_label(rt.running_request))
    rt.live.phase = JOB_PHASE_RUNNING
    rt.live.step = 0
    rt.live.total_steps = total
    rt.live.epoch = 0
    rt.live.total_epochs = rt.running_request.epochs
    rt.live.loss = 1.0
    rt.live.learning_rate = rt.running_request.learning_rate
    rt.live.speed_it_s = 0.0
    rt.live.eta_secs = 0
    rt.live.gpu_util = 62.0
    rt.live.vram_gb = 12.0
    rt.live.vram_total_gb = 24.0
    rt.live.temp_c = 46
    rt.live.cpu_util = 18.0
    rt.live.ram_gb = 8.0


def _start_next(mut rt: TrainerUiRuntime):
    if len(rt.queued_requests) == 0:
        _set_idle(rt)
        return
    var head = rt.queued_requests[0].copy()
    var rest = List[TrainerRequest]()
    for i in range(1, len(rt.queued_requests)):
        rest.append(rt.queued_requests[i].copy())
    rt.queued_requests = rest^
    _start_request(rt, head^)


def trainer_submit_current(state: TrainerState, mut rt: TrainerUiRuntime) -> UInt64:
    """Submit current form state into the normalized trainer runtime."""
    var id = rt.jobs.next_job_id
    var req = trainer_request_from_state(state, id)
    var cap = make_trainer_capability(req.backend_id.copy(), rt.backend_label.copy())
    var issues = validate_trainer_request(req, cap)
    rt.last_validation_summary = backend_validation_summary(issues)
    if backend_validation_error_count(issues) > 0:
        rt.logs.append(String("validation failed: ") + rt.last_validation_summary.copy())
        return UInt64(0)
    var label = trainer_job_label(req)
    var job_id = submit_job(rt.jobs, JOB_KIND_TRAINER, label, 0, 0)
    req.id = job_id
    _record_backend_command(rt, TRAINER_BACKEND_CMD_SUBMIT, job_id, req, String("submit"))
    if rt.has_running:
        rt.queued_requests.append(req^)
    else:
        _start_request(rt, req^)
    return job_id


def trainer_pause(mut rt: TrainerUiRuntime) -> Bool:
    if not rt.has_running or rt.paused:
        return False
    if not pause_job(rt.jobs, rt.current_job_id, String("paused")):
        return False
    rt.paused = True
    rt.live.phase = JOB_PHASE_PAUSED
    rt.live.gpu_util = 0.0
    rt.logs.append(String("paused #") + String(rt.current_job_id))
    var cmd_job_id = rt.current_job_id
    var cmd_req = rt.running_request.copy()
    _record_backend_command(rt, TRAINER_BACKEND_CMD_PAUSE, cmd_job_id, cmd_req, String("paused"))
    return True


def trainer_resume(mut rt: TrainerUiRuntime) -> Bool:
    if not rt.has_running or not rt.paused:
        return False
    if not resume_job(rt.jobs, rt.current_job_id, String("resumed")):
        return False
    rt.paused = False
    rt.live.phase = JOB_PHASE_RUNNING
    rt.live.gpu_util = 62.0
    rt.logs.append(String("resumed #") + String(rt.current_job_id))
    var cmd_job_id = rt.current_job_id
    var cmd_req = rt.running_request.copy()
    _record_backend_command(rt, TRAINER_BACKEND_CMD_RESUME, cmd_job_id, cmd_req, String("resumed"))
    return True


def trainer_cancel_all(mut rt: TrainerUiRuntime):
    """Cancel active and queued trainer jobs."""
    if rt.has_running:
        _ = cancel_job(rt.jobs, rt.current_job_id, String("stopped"))
        rt.logs.append(String("stopped #") + String(rt.current_job_id))
        var cmd_job_id = rt.current_job_id
        var cmd_req = rt.running_request.copy()
        _record_backend_command(rt, TRAINER_BACKEND_CMD_CANCEL, cmd_job_id, cmd_req, String("stopped"))
    for i in range(len(rt.queued_requests)):
        _ = cancel_job(rt.jobs, rt.queued_requests[i].id, String("dropped from queue"))
    rt.queued_requests = List[TrainerRequest]()
    _set_idle(rt)


def trainer_sample_now(mut rt: TrainerUiRuntime) -> Bool:
    if not rt.has_running:
        return False
    var step = rt.live.step
    var art = ArtifactRef(
        ARTIFACT_IMAGE,
        _artifact_path(rt.running_request, String("sample"), step, String(".png")),
        String("sample"),
        step,
    )
    rt.samples.append(art.copy())
    _ = add_artifact(rt.jobs, rt.current_job_id, art)
    rt.logs.append(String("sample ready #") + String(rt.current_job_id) + String(" step ") + String(step))
    var cmd_job_id = rt.current_job_id
    var cmd_req = rt.running_request.copy()
    _record_backend_command(rt, TRAINER_BACKEND_CMD_SAMPLE_NOW, cmd_job_id, cmd_req, String("sample"))
    return True


def trainer_save_checkpoint_now(mut rt: TrainerUiRuntime) -> Bool:
    if not rt.has_running:
        return False
    var step = rt.live.step
    var art = ArtifactRef(
        ARTIFACT_CHECKPOINT,
        _artifact_path(rt.running_request, String("ckpt"), step, String(".safetensors")),
        String("checkpoint"),
        step,
    )
    rt.checkpoints.append(art.copy())
    _ = add_artifact(rt.jobs, rt.current_job_id, art)
    rt.logs.append(String("checkpoint saved #") + String(rt.current_job_id) + String(" step ") + String(step))
    var cmd_job_id = rt.current_job_id
    var cmd_req = rt.running_request.copy()
    _record_backend_command(rt, TRAINER_BACKEND_CMD_SAVE_CHECKPOINT, cmd_job_id, cmd_req, String("checkpoint"))
    return True


def _update_live_metrics(mut rt: TrainerUiRuntime, step: Int32, total: Int32):
    var progress = Float32(Int(step)) / Float32(Int(total))
    if progress < 0.0:
        progress = 0.0
    if progress > 1.0:
        progress = 1.0
    rt.live.step = step
    rt.live.total_steps = total
    rt.live.loss = 1.0 / (1.0 + Float32(Int(step)) * 0.05)
    rt.live.learning_rate = rt.running_request.learning_rate * (1.0 - progress)
    rt.live.speed_it_s = 1.85
    rt.live.eta_secs = Int32(Int((Float32(Int(total - step)) / rt.live.speed_it_s) + 0.5))
    if rt.running_request.epochs > 0:
        rt.live.epoch = Int32(Int(progress * Float32(Int(rt.running_request.epochs)))) + 1
        if rt.live.epoch > rt.running_request.epochs:
            rt.live.epoch = rt.running_request.epochs
    rt.live.gpu_util = 58.0 + progress * 18.0
    rt.live.cpu_util = 18.0 + progress * 12.0
    rt.live.vram_gb = 12.0 + progress * 2.0
    rt.live.temp_c = Int32(46 + Int(progress * 8.0))


def _maybe_emit_step_artifacts(mut rt: TrainerUiRuntime, step: Int32):
    if rt.running_request.sample_every_steps > 0 and step % rt.running_request.sample_every_steps == 0:
        _ = trainer_sample_now(rt)
    if rt.running_request.save_every_steps > 0 and step % rt.running_request.save_every_steps == 0:
        _ = trainer_save_checkpoint_now(rt)
    if step % Int32(25) == 0:
        var art = ArtifactRef(
            ARTIFACT_METRICS,
            _artifact_path(rt.running_request, String("metrics"), step, String(".json")),
            String("metrics"),
            step,
        )
        rt.metrics.append(art.copy())
        _ = add_artifact(rt.jobs, rt.current_job_id, art)


def trainer_tick_and_apply(mut rt: TrainerUiRuntime):
    """Advance the CPU trainer stub one frame."""
    if not rt.has_running or rt.paused:
        return
    rt.frame_counter = rt.frame_counter + 1
    if rt.frame_counter < TRAINER_FRAMES_PER_STEP:
        return
    rt.frame_counter = 0

    var idx = find_job_index(rt.jobs, rt.current_job_id)
    if idx < 0:
        _set_idle(rt)
        return
    var total = rt.jobs.jobs[idx].total_steps
    var step = rt.jobs.jobs[idx].current_step + 1
    _update_live_metrics(rt, step, total)
    _ = update_progress(rt.jobs, rt.current_job_id, step, total, String("train step"))
    _maybe_emit_step_artifacts(rt, step)

    if step >= total:
        _ = complete_job(rt.jobs, rt.current_job_id, String("finished"))
        rt.logs.append(String("finished #") + String(rt.current_job_id))
        _start_next(rt)


def trainer_progress_fraction(rt: TrainerUiRuntime) -> Float32:
    if not rt.has_running:
        return 0.0
    return job_progress(rt.jobs, rt.current_job_id)
