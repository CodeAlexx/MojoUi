"""MojoUI M4 — pure inference-app state + mock-worker model.

FFI-FREE, `mojo run`-testable. Mirrors the egui `inference_ui` AppState
(Image-mode subset) and replaces the crossbeam `WorkerEvent` channel with a
frame-driven mock stepper. The interactive demo (`examples/m8_inference_ui.mojo`)
threads an `InferenceState` through the live MojoUI frame loop; this module
holds everything that can be unit-tested without a window.

Worker protocol mapped to the mock stepper (mirrors Started→Progress×N→Done):
  - `action_generate(state)`: snapshot params → a `QueueJob`; if idle, promote
    it to the running slot and set `generating=True`, `current_step=0`,
    `total_steps=steps`; otherwise it waits in `queued`.
  - `tick_worker(state)`: called once per frame. While generating, every
    `FRAMES_PER_STEP` frames bump `current_step`. When `current_step >=
    total_steps` → mark Done: push a `HistoryItem`, clear `generating`, set
    `result_ready`, then promote the next queued job if any.
  - `action_cancel(state)`: cooperative cancel — drops the running job,
    clears `generating` (no history item).

The single seam where real serenitymojo inference attaches later is
`tick_worker` (swap the frame counter for a real progress callback) and the
synthetic-result production inside `_complete_running`.

Deferred (per PLAN_M4 v1 scope): Video mode, RON persistence, real inference,
NVML perf (mock constants here), controlnet panel, LoRA drag-reorder.
"""


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

comptime FRAMES_PER_STEP: Int = 6
"""Mock stepper advances one inference `step` every this many frames."""


# ---------------------------------------------------------------------------
# QueueJob — a snapshot of the params at Generate time. Mirrors state.rs
# `QueueJob` (id/prompt/width/height/steps/sampler/progress).
# ---------------------------------------------------------------------------


struct QueueJob(Copyable, Movable):
    var id: UInt64
    var prompt: String
    var width: Int32
    var height: Int32
    var steps: Int32
    var sampler: String
    var seed: Int64
    var current_step: Int32  # running job only; 0 for queued
    var color_seed: UInt32   # drives the synthetic gradient

    def __init__(out self):
        self.id = 0
        self.prompt = String("")
        self.width = 1024
        self.height = 1024
        self.steps = 28
        self.sampler = String("euler")
        self.seed = -1
        self.current_step = 0
        self.color_seed = 0

    def __init__(
        out self,
        id: UInt64,
        prompt: String,
        width: Int32,
        height: Int32,
        steps: Int32,
        sampler: String,
        seed: Int64,
        color_seed: UInt32,
    ):
        self.id = id
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.sampler = sampler
        self.seed = seed
        self.current_step = 0
        self.color_seed = color_seed

    def progress(self) -> Float32:
        """0.0..1.0 fraction for this job's progress bar."""
        if self.steps <= 0:
            return 0.0
        var f = Float32(Int(self.current_step)) / Float32(Int(self.steps))
        if f > 1.0:
            return 1.0
        return f


# ---------------------------------------------------------------------------
# HistoryItem — one completed output. `color_seed` keys the procedural
# thumbnail (no disk thumbnail in v1).
# ---------------------------------------------------------------------------


struct HistoryItem(Copyable, Movable):
    var id: UInt64
    var prompt: String
    var seed: Int64
    var color_seed: UInt32

    def __init__(out self):
        self.id = 0
        self.prompt = String("")
        self.seed = -1
        self.color_seed = 0

    def __init__(out self, id: UInt64, prompt: String, seed: Int64, color_seed: UInt32):
        self.id = id
        self.prompt = prompt
        self.seed = seed
        self.color_seed = color_seed


# ---------------------------------------------------------------------------
# PerfTelemetry — mock GPU stats (NVML deferred). Constants mirror state.rs
# `PerfTelemetry::mock()`.
# ---------------------------------------------------------------------------


struct PerfTelemetry(Copyable, Movable):
    var gpu_name: String
    var vram_used_gb: Float32
    var vram_total_gb: Float32
    var gpu_util_pct: Float32
    var temperature_c: Float32

    def __init__(out self):
        self.gpu_name = String("RTX 4090 (mock)")
        self.vram_used_gb = 19.1
        self.vram_total_gb = 24.0
        self.gpu_util_pct = 0.0
        self.temperature_c = 45.0


