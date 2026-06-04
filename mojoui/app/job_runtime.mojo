"""Backend-neutral job/event runtime for MojoUI apps.

This is the small app-layer contract that lets different frontends submit work
without knowing whether the backend is inference, trainer, captioning, video
editing, or a future node graph executor. It is pure Mojo and FFI-free.
"""


# Job kinds. Apps may use JOB_KIND_CUSTOM plus their own subtype in payload code.
comptime JOB_KIND_INFERENCE: Int32 = 1
comptime JOB_KIND_TRAINER: Int32 = 2
comptime JOB_KIND_CAPTION: Int32 = 3
comptime JOB_KIND_VIDEO_EDIT: Int32 = 4
comptime JOB_KIND_NODE_GRAPH: Int32 = 5
comptime JOB_KIND_CUSTOM: Int32 = 100

# Job phases.
comptime JOB_PHASE_QUEUED: Int32 = 0
comptime JOB_PHASE_RUNNING: Int32 = 1
comptime JOB_PHASE_DONE: Int32 = 2
comptime JOB_PHASE_FAILED: Int32 = 3
comptime JOB_PHASE_CANCELLED: Int32 = 4
comptime JOB_PHASE_PAUSED: Int32 = 5

# Event kinds.
comptime JOB_EVENT_STARTED: Int32 = 1
comptime JOB_EVENT_PROGRESS: Int32 = 2
comptime JOB_EVENT_ARTIFACT: Int32 = 3
comptime JOB_EVENT_LOG: Int32 = 4
comptime JOB_EVENT_DONE: Int32 = 5
comptime JOB_EVENT_FAILED: Int32 = 6
comptime JOB_EVENT_CANCELLED: Int32 = 7
comptime JOB_EVENT_PAUSED: Int32 = 8
comptime JOB_EVENT_RESUMED: Int32 = 9

# Artifact kinds.
comptime ARTIFACT_IMAGE: Int32 = 1
comptime ARTIFACT_VIDEO: Int32 = 2
comptime ARTIFACT_AUDIO: Int32 = 3
comptime ARTIFACT_CHECKPOINT: Int32 = 4
comptime ARTIFACT_TEXT: Int32 = 5
comptime ARTIFACT_METRICS: Int32 = 6
comptime ARTIFACT_CUSTOM: Int32 = 100

# Log levels.
comptime JOB_LOG_INFO: Int32 = 1
comptime JOB_LOG_WARN: Int32 = 2
comptime JOB_LOG_ERROR: Int32 = 3


struct ArtifactRef(Copyable, Movable):
    """Reference to an output produced by a job."""

    var kind: Int32
    var path: String
    var label: String
    var step: Int32

    def __init__(out self):
        self.kind = 0
        self.path = String("")
        self.label = String("")
        self.step = 0

    def __init__(out self, kind: Int32, path: String, label: String, step: Int32):
        self.kind = kind
        self.path = path.copy()
        self.label = label.copy()
        self.step = step


struct UiJob(Copyable, Movable):
    """One visible unit of work in the app queue/history."""

    var id: UInt64
    var kind: Int32
    var source_node_id: UInt64
    var graph_run_id: UInt64
    var label: String
    var phase: Int32
    var progress: Float32
    var current_step: Int32
    var total_steps: Int32
    var error: String

    def __init__(out self):
        self.id = 0
        self.kind = 0
        self.source_node_id = 0
        self.graph_run_id = 0
        self.label = String("")
        self.phase = JOB_PHASE_QUEUED
        self.progress = 0.0
        self.current_step = 0
        self.total_steps = 0
        self.error = String("")

    def __init__(
        out self,
        id: UInt64,
        kind: Int32,
        label: String,
        source_node_id: UInt64,
        graph_run_id: UInt64,
    ):
        self.id = id
        self.kind = kind
        self.source_node_id = source_node_id
        self.graph_run_id = graph_run_id
        self.label = label.copy()
        self.phase = JOB_PHASE_QUEUED
        self.progress = 0.0
        self.current_step = 0
        self.total_steps = 0
        self.error = String("")


struct UiJobEvent(Copyable, Movable):
    """Normalized event emitted by any backend job."""

    var kind: Int32
    var job_id: UInt64
    var job_kind: Int32
    var level: Int32
    var step: Int32
    var total_steps: Int32
    var progress: Float32
    var message: String
    var artifact: ArtifactRef

    def __init__(out self):
        self.kind = 0
        self.job_id = 0
        self.job_kind = 0
        self.level = 0
        self.step = 0
        self.total_steps = 0
        self.progress = 0.0
        self.message = String("")
        self.artifact = ArtifactRef()

    def __init__(
        out self,
        kind: Int32,
        job_id: UInt64,
        job_kind: Int32,
        level: Int32,
        step: Int32,
        total_steps: Int32,
        progress: Float32,
        message: String,
        artifact: ArtifactRef,
    ):
        self.kind = kind
        self.job_id = job_id
        self.job_kind = job_kind
        self.level = level
        self.step = step
        self.total_steps = total_steps
        self.progress = progress
        self.message = message.copy()
        self.artifact = artifact.copy()


struct JobRuntime(Movable):
    """Small in-memory job ledger and event stream."""

    var next_job_id: UInt64
    var jobs: List[UiJob]
    var events: List[UiJobEvent]

    def __init__(out self):
        self.next_job_id = 1
        self.jobs = List[UiJob]()
        self.events = List[UiJobEvent]()


