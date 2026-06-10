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
    var prompt: String
    var negative: String
    var width: Int
    var height: Int
    var steps: Int
    var seed: Int                 # concrete seed; -1 = randomize at submit
    var cfg: Float64
    var sampler: String
    var scheduler: String
    var variation_seed: Int       # P5: UI+genparams plumbing (backend may ignore)
    var variation_strength: Float64
    var images: Int               # P6: images-count
    var loras: List[GenLora]

    def __init__(out self):
        self.model = String("")
        self.prompt = String("")
        self.negative = String("")
        self.width = 512
        self.height = 512
        self.steps = 20
        self.seed = 0
        self.cfg = 4.5
        self.sampler = String("euler")
        self.scheduler = String("simple")
        self.variation_seed = 0
        self.variation_strength = 0.0
        self.images = 1
        self.loras = List[GenLora]()

    def same_as(self, other: GenParams) -> Bool:
        if (
            self.model != other.model
            or self.prompt != other.prompt
            or self.negative != other.negative
            or self.width != other.width
            or self.height != other.height
            or self.steps != other.steps
            or self.seed != other.seed
            or self.cfg != other.cfg
            or self.sampler != other.sampler
            or self.scheduler != other.scheduler
            or self.variation_seed != other.variation_seed
            or self.variation_strength != other.variation_strength
            or self.images != other.images
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
        o.set("negative", JSONValue.from_string(self.negative))
        o.set("width", JSONValue.from_int(self.width))
        o.set("height", JSONValue.from_int(self.height))
        o.set("steps", JSONValue.from_int(self.steps))
        o.set("seed", JSONValue.from_int(self.seed))
        o.set("cfg", JSONValue.from_float(self.cfg))
        o.set("sampler", JSONValue.from_string(self.sampler))
        o.set("scheduler", JSONValue.from_string(self.scheduler))
        o.set("variation_seed", JSONValue.from_int(self.variation_seed))
        o.set("variation_strength", JSONValue.from_float(self.variation_strength))
        o.set("images", JSONValue.from_int(self.images))
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
    def from_json(text: String) raises -> GenParams:
        """Parse a serenity.genparams.v1 document (tolerant of extra fields
        such as the server-added job_id; missing fields keep defaults)."""
        var obj = loads(text)
        if not obj.is_object():
            raise Error("genparams: body must be a JSON object")
        var p = GenParams()
        p.model = GenParams._str(obj, String("model"), p.model)
        p.prompt = GenParams._str(obj, String("prompt"), p.prompt)
        p.negative = GenParams._str(obj, String("negative"), p.negative)
        p.width = GenParams._int(obj, String("width"), p.width)
        p.height = GenParams._int(obj, String("height"), p.height)
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


def _find_option(options: List[String], name: String) -> Int32:
    for i in range(len(options)):
        if options[i] == name:
            return Int32(i)
    return Int32(-1)


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
    var m_prompt: String
    var m_negative: String
    var m_width: Float32
    var m_height: Float32
    var m_steps: Float32
    var m_cfg: Float32
    var m_seed: Float32
    var m_variation_seed: Float32
    var m_variation_strength: Float32
    var m_images: Float32
    var m_model_index: Int32      # into the screen's model-name list
    var m_sampler_index: Int32
    var m_scheduler_index: Int32
    var m_lora_indices: List[Int32]    # per-row index into lora options
    var m_lora_weights: List[Float32]  # per-row weight 0..2

    def __init__(out self):
        self.params = GenParams()
        self.version = 0
        self.last_set_json = String("")
        self._seen_version = 0
        self.m_prompt = String("")
        self.m_negative = String("")
        self.m_width = 512.0
        self.m_height = 512.0
        self.m_steps = 20.0
        self.m_cfg = 4.5
        self.m_seed = 0.0
        self.m_variation_seed = 0.0
        self.m_variation_strength = 0.0
        self.m_images = 1.0
        self.m_model_index = 0
        self.m_sampler_index = 0
        self.m_scheduler_index = 0
        self.m_lora_indices = List[Int32]()
        self.m_lora_weights = List[Float32]()

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
        """Build a GenParams from the widget mirrors; when it differs from
        `params`, route it through set() (the H2 dispatch). Returns True iff
        a notify happened. Called once per frame by the gen screen."""
        if self._seen_version != self.version:
            # The mirrors are STALE: an external set() (preset load,
            # reuse-params, node view) landed since the last refresh. A
            # subscriber must re-read before it may write — otherwise the
            # end-of-frame commit silently reverts the external change.
            return False
        var p = GenParams()
        p.model = self._name_at(model_names, self.m_model_index)
        p.prompt = self.m_prompt.copy()
        p.negative = self.m_negative.copy()
        p.width = Int(self.m_width)
        p.height = Int(self.m_height)
        p.steps = Int(self.m_steps) if Int(self.m_steps) >= 1 else 1
        p.cfg = Float64(self.m_cfg)
        p.seed = Int(self.m_seed)
        p.sampler = self._name_at(sampler_names, self.m_sampler_index)
        p.scheduler = self._name_at(scheduler_names, self.m_scheduler_index)
        p.variation_seed = Int(self.m_variation_seed)
        p.variation_strength = Float64(self.m_variation_strength)
        p.images = Int(self.m_images) if Int(self.m_images) >= 1 else 1
        for i in range(len(self.m_lora_indices)):
            var name = self._name_at(lora_names, self.m_lora_indices[i])
            if name == String(""):
                continue
            p.loras.append(GenLora(name^, Float64(self.m_lora_weights[i])))
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
        self.m_prompt = self.params.prompt.copy()
        self.m_negative = self.params.negative.copy()
        self.m_width = Float32(self.params.width)
        self.m_height = Float32(self.params.height)
        self.m_steps = Float32(self.params.steps)
        self.m_cfg = Float32(self.params.cfg)
        self.m_seed = Float32(self.params.seed)
        self.m_variation_seed = Float32(self.params.variation_seed)
        self.m_variation_strength = Float32(self.params.variation_strength)
        self.m_images = Float32(self.params.images)
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
        return True
