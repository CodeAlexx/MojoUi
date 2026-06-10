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
        if GenParams._chk(obj, String("negative"), False, False, True, ignored):
            p.negative = obj[String("negative")].as_string()
        if GenParams._chk(obj, String("width"), True, False, False, ignored):
            p.width = obj[String("width")].as_int()
        if GenParams._chk(obj, String("height"), True, False, False, ignored):
            p.height = obj[String("height")].as_int()
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
    var m_steps: Float32
    var m_cfg: Float32
    var m_seed_text: String            # integer-typed end-to-end (F1)
    var m_variation_seed: Float32
    var m_variation_strength: Float32
    var m_images: Float32
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
    var d_steps: Bool
    var d_cfg: Bool
    var d_seed: Bool
    var d_sampler: Bool
    var d_scheduler: Bool
    var d_variation_seed: Bool
    var d_variation_strength: Bool
    var d_images: Bool
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
        self.m_steps = 20.0
        self.m_cfg = 4.5
        self.m_seed_text = String("0")
        self.m_variation_seed = 0.0
        self.m_variation_strength = 0.0
        self.m_images = 1.0
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
        self.d_steps = False
        self.d_cfg = False
        self.d_seed = False
        self.d_sampler = False
        self.d_scheduler = False
        self.d_variation_seed = False
        self.d_variation_strength = False
        self.d_images = False
        self.d_loras = False

    def clear_dirty(mut self):
        self.d_model = False
        self.d_prompt = False
        self.d_negative = False
        self.d_width = False
        self.d_height = False
        self.d_steps = False
        self.d_cfg = False
        self.d_seed = False
        self.d_sampler = False
        self.d_scheduler = False
        self.d_variation_seed = False
        self.d_variation_strength = False
        self.d_images = False
        self.d_loras = False

    def any_dirty(self) -> Bool:
        return (
            self.d_model or self.d_prompt or self.d_negative or self.d_width
            or self.d_height or self.d_steps or self.d_cfg or self.d_seed
            or self.d_sampler or self.d_scheduler or self.d_variation_seed
            or self.d_variation_strength or self.d_images or self.d_loras
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
            p.prompt = self.m_prompt.copy()
        if self.d_negative:
            p.negative = self.m_negative.copy()
        if self.d_width:
            p.width = Int(self.m_width)
        if self.d_height:
            p.height = Int(self.m_height)
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
        self.m_prompt = self.params.prompt.copy()
        self.m_negative = self.params.negative.copy()
        self.m_width = Float32(self.params.width)
        self.m_height = Float32(self.params.height)
        self.m_steps = Float32(self.params.steps)
        self.m_cfg = Float32(self.params.cfg)
        self.m_seed_text = String(self.params.seed)
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
        # A refresh re-seeds the mirrors: nothing is user-edited anymore.
        self.clear_dirty()
        return True