# ---------------------------------------------------------------------------
# LoraSlot — one LoRA row {name, strength, active}.
# ---------------------------------------------------------------------------


struct LoraSlot(Copyable, Movable):
    var name: String
    var strength: Float32
    var active: Bool

    def __init__(out self, name: String, strength: Float32, active: Bool):
        self.name = name
        self.strength = strength
        self.active = active


# ---------------------------------------------------------------------------
# InferenceState — the whole Image-mode app state. Pure data + a few helpers.
# Movable so it can live behind the user_data pointer in the live demo.
# ---------------------------------------------------------------------------


struct InferenceState(Movable):
    # ----- Top-level -----
    var advanced: Bool

    # ----- Model / mode -----
    var task_options: List[String]
    var task_index: Int32
    var task_open: Bool

    var model_options: List[String]
    var model_index: Int32
    var model_open: Bool

    var vae_options: List[String]
    var vae_index: Int32
    var vae_open: Bool

    var precision_options: List[String]
    var precision_index: Int32
    var precision_open: Bool

    # ----- Resolution -----
    var resolution_options: List[String]
    var resolution_index: Int32
    var resolution_open: Bool
    var width: Float32   # 256..2048
    var height: Float32

    # ----- Sampling -----
    var sampler_options: List[String]
    var sampler_index: Int32
    var sampler_open: Bool
    var scheduler_options: List[String]
    var scheduler_index: Int32
    var scheduler_open: Bool
    var steps: Float32   # 1..100
    var cfg: Float32     # drag_value 0.1 step

    # ----- Seed -----
    var seed: Float32         # -1 = random (stored Float32; cast Int64 in job)
    var seed_mode_options: List[String]
    var seed_mode_index: Int32
    var seed_mode_open: Bool
    var seed_locked: Bool

    # ----- LoRA -----
    var loras: List[LoraSlot]

    # ----- Advanced sampling -----
    var clip_skip: Float32
    var eta: Float32
    var sigma_min: Float32
    var sigma_max: Float32
    var restart_sampling: Bool

    # ----- Perf opts -----
    var attention_options: List[String]
    var attention_index: Int32
    var attention_open: Bool
    var cpu_offload_options: List[String]
    var cpu_offload_index: Int32
    var cpu_offload_open: Bool
    var vram_budget_gb: Float32

    # ----- Output -----
    var output_folder: String
    var filename_template: String
    var save_metadata: Bool

    # ----- Canvas prompts -----
    var prompt: String
    var negative: String
    var batch_count: Float32
    var batch_size: Float32

    # ----- Runtime (mock worker) -----
    var generating: Bool
    var current_step: Int32
    var total_steps: Int32
    var frame_counter: Int32
    var result_ready: Bool

    # ----- Queue / history -----
    var queued: List[QueueJob]
    var running: QueueJob          # valid only when has_running
    var has_running: Bool
    var history: List[HistoryItem]
    var next_job_id: UInt64
    var queue_tab: Int32           # 0 = Queue, 1 = History

    # ----- Perf -----
    var perf: PerfTelemetry

    def __init__(out self):
        self.advanced = False

        var tasks = List[String]()
        tasks.append(String("T2I - Text to Image"))
        tasks.append(String("I2I - Image to Image"))
        tasks.append(String("IC-LoRA - In-Context LoRA"))
        self.task_options = tasks^
        self.task_index = 0
        self.task_open = False

        var models = List[String]()
        models.append(String("Z-Image (base)"))
        models.append(String("Z-Image (turbo)"))
        models.append(String("FLUX Dev"))
        models.append(String("Chroma"))
        models.append(String("Klein 4B"))
        models.append(String("Klein 9B"))
        models.append(String("SD 3.5"))
        models.append(String("Qwen-Image"))
        models.append(String("ERNIE"))
        models.append(String("Anima"))
        models.append(String("SDXL"))
        models.append(String("SD 1.5"))
        self.model_options = models^
        self.model_index = 2  # FLUX Dev (mirrors image_default)
        self.model_open = False

        var vaes = List[String]()
        vaes.append(String("ae.safetensors (auto)"))
        vaes.append(String("sdxl_vae.safetensors"))
        vaes.append(String("taesd"))
        self.vae_options = vaes^
        self.vae_index = 0
        self.vae_open = False

        var precs = List[String]()
        precs.append(String("fp16"))
        precs.append(String("bf16"))
        precs.append(String("fp8_e4m3"))
        precs.append(String("fp8_e5m2"))
        precs.append(String("q8_0"))
        precs.append(String("q4_k_m"))
        self.precision_options = precs^
        self.precision_index = 1  # bf16
        self.precision_open = False

        var res = List[String]()
        res.append(String("1024x1024  ·  1:1"))
        res.append(String("1280x720  ·  16:9"))
        res.append(String("832x1216  ·  2:3"))
        res.append(String("1216x832  ·  3:2"))
        res.append(String("512x512  ·  1:1"))
        self.resolution_options = res^
        self.resolution_index = 0
        self.resolution_open = False
        self.width = 1024.0
        self.height = 1024.0

        var samplers = List[String]()
        samplers.append(String("euler"))
        samplers.append(String("dpm++"))
        samplers.append(String("ddim"))
        samplers.append(String("unipc"))
        self.sampler_options = samplers^
        self.sampler_index = 0
        self.sampler_open = False

        var scheds = List[String]()
        scheds.append(String("karras"))
        scheds.append(String("normal"))
        scheds.append(String("exponential"))
        scheds.append(String("simple"))
        self.scheduler_options = scheds^
        self.scheduler_index = 0
        self.scheduler_open = False

        self.steps = 28.0
        self.cfg = 4.5

        self.seed = -1.0
        var seed_modes = List[String]()
        seed_modes.append(String("random"))
        seed_modes.append(String("fixed"))
        seed_modes.append(String("increment"))
        self.seed_mode_options = seed_modes^
        self.seed_mode_index = 0
        self.seed_mode_open = False
        self.seed_locked = False

        var loras = List[LoraSlot]()
        loras.append(LoraSlot(String("detail-tweaker-xl"), 0.8, True))
        loras.append(LoraSlot(String("film-photography-v2"), 1.1, True))
        loras.append(LoraSlot(String("anime-style-pony"), 0.6, False))
        self.loras = loras^

        self.clip_skip = 2.0
        self.eta = 0.0
        self.sigma_min = 0.03
        self.sigma_max = 14.6
        self.restart_sampling = False

        var attns = List[String]()
        attns.append(String("flash-attn-2"))
        attns.append(String("sdpa"))
        attns.append(String("xformers"))
        attns.append(String("math"))
        self.attention_options = attns^
        self.attention_index = 0
        self.attention_open = False

        var offloads = List[String]()
        offloads.append(String("none"))
        offloads.append(String("cpu"))
        offloads.append(String("sequential"))
        offloads.append(String("model"))
        self.cpu_offload_options = offloads^
        self.cpu_offload_index = 0
        self.cpu_offload_open = False
        self.vram_budget_gb = 24.0

        self.output_folder = String("/home/out/2026-05-28")
        self.filename_template = String("{seed}-{model}-{steps}")
        self.save_metadata = True

        self.prompt = String(
            "cinematic portrait, 85mm, warm afternoon light, film grain"
        )
        self.negative = String("ugly, blurry, low quality, watermark")
        self.batch_count = 1.0
        self.batch_size = 1.0

        self.generating = False
        self.current_step = 0
        self.total_steps = 0
        self.frame_counter = 0
        self.result_ready = False

        self.queued = List[QueueJob]()
        self.running = QueueJob()
        self.has_running = False
        self.history = List[HistoryItem]()
        self.next_job_id = 1
        self.queue_tab = 0

        self.perf = PerfTelemetry()

    # -----------------------------------------------------------------------
    # Small read helpers used by the live demo for labels.
    # -----------------------------------------------------------------------

    def model_label(self) -> String:
        return self.model_options[Int(self.model_index)]

    def sampler_label(self) -> String:
        return self.sampler_options[Int(self.sampler_index)]

    def task_short(self) -> String:
        if self.task_index == 0:
            return String("T2I")
        elif self.task_index == 1:
            return String("I2I")
        return String("IC-LoRA")


