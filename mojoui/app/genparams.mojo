"""serenity.genparams.v1 — the gen screen's SINGLE param-state struct (plan H1)
plus the observer-seam store (plan H2).

H1 (single source of truth): `GenParams` is the ONE serializable param state
for the generation screen. Its canonical JSON form IS the
`serenity.genparams.v1` schema — the same flat body POST /v1/generate accepts,
the same JSON the daemon embeds in the output PNG's tEXt chunk and in
jobs.db, plus the UI-owned-but-daemon-passthrough fields (sampler, scheduler,
variation_seed, variation_strength, images).

H2 (observer seam): ALL edits land through ONE dispatch point —
`GenParamStore.set()`. Widgets never mutate `params` directly: they edit the
store's *mirror* fields (Float32/index bindings the immediate-mode widgets
need), and the screen calls `commit_mirrors()` once per frame, which builds a
GenParams from the mirrors and routes it through `set()` when anything
changed. External writers (preset load, PNG reuse-params, the future node
view) also call `set()`; subscribers re-read via `refresh_mirrors()` /
`version`. The gen screen is itself a subscriber (round-trip safe).

Serialization is MOJO-libs json (JSONValue), never string concatenation.
"""

from json.parser import loads
from json.serialize import dumps
from json.value import JSONValue


comptime GENPARAMS_SCHEMA = "serenity.genparams.v1"


struct GenLora(Copyable, Movable):
    """One LoRA overlay row: bare name (daemon resolves against its scan dir)
    + strength weight."""

    var name: String
    var weight: Float64

    def __init__(out self, name: String, weight: Float64):
        self.name = name.copy()
        self.weight = weight


