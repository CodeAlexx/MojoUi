"""Model-agnostic backend contracts for MojoUI apps.

These structs describe what the UI wants to run, not how a model backend runs
it. Real trainer/inference implementations should adapt from these request
types into their own command/process/in-proc APIs.
"""

from mojoui.app.job_runtime import (
    JOB_KIND_INFERENCE,
    JOB_KIND_TRAINER,
    JOB_KIND_CAPTION,
    JOB_KIND_VIDEO_EDIT,
    JOB_KIND_NODE_GRAPH,
)


# High-level task ids. The UI may display model names, but execution should
# branch on these neutral tasks plus backend capabilities.
comptime TASK_TEXT_TO_IMAGE: Int32 = 1
comptime TASK_IMAGE_TO_IMAGE: Int32 = 2
comptime TASK_TRAIN_LORA: Int32 = 10
comptime TASK_TRAIN_FULL: Int32 = 11
comptime TASK_TRAIN_TEXTUAL_INVERSION: Int32 = 12
comptime TASK_CAPTION_IMAGES: Int32 = 20
comptime TASK_VIDEO_EDIT: Int32 = 30
comptime TASK_NODE_GRAPH: Int32 = 40

# Flexible request parameter value kinds.
comptime PARAM_STRING: Int32 = 1
comptime PARAM_INT: Int32 = 2
comptime PARAM_FLOAT: Int32 = 3
comptime PARAM_BOOL: Int32 = 4
comptime PARAM_PATH: Int32 = 5

comptime BACKEND_VALIDATION_INFO: Int32 = 0
comptime BACKEND_VALIDATION_WARN: Int32 = 1
comptime BACKEND_VALIDATION_ERROR: Int32 = 2

comptime TRAINER_BACKEND_CMD_SUBMIT: Int32 = 1
comptime TRAINER_BACKEND_CMD_PAUSE: Int32 = 2
comptime TRAINER_BACKEND_CMD_RESUME: Int32 = 3
comptime TRAINER_BACKEND_CMD_CANCEL: Int32 = 4
comptime TRAINER_BACKEND_CMD_SAMPLE_NOW: Int32 = 5
comptime TRAINER_BACKEND_CMD_SAVE_CHECKPOINT: Int32 = 6


struct BackendValidationIssue(Copyable, Movable):
    """Backend-neutral validation finding for a request/capability pair."""

    var severity: Int32
    var field: String
    var message: String

    def __init__(out self):
        self.severity = BACKEND_VALIDATION_INFO
        self.field = String("")
        self.message = String("")

    def __init__(out self, severity: Int32, field: String, message: String):
        self.severity = severity
        self.field = field.copy()
        self.message = message.copy()

struct RequestParam(Copyable, Movable):
    """Backend-specific extension point without hardcoding the UI model."""

    var key: String
    var value: String
    var kind: Int32

    def __init__(out self):
        self.key = String("")
        self.value = String("")
        self.kind = PARAM_STRING

    def __init__(out self, key: String, value: String, kind: Int32):
        self.key = key.copy()
        self.value = value.copy()
        self.kind = kind


struct BackendCapability(Copyable, Movable):
    """Declarative feature map for a trainer/inference/caption/video backend."""

    var id: String
    var label: String
    var supports_inference: Bool
    var supports_training: Bool
    var supports_captioning: Bool
    var supports_video_editing: Bool
    var supports_node_graphs: Bool
    var supports_lora: Bool
    var supports_full_finetune: Bool
    var supports_textual_inversion: Bool
    var supports_pause_resume: Bool
    var supports_checkpoint_artifacts: Bool
    var supports_sample_artifacts: Bool
    var supports_metrics: Bool
    var max_width: Int32
    var max_height: Int32

    def __init__(out self):
        self.id = String("")
        self.label = String("")
        self.supports_inference = False
        self.supports_training = False
        self.supports_captioning = False
        self.supports_video_editing = False
        self.supports_node_graphs = False
        self.supports_lora = False
        self.supports_full_finetune = False
        self.supports_textual_inversion = False
        self.supports_pause_resume = False
        self.supports_checkpoint_artifacts = False
        self.supports_sample_artifacts = False
        self.supports_metrics = False
        self.max_width = 0
        self.max_height = 0

    def __init__(out self, id: String, label: String):
        self.id = id.copy()
        self.label = label.copy()
        self.supports_inference = False
        self.supports_training = False
        self.supports_captioning = False
        self.supports_video_editing = False
        self.supports_node_graphs = False
        self.supports_lora = False
        self.supports_full_finetune = False
        self.supports_textual_inversion = False
        self.supports_pause_resume = False
        self.supports_checkpoint_artifacts = False
        self.supports_sample_artifacts = False
        self.supports_metrics = False
        self.max_width = 0
        self.max_height = 0

    def supports_job_kind(self, kind: Int32) -> Bool:
        if kind == JOB_KIND_INFERENCE:
            return self.supports_inference
        if kind == JOB_KIND_TRAINER:
            return self.supports_training
        if kind == JOB_KIND_CAPTION:
            return self.supports_captioning
        if kind == JOB_KIND_VIDEO_EDIT:
            return self.supports_video_editing
        if kind == JOB_KIND_NODE_GRAPH:
            return self.supports_node_graphs
        return False