# ---------------------------------------------------------------------------
# Synthetic color seed — folds the prompt bytes + seed into a UInt32 so each
# generation paints a distinct (but deterministic) gradient. Pure Mojo.
# ---------------------------------------------------------------------------


def _color_seed_for(prompt: String, seed: Int64, job_id: UInt64) -> UInt32:
    var h: UInt32 = 2166136261  # FNV-1a offset basis
    var p = prompt.unsafe_ptr()
    var n = prompt.byte_length()
    for i in range(n):
        h = (h ^ UInt32(p[i])) * UInt32(16777619)
    h = h ^ UInt32(seed & Int64(0xFFFFFFFF))
    h = h ^ UInt32(job_id & UInt64(0xFFFFFFFF))
    return h


# ---------------------------------------------------------------------------
# Worker protocol — the three seams.
# ---------------------------------------------------------------------------


def action_generate(mut state: InferenceState):
    """Snapshot current params into a `QueueJob` and submit it. If nothing is
    running it is promoted immediately (generating starts this frame);
    otherwise it waits in `queued`. Mirrors the egui Generate button which
    pushes a `GenerateJob` onto the worker channel."""
    var seed_i64 = Int64(Int(state.seed))
    # Clamp steps to >= 1. `state.steps` is a public Float32; a value in
    # [0,1) truncates to 0, which would arm a degenerate job that completes
    # in zero steps with a 0% progress bar (skeptic HIGH-1). The UI slider
    # clamps to 1..100, but a non-UI caller could set steps directly.
    var steps_i = Int32(Int(state.steps))
    if steps_i < Int32(1):
        steps_i = Int32(1)
    var job = QueueJob(
        state.next_job_id,
        state.prompt.copy(),
        Int32(Int(state.width)),
        Int32(Int(state.height)),
        steps_i,
        state.sampler_label(),
        seed_i64,
        _color_seed_for(state.prompt, seed_i64, state.next_job_id),
    )
    state.next_job_id = state.next_job_id + 1

    if state.has_running:
        state.queued.append(job^)
    else:
        _promote_job(state, job^)