struct GenParams(Copyable, Movable):
    """The whole generation request. Canonical JSON = serenity.genparams.v1."""

    var model: String
    var prompt: String            # the RESOLVED prompt (what the backend sees)
    var prompt_raw: String        # P9/P10: original prompt WITH syntax ("" =
                                  # prompt had no syntax / is itself raw)
    var negative: String
    var width: Int
    var height: Int
    var frames: Int               # video frame count; 1 for still-image requests
    var fps: Float64              # video playback rate
    var include_audio: Bool       # decode and mux generated audio for video
    var steps: Int
    var seed: Int                 # concrete seed; -1 = randomize at submit
    var cfg: Float64
    var sampler: String
    var scheduler: String
    var variation_seed: Int       # P5: UI+genparams plumbing (backend may ignore)
    var variation_strength: Float64
    var images: Int               # P6: images-count
    var init_image: String        # P7: img2img init image path ("" = txt2img)
    var mask_image: String        # inpaint: mask PNG path ("" = no mask)
    var mask_channel: String      # inpaint: which channel is the mask
                                  # (serializes under key "lanpaint_mask_channel")
    var creativity: Float64       # P7: 0..1 — denoise start sigma fraction
    var hires_scale: Float64      # hires-fix: >1.0 enables the 2-pass refine
    var hires_denoise: Float64    # hires-fix: refine-pass creativity 0..1
    # ── advanced-sampling knobs (_section_advanced). Plumbed end-to-end; the
    #    worker HONORS what it can and warns-loud on the rest. "Unset" sentinels:
    #    clip_skip 0 / eta+sigma -1.0 / restart_sampling False / vae "". ──
    var clip_skip: Int
    var eta: Float64
    var sigma_min: Float64
    var sigma_max: Float64
    var restart_sampling: Bool
    var vae: String
    var caps_positive: String     # precomputed positive conditioning artifact
    var caps_negative: String     # precomputed negative conditioning artifact
    var loras: List[GenLora]

    def __init__(out self):
        self.model = String("")
        self.prompt = String("")
        self.prompt_raw = String("")
        self.negative = String("")
        self.width = 512
        self.height = 512
        self.frames = 1
        self.fps = 24.0
        self.include_audio = False
        self.steps = 20
        self.seed = 0
        self.cfg = 4.5
        self.sampler = String("euler")
        self.scheduler = String("simple")
        self.variation_seed = 0
        self.variation_strength = 0.0
        self.images = 1
        self.init_image = String("")
        self.mask_image = String("")
        self.mask_channel = String("load_image_mask")
        self.creativity = 0.5
        self.hires_scale = 1.0
        self.hires_denoise = 0.4
        self.clip_skip = 0
        self.eta = -1.0
        self.sigma_min = -1.0
        self.sigma_max = -1.0
        self.restart_sampling = False
        self.vae = String("")
        self.caps_positive = String("")
        self.caps_negative = String("")
        self.loras = List[GenLora]()

    def same_as(self, other: GenParams) -> Bool:
        if (
            self.model != other.model
            or self.prompt != other.prompt
            or self.prompt_raw != other.prompt_raw
            or self.negative != other.negative
            or self.width != other.width
            or self.height != other.height
            or self.frames != other.frames
            or self.fps != other.fps
            or self.include_audio != other.include_audio
            or self.steps != other.steps
            or self.seed != other.seed
            or self.cfg != other.cfg
            or self.sampler != other.sampler
            or self.scheduler != other.scheduler
            or self.variation_seed != other.variation_seed
            or self.variation_strength != other.variation_strength
            or self.images != other.images
            or self.init_image != other.init_image
            or self.mask_image != other.mask_image
            or self.mask_channel != other.mask_channel
            or self.creativity != other.creativity
            or self.hires_scale != other.hires_scale
            or self.hires_denoise != other.hires_denoise
            or self.clip_skip != other.clip_skip
            or self.eta != other.eta
            or self.sigma_min != other.sigma_min
            or self.sigma_max != other.sigma_max
            or self.restart_sampling != other.restart_sampling
            or self.vae != other.vae
            or self.caps_positive != other.caps_positive
            or self.caps_negative != other.caps_negative
        ):
            return False
        if len(self.loras) != len(other.loras):
            return False
        for i in range(len(self.loras)):
            if self.loras[i].name != other.loras[i].name:
                return False
            if self.loras[i].weight != other.loras[i].weight:
                return False
        return True

    def to_json(self) raises -> String:
        """Canonical serenity.genparams.v1 (key order mirrors the daemon's
        params_json so the G2f diff is server-added job_id only)."""
        var o = JSONValue.new_object()
        o.set("schema", JSONValue.from_string(String(GENPARAMS_SCHEMA)))
        o.set("model", JSONValue.from_string(self.model))
        o.set("prompt", JSONValue.from_string(self.prompt))
        o.set("prompt_raw", JSONValue.from_string(self.prompt_raw))
        o.set("negative", JSONValue.from_string(self.negative))
        o.set("width", JSONValue.from_int(self.width))
        o.set("height", JSONValue.from_int(self.height))
        o.set("frames", JSONValue.from_int(self.frames))
        o.set("fps", JSONValue.from_float(self.fps))
        o.set("include_audio", JSONValue.from_bool(self.include_audio))
        o.set("steps", JSONValue.from_int(self.steps))
        o.set("seed", JSONValue.from_int(self.seed))
        o.set("cfg", JSONValue.from_float(self.cfg))
        o.set("sampler", JSONValue.from_string(self.sampler))
        o.set("scheduler", JSONValue.from_string(self.scheduler))
        o.set("variation_seed", JSONValue.from_int(self.variation_seed))
        o.set("variation_strength", JSONValue.from_float(self.variation_strength))
        o.set("images", JSONValue.from_int(self.images))
        o.set("init_image", JSONValue.from_string(self.init_image))
        o.set("mask_image", JSONValue.from_string(self.mask_image))
        o.set("lanpaint_mask_channel", JSONValue.from_string(self.mask_channel))
        o.set("creativity", JSONValue.from_float(self.creativity))
        o.set("hires_scale", JSONValue.from_float(self.hires_scale))
        o.set("hires_denoise", JSONValue.from_float(self.hires_denoise))
        o.set("clip_skip", JSONValue.from_int(self.clip_skip))
        o.set("eta", JSONValue.from_float(self.eta))
        o.set("sigma_min", JSONValue.from_float(self.sigma_min))
        o.set("sigma_max", JSONValue.from_float(self.sigma_max))
        o.set("restart_sampling", JSONValue.from_bool(self.restart_sampling))
        o.set("vae", JSONValue.from_string(self.vae))
        o.set("caps_positive", JSONValue.from_string(self.caps_positive))
        o.set("caps_negative", JSONValue.from_string(self.caps_negative))
        var la = JSONValue.new_array()
        for i in range(len(self.loras)):
            var lo = JSONValue.new_object()
            lo.set("name", JSONValue.from_string(self.loras[i].name))
            lo.set("weight", JSONValue.from_float(self.loras[i].weight))
            la.append(lo^)
        o.set("lora", la^)
        return dumps(o)

    @staticmethod
    def _num(obj: JSONValue, key: String, dflt: Float64) raises -> Float64:
        if not obj.contains(key) or not obj[key].is_number():
            return dflt
        return obj[key].as_float()

    @staticmethod
    def _int(obj: JSONValue, key: String, dflt: Int) raises -> Int:
        if not obj.contains(key) or not obj[key].is_int():
            return dflt
        return obj[key].as_int()

    @staticmethod
    def _str(obj: JSONValue, key: String, dflt: String) raises -> String:
        if not obj.contains(key) or not obj[key].is_string():
            return dflt.copy()
        return obj[key].as_string()

    @staticmethod
    def _bool(obj: JSONValue, key: String, dflt: Bool) raises -> Bool:
        if not obj.contains(key) or not obj[key].is_bool():
            return dflt
        return obj[key].as_bool()

    @staticmethod
    def from_json(text: String) raises -> GenParams:
        """Parse a serenity.genparams.v1 document (tolerant of extra fields
        such as the server-added job_id; missing fields keep defaults)."""
        var obj = loads(text)
        if not obj.is_object():
            raise Error("genparams: body must be a JSON object")
        var p = GenParams()
        p.model = GenParams._str(obj, String("model"), p.model)
        p.prompt = GenParams._str(obj, String("prompt"), p.prompt)
        p.prompt_raw = GenParams._str(obj, String("prompt_raw"), p.prompt_raw)
        p.negative = GenParams._str(obj, String("negative"), p.negative)
        p.width = GenParams._int(obj, String("width"), p.width)
        p.height = GenParams._int(obj, String("height"), p.height)
        p.frames = GenParams._int(obj, String("frames"), p.frames)
        p.fps = GenParams._num(obj, String("fps"), p.fps)
        p.include_audio = GenParams._bool(
            obj, String("include_audio"), p.include_audio
        )
        p.steps = GenParams._int(obj, String("steps"), p.steps)
        p.seed = GenParams._int(obj, String("seed"), p.seed)
        p.cfg = GenParams._num(obj, String("cfg"), p.cfg)
        p.sampler = GenParams._str(obj, String("sampler"), p.sampler)
        p.scheduler = GenParams._str(obj, String("scheduler"), p.scheduler)
        p.variation_seed = GenParams._int(obj, String("variation_seed"), p.variation_seed)
        p.variation_strength = GenParams._num(
            obj, String("variation_strength"), p.variation_strength
        )
        p.images = GenParams._int(obj, String("images"), p.images)
        p.init_image = GenParams._str(obj, String("init_image"), p.init_image)
        p.mask_image = GenParams._str(obj, String("mask_image"), p.mask_image)
        p.mask_channel = GenParams._str(
            obj, String("lanpaint_mask_channel"), p.mask_channel
        )
        p.creativity = GenParams._num(obj, String("creativity"), p.creativity)
        p.hires_scale = GenParams._num(obj, String("hires_scale"), p.hires_scale)
        p.hires_denoise = GenParams._num(obj, String("hires_denoise"), p.hires_denoise)
        p.clip_skip = GenParams._int(obj, String("clip_skip"), p.clip_skip)
        p.eta = GenParams._num(obj, String("eta"), p.eta)
        p.sigma_min = GenParams._num(obj, String("sigma_min"), p.sigma_min)
        p.sigma_max = GenParams._num(obj, String("sigma_max"), p.sigma_max)
        p.restart_sampling = GenParams._bool(
            obj, String("restart_sampling"), p.restart_sampling
        )
        p.vae = GenParams._str(obj, String("vae"), p.vae)
        p.caps_positive = GenParams._str(
            obj, String("caps_positive"), p.caps_positive
        )
        p.caps_negative = GenParams._str(
            obj, String("caps_negative"), p.caps_negative
        )
        if obj.contains(String("lora")) and obj[String("lora")].is_array():
            var arr = obj[String("lora")]
            for i in range(arr.length()):
                var ent = arr[i]
                if not ent.is_object():
                    continue
                if not ent.contains(String("name")) or not ent[String("name")].is_string():
                    continue
                var w = GenParams._num(ent, String("weight"), 1.0)
                p.loras.append(GenLora(ent[String("name")].as_string(), w))
        return p^

    @staticmethod
    def _chk(
        obj: JSONValue, key: String, want_int: Bool, want_num: Bool,
        want_str: Bool, mut ignored: List[String],
    ) raises -> Bool:
        """True iff `key` is present AND correctly typed. Present-but-wrong
        typed keys are recorded in `ignored` (F8: never silently default)."""
        if not obj.contains(key):
            return False
        var v = obj[key]
        if want_int and v.is_int():
            return True
        if want_num and v.is_number():
            return True
        if want_str and v.is_string():
            return True
        ignored.append(key.copy())
        return False

    @staticmethod
    def _chk_bool(
        obj: JSONValue, key: String, mut ignored: List[String],
    ) raises -> Bool:
        """True iff `key` is present AND a bool. Present-but-wrong-typed keys
        are recorded in `ignored` (F8: never silently default)."""
        if not obj.contains(key):
            return False
        if obj[key].is_bool():
            return True
        ignored.append(key.copy())
        return False

    @staticmethod
    def from_json_validated(
        text: String, base: GenParams, mut ignored: List[String],
    ) raises -> GenParams:
        """F8 preset load: start from `base` (the CURRENT params) and apply
        only present, correctly-typed fields. Wrong-typed fields keep the
        current value and land in `ignored` so the screen can report
        "preset field 'x' ignored (wrong type)"."""
        var obj = loads(text)
        if not obj.is_object():
            raise Error("genparams: body must be a JSON object")
        var p = base.copy()
        if GenParams._chk(obj, String("model"), False, False, True, ignored):
            p.model = obj[String("model")].as_string()
        if GenParams._chk(obj, String("prompt"), False, False, True, ignored):
            p.prompt = obj[String("prompt")].as_string()
        if GenParams._chk(obj, String("prompt_raw"), False, False, True, ignored):
            p.prompt_raw = obj[String("prompt_raw")].as_string()
        if GenParams._chk(obj, String("negative"), False, False, True, ignored):
            p.negative = obj[String("negative")].as_string()
        if GenParams._chk(obj, String("width"), True, False, False, ignored):
            p.width = obj[String("width")].as_int()
        if GenParams._chk(obj, String("height"), True, False, False, ignored):
            p.height = obj[String("height")].as_int()
        if GenParams._chk(obj, String("frames"), True, False, False, ignored):
            p.frames = obj[String("frames")].as_int()
        if GenParams._chk(obj, String("fps"), False, True, False, ignored):
            p.fps = obj[String("fps")].as_float()
        if GenParams._chk_bool(obj, String("include_audio"), ignored):
            p.include_audio = obj[String("include_audio")].as_bool()
        if GenParams._chk(obj, String("steps"), True, False, False, ignored):
            p.steps = obj[String("steps")].as_int()
        if GenParams._chk(obj, String("seed"), True, False, False, ignored):
            p.seed = obj[String("seed")].as_int()
        if GenParams._chk(obj, String("cfg"), False, True, False, ignored):
            p.cfg = obj[String("cfg")].as_float()
        if GenParams._chk(obj, String("sampler"), False, False, True, ignored):
            p.sampler = obj[String("sampler")].as_string()
        if GenParams._chk(obj, String("scheduler"), False, False, True, ignored):
            p.scheduler = obj[String("scheduler")].as_string()
        if GenParams._chk(obj, String("variation_seed"), True, False, False, ignored):
            p.variation_seed = obj[String("variation_seed")].as_int()
        if GenParams._chk(obj, String("variation_strength"), False, True, False, ignored):
            p.variation_strength = obj[String("variation_strength")].as_float()
        if GenParams._chk(obj, String("images"), True, False, False, ignored):
            p.images = obj[String("images")].as_int()
        if GenParams._chk(obj, String("init_image"), False, False, True, ignored):
            p.init_image = obj[String("init_image")].as_string()
        if GenParams._chk(obj, String("mask_image"), False, False, True, ignored):
            p.mask_image = obj[String("mask_image")].as_string()
        if GenParams._chk(
            obj, String("lanpaint_mask_channel"), False, False, True, ignored
        ):
            p.mask_channel = obj[String("lanpaint_mask_channel")].as_string()
        if GenParams._chk(obj, String("creativity"), False, True, False, ignored):
            p.creativity = obj[String("creativity")].as_float()
        if GenParams._chk(obj, String("hires_scale"), False, True, False, ignored):
            p.hires_scale = obj[String("hires_scale")].as_float()
        if GenParams._chk(obj, String("hires_denoise"), False, True, False, ignored):
            p.hires_denoise = obj[String("hires_denoise")].as_float()
        if GenParams._chk(obj, String("clip_skip"), True, False, False, ignored):
            p.clip_skip = obj[String("clip_skip")].as_int()
        if GenParams._chk(obj, String("eta"), False, True, False, ignored):
            p.eta = obj[String("eta")].as_float()
        if GenParams._chk(obj, String("sigma_min"), False, True, False, ignored):
            p.sigma_min = obj[String("sigma_min")].as_float()
        if GenParams._chk(obj, String("sigma_max"), False, True, False, ignored):
            p.sigma_max = obj[String("sigma_max")].as_float()
        if GenParams._chk_bool(obj, String("restart_sampling"), ignored):
            p.restart_sampling = obj[String("restart_sampling")].as_bool()
        if GenParams._chk(obj, String("vae"), False, False, True, ignored):
            p.vae = obj[String("vae")].as_string()
        if GenParams._chk(obj, String("caps_positive"), False, False, True, ignored):
            p.caps_positive = obj[String("caps_positive")].as_string()
        if GenParams._chk(obj, String("caps_negative"), False, False, True, ignored):
            p.caps_negative = obj[String("caps_negative")].as_string()
        if obj.contains(String("lora")):
            if not obj[String("lora")].is_array():
                ignored.append(String("lora"))
            else:
                p.loras = List[GenLora]()
                var arr = obj[String("lora")]
                for i in range(arr.length()):
                    var ent = arr[i]
                    if not ent.is_object() or not ent.contains(String("name")) \
                            or not ent[String("name")].is_string():
                        ignored.append(String("lora[") + String(i) + String("]"))
                        continue
                    var w = GenParams._num(ent, String("weight"), 1.0)
                    p.loras.append(GenLora(ent[String("name")].as_string(), w))
        return p^