struct TrainerRequest(Copyable, Movable):
    """Complete trainer run snapshot consumed by a trainer backend adapter."""

    var id: UInt64
    var task_id: Int32
    var backend_id: String
    var run_name: String
    var project_dir: String

    var model_type: String
    var architecture: String
    var base_model: String
    var vae_override: String
    var precision: String
    var train_text_encoder: Bool

    var network_rank: Int32
    var network_alpha: Int32
    var conv_rank: Int32
    var dropout: Float32
    var target_modules: List[String]

    var dataset_path: String
    var output_dir: String
    var dataset_image_count: Int32
    var concept_count: Int32
    var target_resolution: Int32
    var bucket_by_aspect: Bool
    var min_bucket_resolution: Int32
    var max_bucket_resolution: Int32
    var bucket_step: Int32
    var cache_latents: Bool
    var shuffle_captions: Bool
    var caption_dropout: Float32

    var epochs: Int32
    var batch_size: Int32
    var grad_accum: Int32
    var max_train_steps: Int32
    var warmup_steps: Int32

    var optimizer: String
    var learning_rate: Float32
    var text_encoder_lr: Float32
    var lr_scheduler: String
    var weight_decay: Float32
    var min_snr_gamma: Float32

    var mixed_precision: String
    var gradient_checkpointing: Bool
    var attention: String
    var cpu_offload: Bool
    var seed: Int64
    var deterministic: Bool

    var noise_offset: Float32
    var multi_res_noise: Bool
    var timestep_start: Int32
    var timestep_end: Int32
    var flip_augmentation: Bool
    var color_jitter: Bool

    var sample_every_steps: Int32
    var sample_sampler: String
    var sample_steps: Int32
    var sample_cfg: Float32
    var sample_resolution: String
    var sample_seed_mode: String

    var save_every_steps: Int32
    var keep_last_n: Int32
    var save_optimizer_state: Bool
    var checkpoint_format: String
    var filename_pattern: String

    var metadata: List[RequestParam]

    def __init__(out self):
        self.id = 0
        self.task_id = TASK_TRAIN_LORA
        self.backend_id = String("")
        self.run_name = String("")
        self.project_dir = String("")
        self.model_type = String("")
        self.architecture = String("")
        self.base_model = String("")
        self.vae_override = String("")
        self.precision = String("")
        self.train_text_encoder = False
        self.network_rank = 0
        self.network_alpha = 0
        self.conv_rank = 0
        self.dropout = 0.0
        self.target_modules = List[String]()
        self.dataset_path = String("")
        self.output_dir = String("")
        self.dataset_image_count = 0
        self.concept_count = 0
        self.target_resolution = 0
        self.bucket_by_aspect = False
        self.min_bucket_resolution = 0
        self.max_bucket_resolution = 0
        self.bucket_step = 0
        self.cache_latents = False
        self.shuffle_captions = False
        self.caption_dropout = 0.0
        self.epochs = 0
        self.batch_size = 0
        self.grad_accum = 0
        self.max_train_steps = 0
        self.warmup_steps = 0
        self.optimizer = String("")
        self.learning_rate = 0.0
        self.text_encoder_lr = 0.0
        self.lr_scheduler = String("")
        self.weight_decay = 0.0
        self.min_snr_gamma = 0.0
        self.mixed_precision = String("")
        self.gradient_checkpointing = False
        self.attention = String("")
        self.cpu_offload = False
        self.seed = 0
        self.deterministic = False
        self.noise_offset = 0.0
        self.multi_res_noise = False
        self.timestep_start = 0
        self.timestep_end = 0
        self.flip_augmentation = False
        self.color_jitter = False
        self.sample_every_steps = 0
        self.sample_sampler = String("")
        self.sample_steps = 0
        self.sample_cfg = 0.0
        self.sample_resolution = String("")
        self.sample_seed_mode = String("")
        self.save_every_steps = 0
        self.keep_last_n = 0
        self.save_optimizer_state = False
        self.checkpoint_format = String("")
        self.filename_pattern = String("")
        self.metadata = List[RequestParam]()


