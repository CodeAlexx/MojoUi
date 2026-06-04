"""Pure trainer UI state and config snapshot helpers.

This mirrors the Rust Trainer design handoff at the app-model layer: sections,
model/dataset/concept/training/sampling/backup fields, and dataset bucket
assignment. It does not run training and does not touch `mojodiffusion`.
"""

from mojoui.app.model_backend import (
    TrainerRequest,
    RequestParam,
    BackendValidationIssue,
    BackendCapability,
    request_param,
    trainer_task_id_from_model_type,
    make_trainer_capability,
    validate_trainer_request,
    backend_validation_error_count,
    backend_validation_warning_count,
    backend_validation_summary,
    PARAM_STRING,
    PARAM_INT,
    PARAM_BOOL,
)
from mojoui.serde.json import (
    JsonValue,
    JK_BOOL,
    JK_NUMBER,
    JK_STRING,
    JK_ARRAY,
    JK_OBJECT,
    emit_json,
    parse_json,
)
from mojoui.theme.serenity_palettes import SERENITY_PALETTE_COUNT, serenity_palette_name


comptime TRAINER_SECTION_MODEL: Int32 = 0
comptime TRAINER_SECTION_DATASET: Int32 = 1
comptime TRAINER_SECTION_CONCEPTS: Int32 = 2
comptime TRAINER_SECTION_TRAINING: Int32 = 3
comptime TRAINER_SECTION_SAMPLING: Int32 = 4
comptime TRAINER_SECTION_BACKUP: Int32 = 5
comptime TRAINER_SECTION_RUNS: Int32 = 6
comptime TRAINER_SECTION_LOGS: Int32 = 7

comptime TRAINER_VALIDATION_INFO: Int32 = 0
comptime TRAINER_VALIDATION_WARN: Int32 = 1
comptime TRAINER_VALIDATION_ERROR: Int32 = 2

comptime TRAINER_PRESET_SCHEMA = String("mojoui.trainer.preset")
comptime TRAINER_PRESET_VERSION: Int32 = 1


struct TrainerValidationIssue(Copyable, Movable):
    """One validation finding for a trainer form snapshot."""

    var section: Int32
    var severity: Int32
    var field: String
    var message: String

    def __init__(out self):
        self.section = TRAINER_SECTION_MODEL
        self.severity = TRAINER_VALIDATION_INFO
        self.field = String("")
        self.message = String("")

    def __init__(out self, section: Int32, severity: Int32, field: String, message: String):
        self.section = section
        self.severity = severity
        self.field = field.copy()
        self.message = message.copy()


struct BucketSize(Copyable, Movable):
    var width: Int32
    var height: Int32

    def __init__(out self):
        self.width = 0
        self.height = 0

    def __init__(out self, width: Int32, height: Int32):
        self.width = width
        self.height = height


struct DatasetImage(Copyable, Movable):
    var name: String
    var width: Int32
    var height: Int32
    var caption: String
    var bucket_width: Int32
    var bucket_height: Int32

    def __init__(out self):
        self.name = String("")
        self.width = 0
        self.height = 0
        self.caption = String("")
        self.bucket_width = 0
        self.bucket_height = 0

    def __init__(out self, name: String, width: Int32, height: Int32, caption: String):
        self.name = name.copy()
        self.width = width
        self.height = height
        self.caption = caption.copy()
        self.bucket_width = width
        self.bucket_height = height


struct ConceptConfig(Copyable, Movable):
    var name: String
    var folder_path: String
    var image_count: Int32
    var repeats: Int32
    var trigger_token: String
    var has_trigger: Bool
    var caption_strategy: String
    var balancing_weight: Float32
    var enabled: Bool
    var is_regularization: Bool

    def __init__(out self):
        self.name = String("")
        self.folder_path = String("")
        self.image_count = 0
        self.repeats = 1
        self.trigger_token = String("")
        self.has_trigger = False
        self.caption_strategy = String("Keep as-is")
        self.balancing_weight = 1.0
        self.enabled = True
        self.is_regularization = False

    def __init__(
        out self,
        name: String,
        folder_path: String,
        image_count: Int32,
        repeats: Int32,
        trigger_token: String,
        has_trigger: Bool,
        is_regularization: Bool,
    ):
        self.name = name.copy()
        self.folder_path = folder_path.copy()
        self.image_count = image_count
        self.repeats = repeats
        self.trigger_token = trigger_token.copy()
        self.has_trigger = has_trigger
        self.caption_strategy = String("Keep as-is")
        self.balancing_weight = 1.0
        self.enabled = True
        self.is_regularization = is_regularization