def _find_option(options: List[String], name: String) -> Int32:
    for i in range(len(options)):
        if options[i] == name:
            return Int32(i)
    return Int32(-1)


def _round2(v: Float64) -> Float64:
    """Round to 2 decimals — kills Float32 widget-mirror noise on COMMIT
    (3.7000000476837158 -> 3.7) without touching externally-set values."""
    if v >= 0.0:
        return Float64(Int(v * 100.0 + 0.5)) / 100.0
    return Float64(Int(v * 100.0 - 0.5)) / 100.0


def _parse_seed_text(text: String, fallback: Int) -> Int:
    """Parse the seed TEXT mirror as a signed integer (whole Int range —
    no Float32 truncation). Anything unparsable keeps the old seed."""
    var b = text.as_bytes()
    var n = text.byte_length()
    var i = 0
    while i < n and (b[i] == 32 or b[i] == 9):
        i += 1
    var neg = False
    if i < n and (b[i] == 45 or b[i] == 43):  # '-' / '+'
        neg = b[i] == 45
        i += 1
    var got = False
    var acc = 0
    while i < n:
        var c = Int(b[i])
        if c < 48 or c > 57:
            break
        acc = acc * 10 + (c - 48)
        got = True
        i += 1
    while i < n and (b[i] == 32 or b[i] == 9):
        i += 1
    if not got or i != n:
        return fallback
    return -acc if neg else acc