struct TrainerBackendCommand(Copyable, Movable):
    """Command sent from UI runtime to a trainer backend adapter."""

    var kind: Int32
    var job_id: UInt64
    var request: TrainerRequest
    var reason: String

    def __init__(out self):
        self.kind = TRAINER_BACKEND_CMD_SUBMIT
        self.job_id = 0
        self.request = TrainerRequest()
        self.reason = String("")

    def __init__(out self, kind: Int32, job_id: UInt64, request: TrainerRequest, reason: String):
        self.kind = kind
        self.job_id = job_id
        self.request = request.copy()
        self.reason = reason.copy()


def make_trainer_capability(id: String, label: String) -> BackendCapability:
    var cap = BackendCapability(id.copy(), label.copy())
    cap.supports_training = True
    cap.supports_lora = True
    cap.supports_full_finetune = True
    cap.supports_textual_inversion = True
    cap.supports_pause_resume = True
    cap.supports_checkpoint_artifacts = True
    cap.supports_sample_artifacts = True
    cap.supports_metrics = True
    return cap^


def make_inference_capability(id: String, label: String, max_width: Int32, max_height: Int32) -> BackendCapability:
    var cap = BackendCapability(id.copy(), label.copy())
    cap.supports_inference = True
    cap.supports_sample_artifacts = True
    cap.supports_metrics = True
    cap.max_width = max_width
    cap.max_height = max_height
    return cap^


def request_param(key: String, value: String, kind: Int32) -> RequestParam:
    return RequestParam(key.copy(), value.copy(), kind)


def trainer_task_id_from_model_type(model_type: String) -> Int32:
    if model_type == String("Full fine-tune"):
        return TASK_TRAIN_FULL
    if model_type == String("Textual Inversion"):
        return TASK_TRAIN_TEXTUAL_INVERSION
    return TASK_TRAIN_LORA


def _push_backend_issue(mut issues: List[BackendValidationIssue], severity: Int32, field: String, message: String):
    issues.append(BackendValidationIssue(severity, field.copy(), message.copy()))


def _empty_string(value: String) -> Bool:
    return value.byte_length() == 0


def _positive_or(value: Int32, fallback: Int32) -> Int32:
    if value > 0:
        return value
    if fallback > 0:
        return fallback
    return 1


def trainer_total_steps(req: TrainerRequest) -> Int32:
    """Compute UI-side total steps without knowing backend internals.

    `max_train_steps` wins. Otherwise derive a conservative estimate from
    dataset images, epochs, batch size, and gradient accumulation.
    """
    if req.max_train_steps > 0:
        return req.max_train_steps
    var images = _positive_or(req.dataset_image_count, 1)
    var epochs = _positive_or(req.epochs, 1)
    var batch = _positive_or(req.batch_size, 1)
    var accum = _positive_or(req.grad_accum, 1)
    var effective_batch = batch * accum
    var per_epoch = (images + effective_batch - 1) // effective_batch
    var total = per_epoch * epochs
    if total < 1:
        return 1
    return total


def trainer_job_label(req: TrainerRequest) -> String:
    if req.run_name.byte_length() == 0:
        return req.model_type.copy()
    return req.run_name.copy() + String(" · ") + req.model_type.copy()