def _clamp_progress(step: Int32, total_steps: Int32) -> Float32:
    if total_steps <= 0:
        return 0.0
    var f = Float32(Int(step)) / Float32(Int(total_steps))
    if f < 0.0:
        return 0.0
    if f > 1.0:
        return 1.0
    return f


def find_job_index(rt: JobRuntime, job_id: UInt64) -> Int:
    for i in range(len(rt.jobs)):
        if rt.jobs[i].id == job_id:
            return i
    return -1


def submit_job(
    mut rt: JobRuntime,
    kind: Int32,
    label: String,
    source_node_id: UInt64,
    graph_run_id: UInt64,
) -> UInt64:
    var id = rt.next_job_id
    rt.next_job_id = rt.next_job_id + 1
    var job = UiJob(id, kind, label.copy(), source_node_id, graph_run_id)
    rt.jobs.append(job^)
    return id


def _event(
    kind: Int32,
    job: UiJob,
    level: Int32,
    step: Int32,
    total_steps: Int32,
    progress: Float32,
    message: String,
    artifact: ArtifactRef,
) -> UiJobEvent:
    return UiJobEvent(
        kind,
        job.id,
        job.kind,
        level,
        step,
        total_steps,
        progress,
        message.copy(),
        artifact.copy(),
    )


def start_job(mut rt: JobRuntime, job_id: UInt64, total_steps: Int32) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    rt.jobs[idx].phase = JOB_PHASE_RUNNING
    rt.jobs[idx].current_step = 0
    rt.jobs[idx].total_steps = total_steps
    rt.jobs[idx].progress = 0.0
    rt.jobs[idx].error = String("")
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_STARTED,
            rt.jobs[idx],
            JOB_LOG_INFO,
            0,
            total_steps,
            0.0,
            String("started"),
            empty,
        )
    )
    return True


def update_progress(
    mut rt: JobRuntime,
    job_id: UInt64,
    step: Int32,
    total_steps: Int32,
    message: String,
) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    var progress = _clamp_progress(step, total_steps)
    rt.jobs[idx].phase = JOB_PHASE_RUNNING
    rt.jobs[idx].current_step = step
    rt.jobs[idx].total_steps = total_steps
    rt.jobs[idx].progress = progress
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_PROGRESS,
            rt.jobs[idx],
            JOB_LOG_INFO,
            step,
            total_steps,
            progress,
            message.copy(),
            empty,
        )
    )
    return True


def add_artifact(mut rt: JobRuntime, job_id: UInt64, artifact: ArtifactRef) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    rt.events.append(
        _event(
            JOB_EVENT_ARTIFACT,
            rt.jobs[idx],
            JOB_LOG_INFO,
            artifact.step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            artifact.label.copy(),
            artifact.copy(),
        )
    )
    return True


def add_log(mut rt: JobRuntime, job_id: UInt64, level: Int32, message: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_LOG,
            rt.jobs[idx],
            level,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            message.copy(),
            empty,
        )
    )
    return True


def complete_job(mut rt: JobRuntime, job_id: UInt64, message: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    rt.jobs[idx].phase = JOB_PHASE_DONE
    if rt.jobs[idx].total_steps > 0:
        rt.jobs[idx].current_step = rt.jobs[idx].total_steps
    rt.jobs[idx].progress = 1.0
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_DONE,
            rt.jobs[idx],
            JOB_LOG_INFO,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            1.0,
            message.copy(),
            empty,
        )
    )
    return True


def fail_job(mut rt: JobRuntime, job_id: UInt64, error: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    rt.jobs[idx].phase = JOB_PHASE_FAILED
    rt.jobs[idx].error = error.copy()
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_FAILED,
            rt.jobs[idx],
            JOB_LOG_ERROR,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            error.copy(),
            empty,
        )
    )
    return True


def cancel_job(mut rt: JobRuntime, job_id: UInt64, message: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    rt.jobs[idx].phase = JOB_PHASE_CANCELLED
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_CANCELLED,
            rt.jobs[idx],
            JOB_LOG_WARN,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            message.copy(),
            empty,
        )
    )
    return True


def pause_job(mut rt: JobRuntime, job_id: UInt64, message: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    if rt.jobs[idx].phase != JOB_PHASE_RUNNING:
        return False
    rt.jobs[idx].phase = JOB_PHASE_PAUSED
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_PAUSED,
            rt.jobs[idx],
            JOB_LOG_WARN,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            message.copy(),
            empty,
        )
    )
    return True


def resume_job(mut rt: JobRuntime, job_id: UInt64, message: String) -> Bool:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return False
    if rt.jobs[idx].phase != JOB_PHASE_PAUSED:
        return False
    rt.jobs[idx].phase = JOB_PHASE_RUNNING
    var empty = ArtifactRef()
    rt.events.append(
        _event(
            JOB_EVENT_RESUMED,
            rt.jobs[idx],
            JOB_LOG_INFO,
            rt.jobs[idx].current_step,
            rt.jobs[idx].total_steps,
            rt.jobs[idx].progress,
            message.copy(),
            empty,
        )
    )
    return True


def job_progress(rt: JobRuntime, job_id: UInt64) -> Float32:
    var idx = find_job_index(rt, job_id)
    if idx < 0:
        return 0.0
    return rt.jobs[idx].progress