struct GenParamStore(Movable):
    """H1 source of truth + H2 observer seam.

    `params` is canonical; `version` bumps on every `set()` (THE single
    dispatch point). The m_* fields are the widget edit mirrors — the gen
    screen's subscriber view. Other subscribers (the future node view) watch
    `version` and re-read `params`.
    """

    var params: GenParams         # H1: the one param state
    var version: UInt64           # bumped only inside set()
    var last_set_json: String     # audit trail: canonical JSON of last set()
    var _seen_version: UInt64     # mirror-subscriber's last-synced version

    # ── widget edit mirrors (immediate-mode bindings) ──
    # Seed is a TEXT mirror (m_seed_text): the drag widget is Float32-only
    # and Float32 cannot represent seeds > 2^24 (123456789 -> 123456792).
    # cfg / variation_strength / lora weights stay Float32 for the widgets
    # but are committed through Float64 round-to-2-decimals (see _round2).
    var m_prompt: String
    var m_negative: String
    var m_width: Float32
    var m_height: Float32
    var m_frames: Float32
    var m_fps: Float32
    var m_include_audio: Bool
    var m_steps: Float32
    var m_cfg: Float32
    var m_seed_text: String            # integer-typed end-to-end (F1)
    var m_variation_seed: Float32
    var m_variation_strength: Float32
    var m_images: Float32
    var m_init_image: String           # P7: init image path (text mirror)
    var m_mask_image: String           # inpaint: mask PNG path (text mirror)
    var m_mask_channel: String         # inpaint: channel enum string mirror
    var m_creativity: Float32          # P7: 0..1 slider mirror
    var m_hires_scale: Float32         # hires-fix: 1..2 scale slider mirror
    var m_hires_denoise: Float32       # hires-fix: 0..1 denoise slider mirror
    # advanced-sampling mirrors (_section_advanced)
    var m_clip_skip: Float32           # drag mirror; committed as Int
    var m_eta: Float32
    var m_sigma_min: Float32
    var m_sigma_max: Float32
    var m_restart_sampling: Bool       # checkbox mirror
    var m_vae: String                  # VAE name string mirror
    var m_caps_positive: String
    var m_caps_negative: String
    var m_model_index: Int32      # into the screen's model-name list
    var m_sampler_index: Int32
    var m_scheduler_index: Int32
    var m_lora_indices: List[Int32]    # per-row index into lora options
    var m_lora_weights: List[Float32]  # per-row weight 0..2

    # ── per-field DIRTY flags (F2): commit_mirrors only set()s fields the
    # user actually edited; refreshed mirror values are NEVER re-committed
    # (a refresh through Float32 must not corrupt externally-set params). ──
    var d_model: Bool
    var d_prompt: Bool
    var d_negative: Bool
    var d_width: Bool
    var d_height: Bool
    var d_frames: Bool
    var d_fps: Bool
    var d_include_audio: Bool
    var d_steps: Bool
    var d_cfg: Bool
    var d_seed: Bool
    var d_sampler: Bool
    var d_scheduler: Bool
    var d_variation_seed: Bool
    var d_variation_strength: Bool
    var d_images: Bool
    var d_init_image: Bool
    var d_mask_image: Bool
    var d_mask_channel: Bool
    var d_creativity: Bool
    var d_hires_scale: Bool
    var d_hires_denoise: Bool
    var d_clip_skip: Bool
    var d_eta: Bool
    var d_sigma_min: Bool
    var d_sigma_max: Bool
    var d_restart_sampling: Bool
    var d_vae: Bool
    var d_caps_positive: Bool
    var d_caps_negative: Bool
    var d_loras: Bool

    def __init__(out self):
        self.params = GenParams()
        self.version = 0
        self.last_set_json = String("")
        self._seen_version = 0
        self.m_prompt = String("")
        self.m_negative = String("")
        self.m_width = 512.0
        self.m_height = 512.0
        self.m_frames = 1.0
        self.m_fps = 24.0
        self.m_include_audio = False
        self.m_steps = 20.0
        self.m_cfg = 4.5
        self.m_seed_text = String("0")
        self.m_variation_seed = 0.0
        self.m_variation_strength = 0.0
        self.m_images = 1.0
        self.m_init_image = String("")
        self.m_mask_image = String("")
        self.m_mask_channel = String("load_image_mask")
        self.m_creativity = 0.5
        self.m_hires_scale = 1.0
        self.m_hires_denoise = 0.4
        self.m_clip_skip = 0.0
        self.m_eta = -1.0
        self.m_sigma_min = -1.0
        self.m_sigma_max = -1.0
        self.m_restart_sampling = False
        self.m_vae = String("")
        self.m_caps_positive = String("")
        self.m_caps_negative = String("")
        self.m_model_index = 0
        self.m_sampler_index = 0
        self.m_scheduler_index = 0
        self.m_lora_indices = List[Int32]()
        self.m_lora_weights = List[Float32]()
        self.d_model = False
        self.d_prompt = False
        self.d_negative = False
        self.d_width = False
        self.d_height = False
        self.d_frames = False
        self.d_fps = False
        self.d_include_audio = False
        self.d_steps = False
        self.d_cfg = False
        self.d_seed = False
        self.d_sampler = False
        self.d_scheduler = False
        self.d_variation_seed = False
        self.d_variation_strength = False
        self.d_images = False
        self.d_init_image = False
        self.d_mask_image = False
        self.d_mask_channel = False
        self.d_creativity = False
        self.d_hires_scale = False
        self.d_hires_denoise = False
        self.d_clip_skip = False
        self.d_eta = False
        self.d_sigma_min = False
        self.d_sigma_max = False
        self.d_restart_sampling = False
        self.d_vae = False
        self.d_caps_positive = False
        self.d_caps_negative = False
        self.d_loras = False

    def clear_dirty(mut self):
        self.d_model = False
        self.d_prompt = False
        self.d_negative = False
        self.d_width = False
        self.d_height = False
        self.d_frames = False
        self.d_fps = False
        self.d_include_audio = False
        self.d_steps = False
        self.d_cfg = False
        self.d_seed = False
        self.d_sampler = False
        self.d_scheduler = False
        self.d_variation_seed = False
        self.d_variation_strength = False
        self.d_images = False
        self.d_init_image = False
        self.d_mask_image = False
        self.d_mask_channel = False
        self.d_creativity = False
        self.d_hires_scale = False
        self.d_hires_denoise = False
        self.d_clip_skip = False
        self.d_eta = False
        self.d_sigma_min = False
        self.d_sigma_max = False
        self.d_restart_sampling = False
        self.d_vae = False
        self.d_caps_positive = False
        self.d_caps_negative = False
        self.d_loras = False

    def any_dirty(self) -> Bool:
        return (
            self.d_model or self.d_prompt or self.d_negative or self.d_width
            or self.d_height or self.d_frames or self.d_fps
            or self.d_include_audio
            or self.d_steps or self.d_cfg or self.d_seed
            or self.d_sampler or self.d_scheduler or self.d_variation_seed
            or self.d_variation_strength or self.d_images
            or self.d_init_image or self.d_mask_image or self.d_mask_channel
            or self.d_creativity
            or self.d_hires_scale or self.d_hires_denoise
            or self.d_clip_skip or self.d_eta or self.d_sigma_min
            or self.d_sigma_max or self.d_restart_sampling or self.d_vae
            or self.d_caps_positive or self.d_caps_negative
            or self.d_loras
        )

    # ── H2: THE single dispatch point. Every param edit lands here. ──
    def set(mut self, var p: GenParams) raises:
        self.params = p^
        self.version += 1
        self.last_set_json = self.params.to_json()

    def _name_at(self, options: List[String], idx: Int32) -> String:
        var i = Int(idx)
        if i < 0 or i >= len(options):
            return String("")
        return options[i].copy()

    def commit_mirrors(
        mut self,
        model_names: List[String],
        sampler_names: List[String],
        scheduler_names: List[String],
        lora_names: List[String],
    ) raises -> Bool:
        """Apply the DIRTY widget mirrors onto a copy of `params`; when it
        differs, route it through set() (the H2 dispatch). Non-dirty fields
        are NEVER rebuilt from the mirrors — a refresh()ed value that lost
        precision in a Float32 mirror cannot corrupt the canonical params
        (F1/F2). Returns True iff a notify happened. Called once per frame
        by the gen screen; the screen sets d_* when a widget reports an
        edit and this clears them after the commit."""
        if self._seen_version != self.version:
            # The mirrors are STALE: an external set() (preset load,
            # reuse-params, node view) landed since the last refresh. A
            # subscriber must re-read before it may write — otherwise the
            # end-of-frame commit silently reverts the external change.
            # Edits from this frame are dropped (refresh wins).
            self.clear_dirty()
            return False
        if not self.any_dirty():
            return False
        var p = self.params.copy()
        if self.d_model:
            p.model = self._name_at(model_names, self.m_model_index)
        if self.d_prompt:
            # A user edit makes the prompt RAW again: the resolved/raw split
            # is recomputed at submit (P9/P10).
            p.prompt = self.m_prompt.copy()
            p.prompt_raw = String("")
        if self.d_negative:
            p.negative = self.m_negative.copy()
        if self.d_width:
            p.width = Int(self.m_width)
        if self.d_height:
            p.height = Int(self.m_height)
        if self.d_frames:
            p.frames = Int(self.m_frames) if Int(self.m_frames) >= 1 else 1
        if self.d_fps:
            p.fps = _round2(Float64(self.m_fps))
        if self.d_include_audio:
            p.include_audio = self.m_include_audio
        if self.d_steps:
            p.steps = Int(self.m_steps) if Int(self.m_steps) >= 1 else 1
        if self.d_cfg:
            p.cfg = _round2(Float64(self.m_cfg))
        if self.d_seed:
            p.seed = _parse_seed_text(self.m_seed_text, p.seed)
        if self.d_sampler:
            p.sampler = self._name_at(sampler_names, self.m_sampler_index)
        if self.d_scheduler:
            p.scheduler = self._name_at(scheduler_names, self.m_scheduler_index)
        if self.d_variation_seed:
            p.variation_seed = Int(self.m_variation_seed)
        if self.d_variation_strength:
            p.variation_strength = _round2(Float64(self.m_variation_strength))
        if self.d_images:
            p.images = Int(self.m_images) if Int(self.m_images) >= 1 else 1
        if self.d_init_image:
            p.init_image = self.m_init_image.copy()
        if self.d_mask_image:
            p.mask_image = self.m_mask_image.copy()
        if self.d_mask_channel:
            p.mask_channel = self.m_mask_channel.copy()
        if self.d_creativity:
            var c = _round2(Float64(self.m_creativity))
            if c < 0.0:
                c = 0.0
            if c > 1.0:
                c = 1.0
            p.creativity = c
        if self.d_hires_scale:
            var hs = _round2(Float64(self.m_hires_scale))
            if hs < 1.0:
                hs = 1.0
            if hs > 2.0:
                hs = 2.0
            p.hires_scale = hs
        if self.d_hires_denoise:
            var hd = _round2(Float64(self.m_hires_denoise))
            if hd < 0.0:
                hd = 0.0
            if hd > 1.0:
                hd = 1.0
            p.hires_denoise = hd
        if self.d_clip_skip:
            var cs = Int(self.m_clip_skip)
            if cs < 0:
                cs = 0
            p.clip_skip = cs
        if self.d_eta:
            p.eta = _round2(Float64(self.m_eta))
        if self.d_sigma_min:
            p.sigma_min = _round2(Float64(self.m_sigma_min))
        if self.d_sigma_max:
            p.sigma_max = _round2(Float64(self.m_sigma_max))
        if self.d_restart_sampling:
            p.restart_sampling = self.m_restart_sampling
        if self.d_vae:
            p.vae = self.m_vae.copy()
        if self.d_caps_positive:
            p.caps_positive = self.m_caps_positive.copy()
        if self.d_caps_negative:
            p.caps_negative = self.m_caps_negative.copy()
        if self.d_loras:
            p.loras = List[GenLora]()
            for i in range(len(self.m_lora_indices)):
                var name = self._name_at(lora_names, self.m_lora_indices[i])
                if name == String(""):
                    continue
                p.loras.append(
                    GenLora(name^, _round2(Float64(self.m_lora_weights[i])))
                )
        self.clear_dirty()
        if p.same_as(self.params):
            return False
        self.set(p^)
        self._seen_version = self.version  # the screen already shows it
        return True

    def refresh_mirrors(
        mut self,
        model_names: List[String],
        sampler_names: List[String],
        scheduler_names: List[String],
        mut lora_names: List[String],
    ) -> Bool:
        """Subscriber re-read: when `params` changed through set() from
        OUTSIDE the mirror commit (preset load, PNG reuse-params, node view),
        rebuild the widget mirrors from the canonical struct. LoRA names not
        present in the screen's options are appended so the rows render.
        Returns True iff a refresh happened (the screen then re-seeds its
        text-edit engines)."""
        if self._seen_version == self.version:
            return False
        # P9/P10: the prompt EDITOR shows the raw (with-syntax) prompt when
        # one exists — the canonical `prompt` holds the resolved text.
        if self.params.prompt_raw.byte_length() > 0:
            self.m_prompt = self.params.prompt_raw.copy()
        else:
            self.m_prompt = self.params.prompt.copy()
        self.m_negative = self.params.negative.copy()
        self.m_width = Float32(self.params.width)
        self.m_height = Float32(self.params.height)
        self.m_frames = Float32(self.params.frames)
        self.m_fps = Float32(self.params.fps)
        self.m_include_audio = self.params.include_audio
        self.m_steps = Float32(self.params.steps)
        self.m_cfg = Float32(self.params.cfg)
        self.m_seed_text = String(self.params.seed)
        self.m_variation_seed = Float32(self.params.variation_seed)
        self.m_variation_strength = Float32(self.params.variation_strength)
        self.m_images = Float32(self.params.images)
        self.m_init_image = self.params.init_image.copy()
        self.m_mask_image = self.params.mask_image.copy()
        self.m_mask_channel = self.params.mask_channel.copy()
        self.m_creativity = Float32(self.params.creativity)
        self.m_hires_scale = Float32(self.params.hires_scale)
        self.m_hires_denoise = Float32(self.params.hires_denoise)
        self.m_clip_skip = Float32(self.params.clip_skip)
        self.m_eta = Float32(self.params.eta)
        self.m_sigma_min = Float32(self.params.sigma_min)
        self.m_sigma_max = Float32(self.params.sigma_max)
        self.m_restart_sampling = self.params.restart_sampling
        self.m_vae = self.params.vae.copy()
        self.m_caps_positive = self.params.caps_positive.copy()
        self.m_caps_negative = self.params.caps_negative.copy()
        var mi = _find_option(model_names, self.params.model)
        if mi >= 0:
            self.m_model_index = mi
        var si = _find_option(sampler_names, self.params.sampler)
        if si >= 0:
            self.m_sampler_index = si
        var ci = _find_option(scheduler_names, self.params.scheduler)
        if ci >= 0:
            self.m_scheduler_index = ci
        self.m_lora_indices = List[Int32]()
        self.m_lora_weights = List[Float32]()
        for i in range(len(self.params.loras)):
            var li = _find_option(lora_names, self.params.loras[i].name)
            if li < 0:
                lora_names.append(self.params.loras[i].name.copy())
                li = Int32(len(lora_names) - 1)
            self.m_lora_indices.append(li)
            self.m_lora_weights.append(Float32(self.params.loras[i].weight))
        self._seen_version = self.version
        # A refresh re-seeds the mirrors: nothing is user-edited anymore.
        self.clear_dirty()
        return True