def validate_trainer_request(req: TrainerRequest, cap: BackendCapability) -> List[BackendValidationIssue]:
    """Validate a trainer request against backend-neutral capability data.

    This is intentionally independent of any real trainer implementation. A
    future mojodiffusion adapter can add stricter checks before launch without
    changing the UI contract.
    """
    var issues = List[BackendValidationIssue]()
    if not cap.supports_training:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("backend"), String("backend does not support training"))
    if req.task_id == TASK_TRAIN_LORA and not cap.supports_lora:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("model_type"), String("backend does not support LoRA-style training"))
    if req.task_id == TASK_TRAIN_FULL and not cap.supports_full_finetune:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("model_type"), String("backend does not support full fine-tuning"))
    if req.task_id == TASK_TRAIN_TEXTUAL_INVERSION and not cap.supports_textual_inversion:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("model_type"), String("backend does not support textual inversion"))

    if _empty_string(req.run_name):
        _push_backend_issue(issues, BACKEND_VALIDATION_WARN, String("run_name"), String("run name is empty"))
    if _empty_string(req.base_model):
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("base_model"), String("base model is required"))
    if _empty_string(req.dataset_path):
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("dataset_path"), String("dataset path is required"))
    if _empty_string(req.output_dir):
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("output_dir"), String("output directory is required"))
    if req.dataset_image_count <= 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("dataset"), String("dataset has no enabled training images"))

    if req.network_rank < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("network_rank"), String("network rank must be at least 1"))
    if req.network_alpha < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("network_alpha"), String("network alpha must be at least 1"))
    if req.dropout < 0.0 or req.dropout > 1.0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("dropout"), String("dropout must be between 0 and 1"))

    if req.epochs < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("epochs"), String("epochs must be at least 1"))
    if req.batch_size < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("batch_size"), String("batch size must be at least 1"))
    if req.grad_accum < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("grad_accum"), String("gradient accumulation must be at least 1"))
    if req.max_train_steps < 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("max_train_steps"), String("max train steps cannot be negative"))
    if req.learning_rate <= 0.0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("learning_rate"), String("learning rate must be positive"))
    if req.text_encoder_lr < 0.0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("text_encoder_lr"), String("text encoder LR cannot be negative"))

    if req.min_bucket_resolution <= 0 or req.max_bucket_resolution <= 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("bucket_resolution"), String("bucket resolutions must be positive"))
    if req.max_bucket_resolution < req.min_bucket_resolution:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("bucket_resolution"), String("max bucket resolution must be >= min bucket resolution"))
    if req.bucket_step <= 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("bucket_step"), String("bucket step must be positive"))
    if req.target_resolution < req.min_bucket_resolution or req.target_resolution > req.max_bucket_resolution:
        _push_backend_issue(issues, BACKEND_VALIDATION_WARN, String("target_resolution"), String("target resolution is outside bucket bounds"))

    if req.timestep_start < 0 or req.timestep_end < 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("timesteps"), String("timesteps cannot be negative"))
    if req.timestep_start >= req.timestep_end:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("timesteps"), String("timestep start must be less than timestep end"))

    if req.sample_every_steps < 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("sample_every_steps"), String("sample cadence cannot be negative"))
    if req.save_every_steps < 0:
        _push_backend_issue(issues, BACKEND_VALIDATION_ERROR, String("save_every_steps"), String("checkpoint cadence cannot be negative"))
    if req.keep_last_n < 1:
        _push_backend_issue(issues, BACKEND_VALIDATION_WARN, String("keep_last_n"), String("checkpoint retention is below 1"))
    return issues^


def backend_validation_error_count(issues: List[BackendValidationIssue]) -> Int32:
    var n: Int32 = 0
    for i in range(len(issues)):
        if issues[i].severity == BACKEND_VALIDATION_ERROR:
            n = n + 1
    return n


def backend_validation_warning_count(issues: List[BackendValidationIssue]) -> Int32:
    var n: Int32 = 0
    for i in range(len(issues)):
        if issues[i].severity == BACKEND_VALIDATION_WARN:
            n = n + 1
    return n


def backend_validation_summary(issues: List[BackendValidationIssue]) -> String:
    var errors = backend_validation_error_count(issues)
    var warnings = backend_validation_warning_count(issues)
    if errors == 0 and warnings == 0:
        return String("Ready")
    if errors == 0:
        return String(warnings) + String(" warning(s)")
    if warnings == 0:
        return String(errors) + String(" error(s)")
    return String(errors) + String(" error(s), ") + String(warnings) + String(" warning(s)")