def _promote_job(mut state: InferenceState, var job: QueueJob):
    """Move `job` into the running slot and arm the mock stepper."""
    state.running = job^
    state.running.current_step = 0
    state.has_running = True
    state.generating = True
    state.current_step = 0
    state.total_steps = state.running.steps
    state.frame_counter = 0
    state.result_ready = False
    state.perf.gpu_util_pct = 62.0


def action_cancel(mut state: InferenceState):
    """Cooperative cancel — drop the running job (no history item) and try to
    start the next queued job if any. Mirrors the egui Stop button."""
    if not state.has_running:
        return
    state.has_running = False
    state.generating = False
    state.current_step = 0
    state.total_steps = 0
    state.frame_counter = 0
    state.perf.gpu_util_pct = 0.0
    _start_next(state)


def _start_next(mut state: InferenceState):
    """If a job is queued, promote the head of the queue."""
    if len(state.queued) > 0:
        var head = state.queued[0].copy()
        # shift the queue left by one
        var rest = List[QueueJob]()
        for i in range(1, len(state.queued)):
            rest.append(state.queued[i].copy())
        state.queued = rest^
        _promote_job(state, head^)


def _complete_running(mut state: InferenceState):
    """Mark the running job Done: produce a history item (procedural result),
    clear generating, set result_ready, then start the next queued job. This
    is the seam where a real decoded image would be attached."""
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
    _start_next(state)


def tick_worker(mut state: InferenceState):
    """Advance the mock worker one frame. No-op when idle. Every
    FRAMES_PER_STEP frames bumps `current_step`; on reaching `total_steps`
    completes the job. Keep the running-job mirror (`running.current_step`)
    in sync so the queue panel's per-job progress bar tracks it."""
    if not state.generating:
        return
    state.frame_counter = state.frame_counter + 1
    if state.frame_counter < Int32(FRAMES_PER_STEP):
        return
    state.frame_counter = 0
    if state.current_step < state.total_steps:
        state.current_step = state.current_step + 1
        if state.has_running:
            state.running.current_step = state.current_step
    if state.current_step >= state.total_steps:
        _complete_running(state)


def progress_fraction(state: InferenceState) -> Float32:
    """Overall progress 0.0..1.0 of the running job (0 when idle)."""
    if state.total_steps <= 0:
        return 0.0
    var f = Float32(Int(state.current_step)) / Float32(Int(state.total_steps))
    if f > 1.0:
        return 1.0
    return f