struct TrainerState(Movable):
    """All form state for the trainer UI shell."""

    var section_options: List[String]
    var section_index: Int32

    var theme_options: List[String]
    var theme_index: Int32
    var theme_open: Bool

    var backend_id: String
    var run_name: String
    var project_dir: String

    var model_type_options: List[String]
    var model_type_index: Int32
    var model_type_open: Bool
    var architecture_options: List[String]
    var architecture_index: Int32
    var architecture_open: Bool
    var base_model: String
    var vae_override: String
    var precision_options: List[String]
    var precision_index: Int32
    var precision_open: Bool
    var train_text_encoder: Bool

    var network_rank: Float32
    var network_alpha: Float32
    var conv_rank: Float32
    var dropout: Float32
    var target_modules: List[String]

    var dataset_path: String
    var dataset_images: List[DatasetImage]
    var selected_image_index: Int32
    var concepts: List[ConceptConfig]
    var selected_concept_index: Int32

    var target_resolution_options: List[String]
    var target_resolution_index: Int32
    var target_resolution_open: Bool
    var bucket_by_aspect: Bool
    var min_bucket_resolution: Float32
    var max_bucket_resolution: Float32
    var bucket_step: Float32
    var cache_latents: Bool
    var shuffle_captions: Bool
    var caption_dropout: Float32

    var epochs: Float32
    var batch_size: Float32
    var grad_accum: Float32
    var max_train_steps: Float32
    var warmup_steps: Float32

    var optimizer_options: List[String]
    var optimizer_index: Int32
    var optimizer_open: Bool
    var learning_rate: Float32
    var text_encoder_lr: Float32
    var scheduler_options: List[String]
    var scheduler_index: Int32
    var scheduler_open: Bool
    var weight_decay: Float32
    var min_snr_gamma: Float32

    var mixed_precision_options: List[String]
    var mixed_precision_index: Int32
    var mixed_precision_open: Bool
    var gradient_checkpointing: Bool
    var attention_options: List[String]
    var attention_index: Int32
    var attention_open: Bool
    var cpu_offload: Bool
    var seed: Float32
    var deterministic: Bool

    var noise_offset: Float32
    var multi_res_noise: Bool
    var timestep_start: Float32
    var timestep_end: Float32
    var flip_augmentation: Bool
    var color_jitter: Bool

    var sample_every_steps: Float32
    var sample_sampler_options: List[String]
    var sample_sampler_index: Int32
    var sample_sampler_open: Bool
    var sample_steps: Float32
    var sample_cfg: Float32
    var sample_resolution_options: List[String]
    var sample_resolution_index: Int32
    var sample_resolution_open: Bool
    var sample_seed_mode_options: List[String]
    var sample_seed_mode_index: Int32
    var sample_seed_mode_open: Bool
    var sample_prompts: List[String]

    var save_every_steps: Float32
    var keep_last_n: Float32
    var save_optimizer_state: Bool
    var checkpoint_format_options: List[String]
    var checkpoint_format_index: Int32
    var checkpoint_format_open: Bool
    var output_dir: String
    var filename_pattern: String

    def __init__(out self):
        var sections = List[String]()
        sections.append(String("Model"))
        sections.append(String("Dataset"))
        sections.append(String("Concepts"))
        sections.append(String("Training"))
        sections.append(String("Sampling"))
        sections.append(String("Backup"))
        sections.append(String("Runs"))
        sections.append(String("Logs"))
        self.section_options = sections^
        self.section_index = TRAINER_SECTION_TRAINING

        var themes = List[String]()
        for i in range(SERENITY_PALETTE_COUNT):
            themes.append(serenity_palette_name(i))
        self.theme_options = themes^
        self.theme_index = 0
        self.theme_open = False

        self.backend_id = String("mojoui.trainer.stub")
        self.run_name = String("rstprsn-v3")
        self.project_dir = String("~/trainings/rstprsn-v3")

        var model_types = List[String]()
        model_types.append(String("LoRA"))
        model_types.append(String("LoCon"))
        model_types.append(String("DoRA"))
        model_types.append(String("Full fine-tune"))
        model_types.append(String("Textual Inversion"))
        self.model_type_options = model_types^
        self.model_type_index = 0
        self.model_type_open = False

        var archs = List[String]()
        archs.append(String("SDXL 1.0"))
        archs.append(String("SD 1.5"))
        archs.append(String("SD 3.5 Medium"))
        archs.append(String("Flux.1 [dev]"))
        archs.append(String("Flux.1 [schnell]"))
        self.architecture_options = archs^
        self.architecture_index = 0
        self.architecture_open = False

        self.base_model = String("sdxl-1.0-base.safetensors")
        self.vae_override = String("")

        var precs = List[String]()
        precs.append(String("fp32"))
        precs.append(String("fp16"))
        precs.append(String("bf16"))
        self.precision_options = precs^
        self.precision_index = 2
        self.precision_open = False
        self.train_text_encoder = True

        self.network_rank = 64.0
        self.network_alpha = 32.0
        self.conv_rank = 16.0
        self.dropout = 0.05
        var targets = List[String]()
        targets.append(String("attn"))
        targets.append(String("mlp"))
        targets.append(String("te1"))
        targets.append(String("te2"))
        self.target_modules = targets^

        self.dataset_path = String("dataset/person")
        var images = List[DatasetImage]()
        images.append(DatasetImage(String("0001.png"), 1024, 1024, String("a portrait of rstprsn, soft window light, film grain")))
        images.append(DatasetImage(String("0002.png"), 896, 1152, String("rstprsn standing in a forest, overcast, medium shot")))
        images.append(DatasetImage(String("0003.png"), 1152, 896, String("rstprsn at a workbench, warm lamp, hands in frame")))
        images.append(DatasetImage(String("0004.png"), 1024, 1024, String("close-up of rstprsn laughing, shallow depth of field")))
        images.append(DatasetImage(String("0005.png"), 832, 1216, String("full body of rstprsn, denim jacket, city street, dusk")))
        images.append(DatasetImage(String("0006.png"), 1216, 832, String("rstprsn sitting on stone steps, golden hour")))
        self.dataset_images = images^
        self.selected_image_index = 0

        var concepts = List[ConceptConfig]()
        concepts.append(ConceptConfig(String("rstprsn"), String("dataset/person"), 12, 6, String("rstprsn"), True, False))
        concepts.append(ConceptConfig(String("regularization"), String("dataset/reg/person"), 200, 1, String("person"), False, True))
        self.concepts = concepts^
        self.selected_concept_index = 0

        var res = List[String]()
        res.append(String("512"))
        res.append(String("768"))
        res.append(String("1024"))
        res.append(String("1280"))
        self.target_resolution_options = res^
        self.target_resolution_index = 2
        self.target_resolution_open = False
        self.bucket_by_aspect = True
        self.min_bucket_resolution = 512.0
        self.max_bucket_resolution = 1536.0
        self.bucket_step = 64.0
        self.cache_latents = True
        self.shuffle_captions = True
        self.caption_dropout = 0.10

        self.epochs = 20.0
        self.batch_size = 2.0
        self.grad_accum = 4.0
        self.max_train_steps = 0.0
        self.warmup_steps = 100.0

        var opts = List[String]()
        opts.append(String("AdamW"))
        opts.append(String("AdamW 8bit"))
        opts.append(String("Lion"))
        opts.append(String("Prodigy"))
        opts.append(String("AdaFactor"))
        opts.append(String("DAdaptAdam"))
        self.optimizer_options = opts^
        self.optimizer_index = 1
        self.optimizer_open = False
        self.learning_rate = 0.0001
        self.text_encoder_lr = 0.00005

        var scheds = List[String]()
        scheds.append(String("cosine"))
        scheds.append(String("cosine_with_restarts"))
        scheds.append(String("linear"))
        scheds.append(String("constant"))
        scheds.append(String("constant_with_warmup"))
        scheds.append(String("polynomial"))
        self.scheduler_options = scheds^
        self.scheduler_index = 0
        self.scheduler_open = False
        self.weight_decay = 0.01
        self.min_snr_gamma = 5.0

        var mixed = List[String]()
        mixed.append(String("no"))
        mixed.append(String("fp16"))
        mixed.append(String("bf16"))
        self.mixed_precision_options = mixed^
        self.mixed_precision_index = 2
        self.mixed_precision_open = False
        self.gradient_checkpointing = True

        var attn = List[String]()
        attn.append(String("sdpa"))
        attn.append(String("xformers"))
        attn.append(String("flash-attn-2"))
        attn.append(String("math"))
        self.attention_options = attn^
        self.attention_index = 1
        self.attention_open = False
        self.cpu_offload = False
        self.seed = 42.0
        self.deterministic = False

        self.noise_offset = 0.05
        self.multi_res_noise = True
        self.timestep_start = 0.0
        self.timestep_end = 1000.0
        self.flip_augmentation = True
        self.color_jitter = False

        self.sample_every_steps = 250.0
        var sample_samplers = List[String]()
        sample_samplers.append(String("Euler"))
        sample_samplers.append(String("Euler a"))
        sample_samplers.append(String("DPM++ 2M Karras"))
        sample_samplers.append(String("DDIM"))
        sample_samplers.append(String("DPM++ SDE"))
        self.sample_sampler_options = sample_samplers^
        self.sample_sampler_index = 1
        self.sample_sampler_open = False
        self.sample_steps = 28.0
        self.sample_cfg = 5.5

        var sample_res = List[String]()
        sample_res.append(String("512x512"))
        sample_res.append(String("768x768"))
        sample_res.append(String("1024x1024"))
        sample_res.append(String("896x1152"))
        sample_res.append(String("1152x896"))
        self.sample_resolution_options = sample_res^
        self.sample_resolution_index = 2
        self.sample_resolution_open = False

        var seed_modes = List[String]()
        seed_modes.append(String("Random"))
        seed_modes.append(String("Fixed per prompt"))
        seed_modes.append(String("Sequential"))
        self.sample_seed_mode_options = seed_modes^
        self.sample_seed_mode_index = 1
        self.sample_seed_mode_open = False

        var prompts = List[String]()
        prompts.append(String("rstprsn portrait, cinematic lighting, 35mm"))
        prompts.append(String("rstprsn in a library, warm lamps, reading a book"))
        prompts.append(String("rstprsn hiking, mountain ridge, dramatic sky"))
        self.sample_prompts = prompts^

        self.save_every_steps = 500.0
        self.keep_last_n = 5.0
        self.save_optimizer_state = True
        var formats = List[String]()
        formats.append(String("safetensors"))
        formats.append(String("ckpt"))
        formats.append(String("diffusers"))
        self.checkpoint_format_options = formats^
        self.checkpoint_format_index = 0
        self.checkpoint_format_open = False
        self.output_dir = String("output/rstprsn-v3")
        self.filename_pattern = String("rstprsn-v3-{step:06d}.safetensors")

        assign_dataset_buckets(self)

    def section_label(self) -> String:
        return self.section_options[Int(self.section_index)]

    def theme_label(self) -> String:
        return self.theme_options[Int(self.theme_index)]

    def model_type_label(self) -> String:
        return self.model_type_options[Int(self.model_type_index)]

    def architecture_label(self) -> String:
        return self.architecture_options[Int(self.architecture_index)]

    def precision_label(self) -> String:
        return self.precision_options[Int(self.precision_index)]

    def target_resolution(self) -> Int32:
        if self.target_resolution_index == 0:
            return 512
        if self.target_resolution_index == 1:
            return 768
        if self.target_resolution_index == 3:
            return 1280
        return 1024

    def optimizer_label(self) -> String:
        return self.optimizer_options[Int(self.optimizer_index)]

    def scheduler_label(self) -> String:
        return self.scheduler_options[Int(self.scheduler_index)]

    def mixed_precision_label(self) -> String:
        return self.mixed_precision_options[Int(self.mixed_precision_index)]

    def attention_label(self) -> String:
        return self.attention_options[Int(self.attention_index)]

    def sample_sampler_label(self) -> String:
        return self.sample_sampler_options[Int(self.sample_sampler_index)]

    def sample_resolution_label(self) -> String:
        return self.sample_resolution_options[Int(self.sample_resolution_index)]

    def sample_seed_mode_label(self) -> String:
        return self.sample_seed_mode_options[Int(self.sample_seed_mode_index)]

    def checkpoint_format_label(self) -> String:
        return self.checkpoint_format_options[Int(self.checkpoint_format_index)]


def _clamp_i32(value: Int32, lo: Int32, hi: Int32) -> Int32:
    var out = value
    if out < lo:
        out = lo
    if out > hi:
        out = hi
    return out


def _round_to_step(value: Int32, step: Int32) -> Int32:
    if step <= 0:
        return value
    return ((value + step // 2) // step) * step


def bucket_for_image(
    width: Int32,
    height: Int32,
    target_resolution: Int32,
    min_resolution: Int32,
    max_resolution: Int32,
    bucket_step: Int32,
) -> BucketSize:
    """Aspect-preserving bucket assignment from the trainer handoff."""
    if width <= 0 or height <= 0:
        return BucketSize(target_resolution, target_resolution)

    var target = _clamp_i32(target_resolution, min_resolution, max_resolution)
    if width >= height:
        var bw = _round_to_step(target, bucket_step)
        var bh = _round_to_step(
            Int32(Float32(Int(height)) * Float32(Int(target)) / Float32(Int(width)) + 0.5),
            bucket_step,
        )
        bw = _clamp_i32(bw, min_resolution, max_resolution)
        bh = _clamp_i32(bh, min_resolution, max_resolution)
        return BucketSize(bw, bh)

    var bh = _round_to_step(target, bucket_step)
    var bw = _round_to_step(
        Int32(Float32(Int(width)) * Float32(Int(target)) / Float32(Int(height)) + 0.5),
        bucket_step,
    )
    bw = _clamp_i32(bw, min_resolution, max_resolution)
    bh = _clamp_i32(bh, min_resolution, max_resolution)
    return BucketSize(bw, bh)


def assign_dataset_buckets(mut state: TrainerState):
    var min_res = Int32(Int(state.min_bucket_resolution))
    var max_res = Int32(Int(state.max_bucket_resolution))
    var step = Int32(Int(state.bucket_step))
    var target = state.target_resolution()
    for i in range(len(state.dataset_images)):
        var b = bucket_for_image(
            state.dataset_images[i].width,
            state.dataset_images[i].height,
            target,
            min_res,
            max_res,
            step,
        )
        state.dataset_images[i].bucket_width = b.width
        state.dataset_images[i].bucket_height = b.height


def trainer_dataset_image_count(state: TrainerState) -> Int32:
    var total = 0
    for i in range(len(state.concepts)):
        if state.concepts[i].enabled and not state.concepts[i].is_regularization:
            total = total + Int(state.concepts[i].image_count * state.concepts[i].repeats)
    if total <= 0:
        total = len(state.dataset_images)
    return Int32(total)


def trainer_request_from_state(state: TrainerState, job_id: UInt64) -> TrainerRequest:
    """Snapshot current trainer form state into a backend-neutral request."""
    var req = TrainerRequest()
    req.id = job_id
    req.task_id = trainer_task_id_from_model_type(state.model_type_label())
    req.backend_id = state.backend_id.copy()
    req.run_name = state.run_name.copy()
    req.project_dir = state.project_dir.copy()
    req.model_type = state.model_type_label()
    req.architecture = state.architecture_label()
    req.base_model = state.base_model.copy()
    req.vae_override = state.vae_override.copy()
    req.precision = state.precision_label()
    req.train_text_encoder = state.train_text_encoder
    req.network_rank = Int32(Int(state.network_rank))
    req.network_alpha = Int32(Int(state.network_alpha))
    req.conv_rank = Int32(Int(state.conv_rank))
    req.dropout = state.dropout
    req.target_modules = state.target_modules.copy()
    req.dataset_path = state.dataset_path.copy()
    req.output_dir = state.output_dir.copy()
    req.dataset_image_count = trainer_dataset_image_count(state)
    req.concept_count = Int32(len(state.concepts))
    req.target_resolution = state.target_resolution()
    req.bucket_by_aspect = state.bucket_by_aspect
    req.min_bucket_resolution = Int32(Int(state.min_bucket_resolution))
    req.max_bucket_resolution = Int32(Int(state.max_bucket_resolution))
    req.bucket_step = Int32(Int(state.bucket_step))
    req.cache_latents = state.cache_latents
    req.shuffle_captions = state.shuffle_captions
    req.caption_dropout = state.caption_dropout
    req.epochs = Int32(Int(state.epochs))
    req.batch_size = Int32(Int(state.batch_size))
    req.grad_accum = Int32(Int(state.grad_accum))
    req.max_train_steps = Int32(Int(state.max_train_steps))
    req.warmup_steps = Int32(Int(state.warmup_steps))
    req.optimizer = state.optimizer_label()
    req.learning_rate = state.learning_rate
    req.text_encoder_lr = state.text_encoder_lr
    req.lr_scheduler = state.scheduler_label()
    req.weight_decay = state.weight_decay
    req.min_snr_gamma = state.min_snr_gamma
    req.mixed_precision = state.mixed_precision_label()
    req.gradient_checkpointing = state.gradient_checkpointing
    req.attention = state.attention_label()
    req.cpu_offload = state.cpu_offload
    req.seed = Int64(Int(state.seed))
    req.deterministic = state.deterministic
    req.noise_offset = state.noise_offset
    req.multi_res_noise = state.multi_res_noise
    req.timestep_start = Int32(Int(state.timestep_start))
    req.timestep_end = Int32(Int(state.timestep_end))
    req.flip_augmentation = state.flip_augmentation
    req.color_jitter = state.color_jitter
    req.sample_every_steps = Int32(Int(state.sample_every_steps))
    req.sample_sampler = state.sample_sampler_label()
    req.sample_steps = Int32(Int(state.sample_steps))
    req.sample_cfg = state.sample_cfg
    req.sample_resolution = state.sample_resolution_label()
    req.sample_seed_mode = state.sample_seed_mode_label()
    req.save_every_steps = Int32(Int(state.save_every_steps))
    req.keep_last_n = Int32(Int(state.keep_last_n))
    req.save_optimizer_state = state.save_optimizer_state
    req.checkpoint_format = state.checkpoint_format_label()
    req.filename_pattern = state.filename_pattern.copy()

    var meta = List[RequestParam]()
    meta.append(request_param(String("theme"), state.theme_label(), PARAM_STRING))
    meta.append(request_param(String("bucket_by_aspect"), String(state.bucket_by_aspect), PARAM_BOOL))
    meta.append(request_param(String("sample_prompt_count"), String(len(state.sample_prompts)), PARAM_INT))
    req.metadata = meta^
    return req^


def _state_capability(state: TrainerState) -> BackendCapability:
    return make_trainer_capability(state.backend_id.copy(), String("MojoUI Trainer"))


def trainer_backend_validation_issues(state: TrainerState) -> List[BackendValidationIssue]:
    var req = trainer_request_from_state(state, UInt64(0))
    var cap = _state_capability(state)
    return validate_trainer_request(req, cap)


def trainer_validation_issues(state: TrainerState) -> List[TrainerValidationIssue]:
    """Validate UI form state, including backend-neutral request checks."""
    var out = List[TrainerValidationIssue]()
    var backend = trainer_backend_validation_issues(state)
    for i in range(len(backend)):
        var section = TRAINER_SECTION_TRAINING
        var field = backend[i].field.copy()
        if field == String("backend") or field == String("model_type") or field == String("base_model") or field == String("network_rank") or field == String("network_alpha") or field == String("dropout"):
            section = TRAINER_SECTION_MODEL
        elif field == String("dataset") or field == String("dataset_path") or field == String("bucket_resolution") or field == String("bucket_step") or field == String("target_resolution"):
            section = TRAINER_SECTION_DATASET
        elif field == String("output_dir") or field == String("save_every_steps") or field == String("keep_last_n"):
            section = TRAINER_SECTION_BACKUP
        elif field == String("sample_every_steps"):
            section = TRAINER_SECTION_SAMPLING
        out.append(TrainerValidationIssue(section, backend[i].severity, field^, backend[i].message.copy()))

    var enabled_concepts = 0
    for i in range(len(state.concepts)):
        if state.concepts[i].enabled:
            enabled_concepts = enabled_concepts + 1
            if state.concepts[i].image_count <= 0:
                out.append(TrainerValidationIssue(TRAINER_SECTION_CONCEPTS, TRAINER_VALIDATION_WARN, String("concepts"), state.concepts[i].name.copy() + String(" has no images")))
            if state.concepts[i].repeats <= 0:
                out.append(TrainerValidationIssue(TRAINER_SECTION_CONCEPTS, TRAINER_VALIDATION_ERROR, String("concepts"), state.concepts[i].name.copy() + String(" repeats must be positive")))
    if enabled_concepts == 0:
        out.append(TrainerValidationIssue(TRAINER_SECTION_CONCEPTS, TRAINER_VALIDATION_ERROR, String("concepts"), String("at least one concept must be enabled")))
    if len(state.sample_prompts) == 0:
        out.append(TrainerValidationIssue(TRAINER_SECTION_SAMPLING, TRAINER_VALIDATION_WARN, String("sample_prompts"), String("no sample prompts configured")))
    return out^


def trainer_validation_error_count(issues: List[TrainerValidationIssue]) -> Int32:
    var n: Int32 = 0
    for i in range(len(issues)):
        if issues[i].severity == TRAINER_VALIDATION_ERROR:
            n = n + 1
    return n


def trainer_validation_warning_count(issues: List[TrainerValidationIssue]) -> Int32:
    var n: Int32 = 0
    for i in range(len(issues)):
        if issues[i].severity == TRAINER_VALIDATION_WARN:
            n = n + 1
    return n


def trainer_validation_summary(issues: List[TrainerValidationIssue]) -> String:
    var errors = trainer_validation_error_count(issues)
    var warnings = trainer_validation_warning_count(issues)
    if errors == 0 and warnings == 0:
        return String("Ready")
    if errors == 0:
        return String(warnings) + String(" warning(s)")
    if warnings == 0:
        return String(errors) + String(" error(s)")
    return String(errors) + String(" error(s), ") + String(warnings) + String(" warning(s)")


def trainer_state_is_valid(state: TrainerState) -> Bool:
    var issues = trainer_validation_issues(state)
    return trainer_validation_error_count(issues) == 0


def _j_string(value: String) -> JsonValue:
    return JsonValue.string(value.copy())


def _j_i32(value: Int32) -> JsonValue:
    return JsonValue.number_i(Int(value))


def _j_f32(value: Float32) -> JsonValue:
    return JsonValue.number(Float64(value))


def _j_bool(value: Bool) -> JsonValue:
    return JsonValue.bool_(value)


def _json_obj(value: JsonValue) -> JsonValue:
    if value.kind == JK_OBJECT:
        return value.copy()
    return JsonValue.empty_object()


def _json_string(obj: JsonValue, key: String, fallback: String) -> String:
    var v = obj.get_object_field(key)
    if v.kind == JK_STRING:
        return v.str_val.copy()
    return fallback.copy()


def _json_i32(obj: JsonValue, key: String, fallback: Int32) -> Int32:
    var v = obj.get_object_field(key)
    if v.kind == JK_NUMBER:
        return Int32(Int(v.num_val))
    return fallback


def _json_f32(obj: JsonValue, key: String, fallback: Float32) -> Float32:
    var v = obj.get_object_field(key)
    if v.kind == JK_NUMBER:
        return Float32(v.num_val)
    return fallback


def _json_bool(obj: JsonValue, key: String, fallback: Bool) -> Bool:
    var v = obj.get_object_field(key)
    if v.kind == JK_BOOL:
        return v.bool_val
    return fallback


def _find_option_index(options: List[String], value: String, fallback: Int32) -> Int32:
    for i in range(len(options)):
        if options[i] == value:
            return Int32(i)
    return fallback


def _strings_to_json(items: List[String]) -> JsonValue:
    var arr = List[JsonValue]()
    for i in range(len(items)):
        arr.append(_j_string(items[i].copy()))
    return JsonValue.array(arr^)


def _strings_from_json(value: JsonValue, fallback: List[String]) -> List[String]:
    if value.kind != JK_ARRAY:
        return fallback.copy()
    var out = List[String]()
    for i in range(len(value.arr_val)):
        if value.arr_val[i].kind == JK_STRING:
            out.append(value.arr_val[i].str_val.copy())
    if len(out) == 0 and len(fallback) > 0:
        return fallback.copy()
    return out^


def _concept_to_json(c: ConceptConfig) -> JsonValue:
    var obj = JsonValue.empty_object()
    obj.set_object_field(String("name"), _j_string(c.name.copy()))
    obj.set_object_field(String("folder_path"), _j_string(c.folder_path.copy()))
    obj.set_object_field(String("image_count"), _j_i32(c.image_count))
    obj.set_object_field(String("repeats"), _j_i32(c.repeats))
    obj.set_object_field(String("trigger_token"), _j_string(c.trigger_token.copy()))
    obj.set_object_field(String("has_trigger"), _j_bool(c.has_trigger))
    obj.set_object_field(String("caption_strategy"), _j_string(c.caption_strategy.copy()))
    obj.set_object_field(String("balancing_weight"), _j_f32(c.balancing_weight))
    obj.set_object_field(String("enabled"), _j_bool(c.enabled))
    obj.set_object_field(String("is_regularization"), _j_bool(c.is_regularization))
    return obj^


def _concepts_to_json(concepts: List[ConceptConfig]) -> JsonValue:
    var arr = List[JsonValue]()
    for i in range(len(concepts)):
        arr.append(_concept_to_json(concepts[i]))
    return JsonValue.array(arr^)


def _concept_from_json(value: JsonValue) -> ConceptConfig:
    var obj = _json_obj(value)
    var c = ConceptConfig()
    c.name = _json_string(obj, String("name"), c.name.copy())
    c.folder_path = _json_string(obj, String("folder_path"), c.folder_path.copy())
    c.image_count = _json_i32(obj, String("image_count"), c.image_count)
    c.repeats = _json_i32(obj, String("repeats"), c.repeats)
    c.trigger_token = _json_string(obj, String("trigger_token"), c.trigger_token.copy())
    c.has_trigger = _json_bool(obj, String("has_trigger"), c.has_trigger)
    c.caption_strategy = _json_string(obj, String("caption_strategy"), c.caption_strategy.copy())
    c.balancing_weight = _json_f32(obj, String("balancing_weight"), c.balancing_weight)
    c.enabled = _json_bool(obj, String("enabled"), c.enabled)
    c.is_regularization = _json_bool(obj, String("is_regularization"), c.is_regularization)
    return c^


def _concepts_from_json(value: JsonValue, fallback: List[ConceptConfig]) -> List[ConceptConfig]:
    if value.kind != JK_ARRAY:
        return fallback.copy()
    var out = List[ConceptConfig]()
    for i in range(len(value.arr_val)):
        if value.arr_val[i].kind == JK_OBJECT:
            out.append(_concept_from_json(value.arr_val[i]))
    if len(out) == 0 and len(fallback) > 0:
        return fallback.copy()
    return out^


def _image_to_json(img: DatasetImage) -> JsonValue:
    var obj = JsonValue.empty_object()
    obj.set_object_field(String("name"), _j_string(img.name.copy()))
    obj.set_object_field(String("width"), _j_i32(img.width))
    obj.set_object_field(String("height"), _j_i32(img.height))
    obj.set_object_field(String("caption"), _j_string(img.caption.copy()))
    return obj^


def _images_to_json(images: List[DatasetImage]) -> JsonValue:
    var arr = List[JsonValue]()
    for i in range(len(images)):
        arr.append(_image_to_json(images[i]))
    return JsonValue.array(arr^)


def _image_from_json(value: JsonValue) -> DatasetImage:
    var obj = _json_obj(value)
    var img = DatasetImage()
    img.name = _json_string(obj, String("name"), img.name.copy())
    img.width = _json_i32(obj, String("width"), img.width)
    img.height = _json_i32(obj, String("height"), img.height)
    img.caption = _json_string(obj, String("caption"), img.caption.copy())
    img.bucket_width = img.width
    img.bucket_height = img.height
    return img^


def _images_from_json(value: JsonValue, fallback: List[DatasetImage]) -> List[DatasetImage]:
    if value.kind != JK_ARRAY:
        return fallback.copy()
    var out = List[DatasetImage]()
    for i in range(len(value.arr_val)):
        if value.arr_val[i].kind == JK_OBJECT:
            out.append(_image_from_json(value.arr_val[i]))
    if len(out) == 0 and len(fallback) > 0:
        return fallback.copy()
    return out^


def trainer_preset_json_from_state(state: TrainerState) -> String:
    """Serialize full trainer UI state as a stable, model-agnostic preset."""
    var root = JsonValue.empty_object()
    root.set_object_field(String("kind"), _j_string(String("mojoui.trainer.preset")))
    root.set_object_field(String("schema_version"), _j_i32(TRAINER_PRESET_VERSION))
    root.set_object_field(String("backend_id"), _j_string(state.backend_id.copy()))

    var run = JsonValue.empty_object()
    run.set_object_field(String("name"), _j_string(state.run_name.copy()))
    run.set_object_field(String("project_dir"), _j_string(state.project_dir.copy()))
    run.set_object_field(String("output_dir"), _j_string(state.output_dir.copy()))
    root.set_object_field(String("run"), run^)

    var model = JsonValue.empty_object()
    model.set_object_field(String("type"), _j_string(state.model_type_label()))
    model.set_object_field(String("architecture"), _j_string(state.architecture_label()))
    model.set_object_field(String("base_model"), _j_string(state.base_model.copy()))
    model.set_object_field(String("vae_override"), _j_string(state.vae_override.copy()))
    model.set_object_field(String("precision"), _j_string(state.precision_label()))
    model.set_object_field(String("train_text_encoder"), _j_bool(state.train_text_encoder))
    root.set_object_field(String("model"), model^)

    var network = JsonValue.empty_object()
    network.set_object_field(String("rank"), _j_f32(state.network_rank))
    network.set_object_field(String("alpha"), _j_f32(state.network_alpha))
    network.set_object_field(String("conv_rank"), _j_f32(state.conv_rank))
    network.set_object_field(String("dropout"), _j_f32(state.dropout))
    network.set_object_field(String("target_modules"), _strings_to_json(state.target_modules))
    root.set_object_field(String("network"), network^)

    var bucket = JsonValue.empty_object()
    bucket.set_object_field(String("target_resolution"), _j_i32(state.target_resolution()))
    bucket.set_object_field(String("bucket_by_aspect"), _j_bool(state.bucket_by_aspect))
    bucket.set_object_field(String("min_resolution"), _j_f32(state.min_bucket_resolution))
    bucket.set_object_field(String("max_resolution"), _j_f32(state.max_bucket_resolution))
    bucket.set_object_field(String("step"), _j_f32(state.bucket_step))

    var dataset = JsonValue.empty_object()
    dataset.set_object_field(String("path"), _j_string(state.dataset_path.copy()))
    dataset.set_object_field(String("bucket"), bucket^)
    dataset.set_object_field(String("cache_latents"), _j_bool(state.cache_latents))
    dataset.set_object_field(String("shuffle_captions"), _j_bool(state.shuffle_captions))
    dataset.set_object_field(String("caption_dropout"), _j_f32(state.caption_dropout))
    dataset.set_object_field(String("images"), _images_to_json(state.dataset_images))
    dataset.set_object_field(String("concepts"), _concepts_to_json(state.concepts))
    root.set_object_field(String("dataset"), dataset^)

    var training = JsonValue.empty_object()
    training.set_object_field(String("epochs"), _j_f32(state.epochs))
    training.set_object_field(String("batch_size"), _j_f32(state.batch_size))
    training.set_object_field(String("grad_accum"), _j_f32(state.grad_accum))
    training.set_object_field(String("max_train_steps"), _j_f32(state.max_train_steps))
    training.set_object_field(String("warmup_steps"), _j_f32(state.warmup_steps))
    training.set_object_field(String("optimizer"), _j_string(state.optimizer_label()))
    training.set_object_field(String("learning_rate"), _j_f32(state.learning_rate))
    training.set_object_field(String("text_encoder_lr"), _j_f32(state.text_encoder_lr))
    training.set_object_field(String("scheduler"), _j_string(state.scheduler_label()))
    training.set_object_field(String("weight_decay"), _j_f32(state.weight_decay))
    training.set_object_field(String("min_snr_gamma"), _j_f32(state.min_snr_gamma))
    training.set_object_field(String("mixed_precision"), _j_string(state.mixed_precision_label()))
    training.set_object_field(String("gradient_checkpointing"), _j_bool(state.gradient_checkpointing))
    training.set_object_field(String("attention"), _j_string(state.attention_label()))
    training.set_object_field(String("cpu_offload"), _j_bool(state.cpu_offload))
    training.set_object_field(String("seed"), _j_f32(state.seed))
    training.set_object_field(String("deterministic"), _j_bool(state.deterministic))
    training.set_object_field(String("noise_offset"), _j_f32(state.noise_offset))
    training.set_object_field(String("multi_res_noise"), _j_bool(state.multi_res_noise))
    training.set_object_field(String("timestep_start"), _j_f32(state.timestep_start))
    training.set_object_field(String("timestep_end"), _j_f32(state.timestep_end))
    training.set_object_field(String("flip_augmentation"), _j_bool(state.flip_augmentation))
    training.set_object_field(String("color_jitter"), _j_bool(state.color_jitter))
    root.set_object_field(String("training"), training^)

    var sampling = JsonValue.empty_object()
    sampling.set_object_field(String("every_steps"), _j_f32(state.sample_every_steps))
    sampling.set_object_field(String("sampler"), _j_string(state.sample_sampler_label()))
    sampling.set_object_field(String("steps"), _j_f32(state.sample_steps))
    sampling.set_object_field(String("cfg"), _j_f32(state.sample_cfg))
    sampling.set_object_field(String("resolution"), _j_string(state.sample_resolution_label()))
    sampling.set_object_field(String("seed_mode"), _j_string(state.sample_seed_mode_label()))
    sampling.set_object_field(String("prompts"), _strings_to_json(state.sample_prompts))
    root.set_object_field(String("sampling"), sampling^)

    var backup = JsonValue.empty_object()
    backup.set_object_field(String("save_every_steps"), _j_f32(state.save_every_steps))
    backup.set_object_field(String("keep_last_n"), _j_f32(state.keep_last_n))
    backup.set_object_field(String("save_optimizer_state"), _j_bool(state.save_optimizer_state))
    backup.set_object_field(String("format"), _j_string(state.checkpoint_format_label()))
    backup.set_object_field(String("filename_pattern"), _j_string(state.filename_pattern.copy()))
    root.set_object_field(String("backup"), backup^)

    var ui = JsonValue.empty_object()
    ui.set_object_field(String("theme"), _j_string(state.theme_label()))
    root.set_object_field(String("ui"), ui^)
    return emit_json(root)


def trainer_state_to_preset_json(state: TrainerState) -> String:
    return trainer_preset_json_from_state(state)


def trainer_state_apply_preset_json(mut state: TrainerState, raw: String) raises:
    """Apply a preset JSON string to existing UI state.

    Existing option lists stay intact; label fields are mapped back to current
    option indexes. Missing fields keep their current values.
    """
    var root = parse_json(raw)
    if root.kind != JK_OBJECT:
        raise Error("trainer preset must be a JSON object")
    var kind = _json_string(root, String("kind"), String(""))
    if kind != String("") and kind != String("mojoui.trainer.preset"):
        raise Error("unsupported trainer preset kind: " + kind)
    var version = _json_i32(root, String("schema_version"), TRAINER_PRESET_VERSION)
    if version != TRAINER_PRESET_VERSION:
        raise Error("unsupported trainer preset version: " + String(version))

    state.backend_id = _json_string(root, String("backend_id"), state.backend_id.copy())

    var run = _json_obj(root.get_object_field(String("run")))
    state.run_name = _json_string(run, String("name"), state.run_name.copy())
    state.project_dir = _json_string(run, String("project_dir"), state.project_dir.copy())
    state.output_dir = _json_string(run, String("output_dir"), state.output_dir.copy())

    var model = _json_obj(root.get_object_field(String("model")))
    state.model_type_index = _find_option_index(state.model_type_options, _json_string(model, String("type"), state.model_type_label()), state.model_type_index)
    state.architecture_index = _find_option_index(state.architecture_options, _json_string(model, String("architecture"), state.architecture_label()), state.architecture_index)
    state.base_model = _json_string(model, String("base_model"), state.base_model.copy())
    state.vae_override = _json_string(model, String("vae_override"), state.vae_override.copy())
    state.precision_index = _find_option_index(state.precision_options, _json_string(model, String("precision"), state.precision_label()), state.precision_index)
    state.train_text_encoder = _json_bool(model, String("train_text_encoder"), state.train_text_encoder)

    var network = _json_obj(root.get_object_field(String("network")))
    state.network_rank = _json_f32(network, String("rank"), state.network_rank)
    state.network_alpha = _json_f32(network, String("alpha"), state.network_alpha)
    state.conv_rank = _json_f32(network, String("conv_rank"), state.conv_rank)
    state.dropout = _json_f32(network, String("dropout"), state.dropout)
    state.target_modules = _strings_from_json(network.get_object_field(String("target_modules")), state.target_modules)

    var dataset = _json_obj(root.get_object_field(String("dataset")))
    state.dataset_path = _json_string(dataset, String("path"), state.dataset_path.copy())
    state.cache_latents = _json_bool(dataset, String("cache_latents"), state.cache_latents)
    state.shuffle_captions = _json_bool(dataset, String("shuffle_captions"), state.shuffle_captions)
    state.caption_dropout = _json_f32(dataset, String("caption_dropout"), state.caption_dropout)
    state.dataset_images = _images_from_json(dataset.get_object_field(String("images")), state.dataset_images)
    state.concepts = _concepts_from_json(dataset.get_object_field(String("concepts")), state.concepts)
    var bucket = _json_obj(dataset.get_object_field(String("bucket")))
    var target_res = _json_i32(bucket, String("target_resolution"), state.target_resolution())
    state.target_resolution_index = _find_option_index(state.target_resolution_options, String(target_res), state.target_resolution_index)
    state.bucket_by_aspect = _json_bool(bucket, String("bucket_by_aspect"), state.bucket_by_aspect)
    state.min_bucket_resolution = _json_f32(bucket, String("min_resolution"), state.min_bucket_resolution)
    state.max_bucket_resolution = _json_f32(bucket, String("max_resolution"), state.max_bucket_resolution)
    state.bucket_step = _json_f32(bucket, String("step"), state.bucket_step)

    var training = _json_obj(root.get_object_field(String("training")))
    state.epochs = _json_f32(training, String("epochs"), state.epochs)
    state.batch_size = _json_f32(training, String("batch_size"), state.batch_size)
    state.grad_accum = _json_f32(training, String("grad_accum"), state.grad_accum)
    state.max_train_steps = _json_f32(training, String("max_train_steps"), state.max_train_steps)
    state.warmup_steps = _json_f32(training, String("warmup_steps"), state.warmup_steps)
    state.optimizer_index = _find_option_index(state.optimizer_options, _json_string(training, String("optimizer"), state.optimizer_label()), state.optimizer_index)
    state.learning_rate = _json_f32(training, String("learning_rate"), state.learning_rate)
    state.text_encoder_lr = _json_f32(training, String("text_encoder_lr"), state.text_encoder_lr)
    state.scheduler_index = _find_option_index(state.scheduler_options, _json_string(training, String("scheduler"), state.scheduler_label()), state.scheduler_index)
    state.weight_decay = _json_f32(training, String("weight_decay"), state.weight_decay)
    state.min_snr_gamma = _json_f32(training, String("min_snr_gamma"), state.min_snr_gamma)
    state.mixed_precision_index = _find_option_index(state.mixed_precision_options, _json_string(training, String("mixed_precision"), state.mixed_precision_label()), state.mixed_precision_index)
    state.gradient_checkpointing = _json_bool(training, String("gradient_checkpointing"), state.gradient_checkpointing)
    state.attention_index = _find_option_index(state.attention_options, _json_string(training, String("attention"), state.attention_label()), state.attention_index)
    state.cpu_offload = _json_bool(training, String("cpu_offload"), state.cpu_offload)
    state.seed = _json_f32(training, String("seed"), state.seed)
    state.deterministic = _json_bool(training, String("deterministic"), state.deterministic)
    state.noise_offset = _json_f32(training, String("noise_offset"), state.noise_offset)
    state.multi_res_noise = _json_bool(training, String("multi_res_noise"), state.multi_res_noise)
    state.timestep_start = _json_f32(training, String("timestep_start"), state.timestep_start)
    state.timestep_end = _json_f32(training, String("timestep_end"), state.timestep_end)
    state.flip_augmentation = _json_bool(training, String("flip_augmentation"), state.flip_augmentation)
    state.color_jitter = _json_bool(training, String("color_jitter"), state.color_jitter)

    var sampling = _json_obj(root.get_object_field(String("sampling")))
    state.sample_every_steps = _json_f32(sampling, String("every_steps"), state.sample_every_steps)
    state.sample_sampler_index = _find_option_index(state.sample_sampler_options, _json_string(sampling, String("sampler"), state.sample_sampler_label()), state.sample_sampler_index)
    state.sample_steps = _json_f32(sampling, String("steps"), state.sample_steps)
    state.sample_cfg = _json_f32(sampling, String("cfg"), state.sample_cfg)
    state.sample_resolution_index = _find_option_index(state.sample_resolution_options, _json_string(sampling, String("resolution"), state.sample_resolution_label()), state.sample_resolution_index)
    state.sample_seed_mode_index = _find_option_index(state.sample_seed_mode_options, _json_string(sampling, String("seed_mode"), state.sample_seed_mode_label()), state.sample_seed_mode_index)
    state.sample_prompts = _strings_from_json(sampling.get_object_field(String("prompts")), state.sample_prompts)

    var backup = _json_obj(root.get_object_field(String("backup")))
    state.save_every_steps = _json_f32(backup, String("save_every_steps"), state.save_every_steps)
    state.keep_last_n = _json_f32(backup, String("keep_last_n"), state.keep_last_n)
    state.save_optimizer_state = _json_bool(backup, String("save_optimizer_state"), state.save_optimizer_state)
    state.checkpoint_format_index = _find_option_index(state.checkpoint_format_options, _json_string(backup, String("format"), state.checkpoint_format_label()), state.checkpoint_format_index)
    state.filename_pattern = _json_string(backup, String("filename_pattern"), state.filename_pattern.copy())

    var ui = _json_obj(root.get_object_field(String("ui")))
    state.theme_index = _find_option_index(state.theme_options, _json_string(ui, String("theme"), state.theme_label()), state.theme_index)
    assign_dataset_buckets(state)
