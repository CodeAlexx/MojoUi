"""NodeRegistry + NodeTypeDef — the visual-data layer's type catalog.

Per `EriGui node audit notes` §"Node Registry / Type System" the registry maps
`type_id: String` (e.g. `"core/k_sampler"`) to a `NodeTypeDef` carrying the
defaults that `make_node` clones into a fresh `Node` at spawn time:

  - default input port list (name + value_type tag, direction implied)
  - default output port list
  - default parameter values keyed by field name
  - canvas display size + human-readable display name + category

**Important deviation from EriGui** (per `architecture plan` Decision 1):
EriGui represents node behavior via a `Box<dyn NodeType>` trait with an
`execute()` method. MojoUI's `NodeTypeDef` is PLAIN DATA — no execute method.
Execution is the application layer's responsibility (the diffusion runtime
walks the topo-sorted graph and dispatches per `type_id` outside the visual
layer). This keeps `mojoui/nodes/` pure-data and serializable; whatever app
embeds MojoUI joins behavior to `type_id` via its own dispatch table.

**Registry decoupling note** (per `EriGui node audit notes` §"Context Menu /
Node Spawning UX", which describes `NodeRegistryHandle` trait in EriGui):
the M2.5 registry is a concrete struct, not a trait. The canvas (c39) +
add-menu (c40) consume the typedef directly. If a future circular-dep
problem emerges between the registry and a downstream chunk, M3 may
introduce a trait surface — for M2.5 the direct reference is simpler.

The registry composes the following c33+c32 surface:

  - `Port` from c33 (`port.mojo`): full port struct with name + value_type
    (NodeValueType tag) + is_input flag — used in `default_inputs`/
    `default_outputs` lists on the typedef.
  - `PortRef` from c32 (`node.mojo`): minimal node-local port descriptor
    (name + value_type only) — what `make_node` writes into the fresh
    Node's `inputs`/`outputs` lists. The translation drops `is_input`
    because Node already separates inputs from outputs into two lists.
  - `FieldValue` from c32: parameter value carrier for `default_fields`.
  - `Node` from c32: what `make_node` returns.
  - `RetainedId` from c11: caller-supplied id allocated upstream.
  - `Vec2` from `core/types`: position + size.
  - `NodeValueType` constants from c33: used by `register_builtins` to
    seed the starter typedefs.

The starter builtins registered by `register_builtins` mirror ComfyUI-shaped
core and media nodes for parity testing:

  - `core/load_checkpoint` → outputs model/clip/vae; field `path` (string).
  - `core/encode_prompt` → input clip, output cond; field `text` (string).
  - `core/k_sampler` → inputs model/cond/uncond/latent, output latent;
    fields cfg (number), steps (int), seed (int), sampler (string).
  - `core/vae_decode` → inputs vae/latent, output image.
  - `core/load_image` → output image; field `path` (string).
  - `core/save_image` → input image; field `path` (string).
  - `core/image_to_prompt` → image to prompt text via a vision model.
  - `core/preview_text` → terminal text/JSON preview node.
  - `core/load_video` → output video; field `path` (string).
  - `core/preview_video` → input video; fields for path/autoplay/loop.
  - `core/save_video` → input video; fields for path/fps/codec.
  - `core/ideogram4_prompt_builder` → SerenityUI visual bbox prompt builder.
  - `core/ideogram4_magic_prompt` → prompt text to structured caption JSON.
  - `core/ideogram4_generate` → caption JSON to image via Ideogram4.

Apps can override or extend via `registry.register(...)` — the builtins are
a convenience starter set, not a load-bearing contract.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId
from mojoui.nodes.port import (
    Port,
    NodeValueType,
    NVT_MODEL,
    NVT_CLIP,
    NVT_VAE,
    NVT_LATENT,
    NVT_CONDITIONING,
    NVT_IMAGE,
    NVT_LORA,
    NVT_NUMBER,
    NVT_TEXT,
    NVT_SEED,
    NVT_BOOL,
    NVT_VIDEO,
    NVT_BBOX,
)
from mojoui.nodes.node import Node, PortRef, FieldValue


comptime _DEFAULT_TYPEDEF_W: Float32 = 200.0
"""Default canvas-width for a freshly-registered typedef. Override per
typedef via `with_size`."""

comptime _DEFAULT_TYPEDEF_H: Float32 = 80.0
"""Default canvas-height."""


# ============================================================================
# NodeTypeDef — data-only descriptor for a node type
# ============================================================================


struct NodeTypeDef(Copyable, Movable):
    """Data-only descriptor for a node type. Captures the defaults the
    registry stamps into a fresh `Node` on spawn (`make_node`).

    NOTE: execution is intentionally NOT part of this struct (per
    `architecture plan` Decision 1). EriGui's `Box<dyn NodeType>` has an
    `execute()` method; MojoUI's `NodeTypeDef` has only display + default
    state. Whatever app embeds MojoUI joins behavior to `type_id` via its
    own dispatch table outside the visual layer.

    Per Mojo implementation notes "Confirmed in M2.5 chunk 32" (auto-Copyable wall): no
    explicit `__copyinit__`. The compiler auto-generates a working copy
    init that respects `.copy()` on the `String`/`List[Port]`/`Dict[String,
    FieldValue]` fields and trivially copies the `Vec2` scalar fields.
    """

    var type_id: String
    """Stable identifier (`"category/name"`, e.g. `"core/k_sampler"`).
    Used as the key into the registry's `types` Dict and as the
    serialized `type_id` field on every saved Node."""

    var display_name: String
    """Human-readable label (e.g. `"K-Sampler"`). Defaults to `type_id`
    if the caller does not override; used by the add-menu (c40) for
    rendering the spawn-list entry."""

    var category: String
    """Add-menu category key (e.g. `"core"`, `"sampler"`, `"vae"`).
    Used by `by_category()` to group typedefs in the add-menu UI."""

    var default_inputs: List[Port]
    """Template input ports. `make_node` copies each into a `PortRef` on
    the fresh Node. Direction (is_input=True) is implied by list
    membership — the Node split into `inputs`/`outputs` lists makes the
    per-Port `is_input` flag redundant on the Node side, but we keep the
    full `Port` shape on the TypeDef so the canvas can render typed
    sockets directly off the typedef without a Node instance."""

    var default_outputs: List[Port]
    """Template output ports (each constructed with is_input=False)."""

    var default_fields: Dict[String, FieldValue]
    """Parameter defaults keyed by field name. `make_node` copies into
    the fresh Node's `fields` dict."""

    var default_size: Vec2
    """Default canvas display size in world units. 200×80 unless
    overridden via `with_size`."""

    def __init__(
        out self,
        type_id: String,
        display_name: String,
        category: String,
    ):
        """Construct an empty typedef. Add ports / fields / size via the
        chainable `with_*` mutators below.
        """
        self.type_id = type_id.copy()
        self.display_name = display_name.copy()
        self.category = category.copy()
        self.default_inputs = List[Port]()
        self.default_outputs = List[Port]()
        self.default_fields = Dict[String, FieldValue]()
        self.default_size = Vec2(_DEFAULT_TYPEDEF_W, _DEFAULT_TYPEDEF_H)

    def with_input(mut self, port_name: String, value_type: NodeValueType):
        """Append an input port to `default_inputs`. The is_input flag is
        set True automatically. Returns void (caller composes in
        sequence; no fluent return value in current beta)."""
        self.default_inputs.append(Port(port_name, value_type, True))

    def with_output(mut self, port_name: String, value_type: NodeValueType):
        """Append an output port to `default_outputs` (is_input=False)."""
        self.default_outputs.append(Port(port_name, value_type, False))

    def with_field(mut self, field_name: String, default_value: FieldValue):
        """Set a default field value. Overwrites any prior entry for the
        same `field_name`."""
        self.default_fields[field_name.copy()] = default_value.copy()

    def with_size(mut self, size: Vec2):
        """Override the default 200×80 canvas display size."""
        self.default_size = size.copy()


# ============================================================================
# NodeRegistry — catalog of NodeTypeDefs keyed by type_id
# ============================================================================


struct NodeRegistry(Movable):
    """Catalog of `NodeTypeDef`s keyed by `type_id`. Used by the add-menu
    (c40) to populate the spawn list, and by the canvas (c39) to look up
    display metadata at render time.

    The registry tracks two parallel structures:
      - `types: Dict[String, NodeTypeDef]` — random-access lookup.
      - `insertion_order: List[String]` — stable iteration order for
        `by_category()` so a deterministic add-menu walk produces the
        same UI sequence run-to-run (and matches the order typedefs were
        registered).

    Re-registering the same `type_id` REPLACES the typedef (the Dict
    overwrites in place) but does NOT re-append to `insertion_order` —
    the original registration's position in the menu is preserved. This
    matches EriGui's `HashMap::insert` semantics.

    Conforms to `Movable` only (not Copyable) — the registry is large
    once builtins are loaded; the app holds a single instance for the
    process lifetime and there is no use-case for copy-by-value. Move
    via `^` if ownership transfer is needed.
    """

    var types: Dict[String, NodeTypeDef]
    """Random-access lookup. Key is `type_id`."""

    var insertion_order: List[String]
    """Stable iteration order (for `by_category()` + `all_type_ids()`)."""

    def __init__(out self):
        """Construct an empty registry. Call `register(...)` or
        `register_builtins(...)` to populate."""
        self.types = Dict[String, NodeTypeDef]()
        self.insertion_order = List[String]()

    def register(mut self, def_: NodeTypeDef):
        """Register a NodeTypeDef. If `type_id` already exists, REPLACES
        the typedef in-place (the new defaults take effect for future
        `make_node` calls) but preserves the original menu position.

        The parameter name `def_` carries a trailing underscore to avoid
        the `def` keyword.
        """
        var tid = def_.type_id.copy()
        if not (tid in self.types):
            self.insertion_order.append(tid.copy())
        self.types[tid] = def_.copy()

    def lookup(self, type_id: String) raises -> NodeTypeDef:
        """Returns the NodeTypeDef for `type_id`. Raises if not found.

        Use `is_registered(type_id)` to check first if absence is
        expected. The raise is the cleanest way to surface a missing
        type in current beta — `Optional[T]` shapes are awkward across
        the Dict access surface today.
        """
        if not (type_id in self.types):
            raise Error("unknown type_id: " + type_id)
        return self.types[type_id].copy()

    def is_registered(self, type_id: String) -> Bool:
        """True iff `type_id` has been registered."""
        return type_id in self.types

    def make_node(
        self, type_id: String, position: Vec2, id: RetainedId
    ) raises -> Node:
        """Construct a fresh `Node` from the typedef's defaults.

        Caller supplies:
          - `type_id`: which typedef to clone from. Raises if not
            registered.
          - `position`: world-space top-left for the fresh Node.
          - `id`: pre-allocated `RetainedId` (typically from
            `Graph.id_alloc.alloc()` per c11).

        The fresh Node gets:
          - id = caller-supplied
          - type_id = typedef's type_id
          - title = typedef's display_name
          - position = caller-supplied
          - size = typedef's default_size
          - inputs/outputs = PortRefs cloned from typedef's
            default_inputs/outputs (name + value_type carried over;
            is_input is implied by list membership in Node).
          - fields = deep copy of typedef's default_fields.
        """
        if not self.is_registered(type_id):
            raise Error("unknown type_id: " + type_id)
        var typedef = self.types[type_id].copy()
        var node = Node(id, type_id)
        node.title = typedef.display_name.copy()
        node.position = position.copy()
        node.size = typedef.default_size.copy()
        # Copy default port refs (name + value_type tag) into Node's port lists.
        # The full `Port.is_input` flag is dropped because Node already
        # separates inputs from outputs into two lists.
        for p in typedef.default_inputs:
            node.inputs.append(PortRef(p.name.copy(), p.value_type))
        for p in typedef.default_outputs:
            node.outputs.append(PortRef(p.name.copy(), p.value_type))
        # Copy default field values. We materialise the key list first to
        # break the aliasing between iterating the Dict and reading from it
        # in the same expression (the compiler flags `typedef.default_fields[k]`
        # while `k` borrows from `typedef.default_fields.keys()` as an alias
        # violation in current beta).
        var field_keys = List[String]()
        for k in typedef.default_fields.keys():
            field_keys.append(k.copy())
        for i in range(len(field_keys)):
            var key = field_keys[i].copy()
            node.fields[key.copy()] = typedef.default_fields[key].copy()
        return node^

    def by_category(self) raises -> Dict[String, List[String]]:
        """Group registered type_ids by category. Returns a dict of
        category → list of type_ids in INSERTION ORDER (not alphabetic).
        Used by the add-menu (c40) to render category headers with a
        deterministic per-category list.
        """
        var groups = Dict[String, List[String]]()
        for tid in self.insertion_order:
            var cat = self.types[tid].category.copy()
            if not (cat in groups):
                groups[cat] = List[String]()
            groups[cat].append(tid.copy())
        return groups^

    def all_type_ids(self) -> List[String]:
        """Return all registered `type_id`s in insertion order. Used by
        tests + the add-menu's flat fallback path."""
        return self.insertion_order.copy()

    def size(self) -> Int:
        """Number of registered typedefs."""
        return len(self.insertion_order)


# ============================================================================
# register_builtins — convenience starter set mirroring ComfyUI core/media nodes
# ============================================================================


def register_builtins(mut registry: NodeRegistry):
    """Register starter typedefs matching ComfyUI-shaped core/media nodes.

    Apps may either:
      - Call this then add/override via `registry.register(...)`.
      - Skip it entirely and register a custom set.

    The builtin type ids are stable across MojoUI versions (they end up in
    saved workflow JSON); evolving the field/port shapes within a
    given type_id is OK as long as `make_node` still produces a node
    that the runtime can dispatch.
    """
    # core/load_checkpoint — outputs the three model/clip/vae handles
    # ComfyUI splits a checkpoint into.
    var lc = NodeTypeDef(
        String("core/load_checkpoint"),
        String("Load Checkpoint"),
        String("core"),
    )
    lc.with_output(String("model"), NVT_MODEL)
    lc.with_output(String("clip"), NVT_CLIP)
    lc.with_output(String("vae"), NVT_VAE)
    lc.with_field(String("path"), FieldValue.string(String("model.safetensors")))
    registry.register(lc^)

    # core/encode_prompt — CLIP text encoder.
    var ep = NodeTypeDef(
        String("core/encode_prompt"),
        String("Encode Prompt"),
        String("core"),
    )
    ep.with_input(String("clip"), NVT_CLIP)
    ep.with_output(String("cond"), NVT_CONDITIONING)
    ep.with_field(String("text"), FieldValue.string(String("a photo of...")))
    registry.register(ep^)

    # core/k_sampler — the canonical denoise step.
    var ks = NodeTypeDef(
        String("core/k_sampler"),
        String("K-Sampler"),
        String("sampler"),
    )
    ks.with_input(String("model"), NVT_MODEL)
    ks.with_input(String("cond"), NVT_CONDITIONING)
    ks.with_input(String("uncond"), NVT_CONDITIONING)
    ks.with_input(String("latent"), NVT_LATENT)
    ks.with_output(String("latent"), NVT_LATENT)
    ks.with_field(String("cfg"), FieldValue.number(7.0))
    ks.with_field(String("steps"), FieldValue.int_(30))
    ks.with_field(String("seed"), FieldValue.int_(0))
    ks.with_field(String("sampler"), FieldValue.string(String("euler")))
    registry.register(ks^)

    # core/vae_decode — latent → image via the VAE decoder.
    var vd = NodeTypeDef(
        String("core/vae_decode"),
        String("VAE Decode"),
        String("vae"),
    )
    vd.with_input(String("vae"), NVT_VAE)
    vd.with_input(String("latent"), NVT_LATENT)
    vd.with_output(String("image"), NVT_IMAGE)
    registry.register(vd^)

    # core/load_image — source image file into the graph.
    var li = NodeTypeDef(
        String("core/load_image"),
        String("Load Image"),
        String("image"),
    )
    li.with_output(String("image"), NVT_IMAGE)
    li.with_output(String("mask"), NVT_IMAGE)
    li.with_field(String("path"), FieldValue.string(String("input.png")))
    li.with_field(String("upload_label"), FieldValue.string(String("choose file to upload")))
    li.with_size(Vec2(240.0, 260.0))
    registry.register(li^)

    # core/save_image — terminal sink: image → file.
    var si = NodeTypeDef(
        String("core/save_image"),
        String("Save Image"),
        String("image"),
    )
    si.with_input(String("image"), NVT_IMAGE)
    si.with_field(String("path"), FieldValue.string(String("out.png")))
    registry.register(si^)

    # core/image_to_prompt — image caption/region prompt builder entry.
    var itp = NodeTypeDef(
        String("core/image_to_prompt"),
        String("Image to Prompt"),
        String("image"),
    )
    itp.with_input(String("image"), NVT_IMAGE)
    itp.with_output(String("prompt"), NVT_TEXT)
    itp.with_field(String("model"), FieldValue.string(String("kiwi_vision_9b")))
    itp.with_field(String("prompt"), FieldValue.string(String("")))
    itp.with_size(Vec2(240.0, 112.0))
    registry.register(itp^)

    # core/preview_text — terminal text/JSON preview node.
    var pt = NodeTypeDef(
        String("core/preview_text"),
        String("Preview as Text"),
        String("text"),
    )
    pt.with_input(String("source"), NVT_TEXT)
    pt.with_field(String("previewMode"), FieldValue.string(String("Plaintext")))
    pt.with_size(Vec2(360.0, 220.0))
    registry.register(pt^)

    # core/load_video — source a video file into the graph. Apps decide
    # whether the value is a decoded frame stream, path handle, or runtime id.
    var lv = NodeTypeDef(
        String("core/load_video"),
        String("Load Video"),
        String("video"),
    )
    lv.with_output(String("video"), NVT_VIDEO)
    lv.with_field(String("path"), FieldValue.string(String("input.mp4")))
    lv.with_field(String("start_frame"), FieldValue.int_(Int64(0)))
    lv.with_field(String("frame_count"), FieldValue.int_(Int64(0)))
    lv.with_size(Vec2(220.0, 112.0))
    registry.register(lv^)

    # core/preview_video — terminal UI node for showing/opening a video.
    var pv = NodeTypeDef(
        String("core/preview_video"),
        String("Preview Video"),
        String("video"),
    )
    pv.with_input(String("video"), NVT_VIDEO)
    pv.with_field(String("path"), FieldValue.string(String("")))
    pv.with_field(String("autoplay"), FieldValue.bool_(False))
    pv.with_field(String("loop"), FieldValue.bool_(True))
    pv.with_size(Vec2(240.0, 132.0))
    registry.register(pv^)

    # core/save_video — terminal sink: video → file.
    var sv = NodeTypeDef(
        String("core/save_video"),
        String("Save Video"),
        String("video"),
    )
    sv.with_input(String("video"), NVT_VIDEO)
    sv.with_field(String("path"), FieldValue.string(String("out.mp4")))
    sv.with_field(String("fps"), FieldValue.int_(Int64(16)))
    sv.with_field(String("codec"), FieldValue.string(String("h264")))
    sv.with_size(Vec2(220.0, 108.0))
    registry.register(sv^)

    # core/ideogram4_prompt_builder — SerenityUI visual prompt/bbox builder
    # modeled after ComfyUI-style Ideogram4 region editors.
    var ipb = NodeTypeDef(
        String("core/ideogram4_prompt_builder"),
        String("SerenityUI Ideogram Prompt Builder"),
        String("ideogram"),
    )
    ipb.with_input(String("image"), NVT_IMAGE)
    ipb.with_input(String("import_json"), NVT_TEXT)
    ipb.with_input(String("bboxes"), NVT_BBOX)
    ipb.with_output(String("prompt"), NVT_TEXT)
    ipb.with_output(String("preview"), NVT_IMAGE)
    ipb.with_output(String("bboxes"), NVT_BBOX)
    ipb.with_output(String("width"), NVT_NUMBER)
    ipb.with_output(String("height"), NVT_NUMBER)
    ipb.with_field(String("width"), FieldValue.int_(Int64(1024)))
    ipb.with_field(String("height"), FieldValue.int_(Int64(1024)))
    ipb.with_field(String("high_level_description"), FieldValue.string(String("")))
    ipb.with_field(String("background"), FieldValue.string(String("")))
    ipb.with_field(String("style"), FieldValue.string(String("art_style")))
    ipb.with_field(String("photo"), FieldValue.string(String("")))
    ipb.with_field(String("art_style"), FieldValue.string(String("")))
    ipb.with_field(String("aesthetics"), FieldValue.string(String("")))
    ipb.with_field(String("lighting"), FieldValue.string(String("")))
    ipb.with_field(String("medium"), FieldValue.string(String("")))
    ipb.with_field(String("import_json"), FieldValue.string(String("")))
    ipb.with_field(String("style_palette_data"), FieldValue.string(String("")))
    ipb.with_field(String("elements_data"), FieldValue.string(String("")))
    ipb.with_field(String("bg_brightness"), FieldValue.int_(Int64(25)))
    ipb.with_size(Vec2(520.0, 640.0))
    registry.register(ipb^)

    # core/ideogram4_magic_prompt — local Qwen magic-prompt front-end used
    # by mojodiffusion's Ideogram4 pipeline.
    var imp = NodeTypeDef(
        String("core/ideogram4_magic_prompt"),
        String("Ideogram4 Magic Prompt"),
        String("ideogram"),
    )
    imp.with_input(String("prompt"), NVT_TEXT)
    imp.with_output(String("caption_json"), NVT_TEXT)
    imp.with_field(String("aspect_ratio"), FieldValue.string(String("1:1")))
    imp.with_field(String("enabled"), FieldValue.bool_(True))
    imp.with_field(String("magic_prompt_model"), FieldValue.string(String("qwen3-local-v1")))
    imp.with_field(
        String("entry"),
        FieldValue.string(String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_magic.mojo")),
    )
    imp.with_size(Vec2(260.0, 132.0))
    registry.register(imp^)

    # core/ideogram4_generate — structured caption JSON to image. Runtime
    # dispatch is owned by Serenity/mojodiffusion, not by the visual library.
    var ig = NodeTypeDef(
        String("core/ideogram4_generate"),
        String("Ideogram4 Generate"),
        String("ideogram"),
    )
    ig.with_input(String("caption_json"), NVT_TEXT)
    ig.with_output(String("image"), NVT_IMAGE)
    ig.with_field(String("width"), FieldValue.int_(Int64(1024)))
    ig.with_field(String("height"), FieldValue.int_(Int64(1024)))
    ig.with_field(String("preset"), FieldValue.string(String("V4_QUALITY_48")))
    ig.with_field(String("steps"), FieldValue.int_(Int64(48)))
    ig.with_field(String("seed"), FieldValue.int_(Int64(0)))
    ig.with_field(String("magic_prompt"), FieldValue.bool_(True))
    ig.with_field(
        String("output_path"),
        FieldValue.string(String("/home/alex/mojodiffusion/output/ideogram4_generated_1024.png")),
    )
    ig.with_field(
        String("entry"),
        FieldValue.string(String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_generate.mojo")),
    )
    ig.with_size(Vec2(260.0, 152.0))
    registry.register(ig^)

    register_comfy_standard_nodes(registry)


def register_comfy_standard_nodes(mut registry: NodeRegistry):
    """Register ComfyUI/Swarm/KJ/rgthree node shapes as data-only typedefs.

    These are visual/runtime contracts only: they give imports and add-menu
    spawning stable ports/fields. App-level executors still own the actual
    GPU/runtime dispatch for each `type_id`.
    """
    var cls = NodeTypeDef(
        String("comfy/CheckpointLoaderSimple"),
        String("Checkpoint Loader Simple"),
        String("comfy/loaders"),
    )
    cls.with_output(String("MODEL"), NVT_MODEL)
    cls.with_output(String("CLIP"), NVT_CLIP)
    cls.with_output(String("VAE"), NVT_VAE)
    cls.with_field(String("ckpt_name"), FieldValue.string(String("model.safetensors")))
    cls.with_size(Vec2(290.0, 120.0))
    registry.register(cls^)

    var unet = NodeTypeDef(
        String("comfy/UNETLoader"),
        String("UNET Loader"),
        String("comfy/loaders"),
    )
    unet.with_output(String("MODEL"), NVT_MODEL)
    unet.with_field(String("unet_name"), FieldValue.string(String("diffusion_model.safetensors")))
    unet.with_field(String("weight_dtype"), FieldValue.string(String("default")))
    unet.with_size(Vec2(300.0, 120.0))
    registry.register(unet^)

    var dual_clip = NodeTypeDef(
        String("comfy/DualCLIPLoader"),
        String("Dual CLIP Loader"),
        String("comfy/loaders"),
    )
    dual_clip.with_output(String("CLIP"), NVT_CLIP)
    dual_clip.with_field(String("clip_name1"), FieldValue.string(String("clip_l.safetensors")))
    dual_clip.with_field(String("clip_name2"), FieldValue.string(String("t5xxl.safetensors")))
    dual_clip.with_field(String("type"), FieldValue.string(String("flux")))
    dual_clip.with_size(Vec2(300.0, 142.0))
    registry.register(dual_clip^)

    var vae_loader = NodeTypeDef(
        String("comfy/VAELoader"),
        String("VAE Loader"),
        String("comfy/loaders"),
    )
    vae_loader.with_output(String("VAE"), NVT_VAE)
    vae_loader.with_field(String("vae_name"), FieldValue.string(String("vae.safetensors")))
    vae_loader.with_size(Vec2(240.0, 98.0))
    registry.register(vae_loader^)

    var lora_loader = NodeTypeDef(
        String("comfy/LoraLoader"),
        String("LoRA Loader"),
        String("comfy/loaders"),
    )
    lora_loader.with_input(String("model"), NVT_MODEL)
    lora_loader.with_input(String("clip"), NVT_CLIP)
    lora_loader.with_output(String("MODEL"), NVT_MODEL)
    lora_loader.with_output(String("CLIP"), NVT_CLIP)
    lora_loader.with_field(String("lora_name"), FieldValue.string(String("lora.safetensors")))
    lora_loader.with_field(String("strength_model"), FieldValue.number(1.0))
    lora_loader.with_field(String("strength_clip"), FieldValue.number(1.0))
    lora_loader.with_size(Vec2(320.0, 168.0))
    registry.register(lora_loader^)

    var clip_text = NodeTypeDef(
        String("comfy/CLIPTextEncode"),
        String("CLIP Text Encode"),
        String("comfy/conditioning"),
    )
    clip_text.with_input(String("clip"), NVT_CLIP)
    clip_text.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    clip_text.with_field(String("text"), FieldValue.string(String("")))
    clip_text.with_size(Vec2(360.0, 240.0))
    registry.register(clip_text^)

    var clip_sdxl = NodeTypeDef(
        String("comfy/CLIPTextEncodeSDXL"),
        String("CLIP Text Encode SDXL"),
        String("comfy/conditioning"),
    )
    clip_sdxl.with_input(String("clip"), NVT_CLIP)
    clip_sdxl.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    clip_sdxl.with_field(String("width"), FieldValue.int_(Int64(1024)))
    clip_sdxl.with_field(String("height"), FieldValue.int_(Int64(1024)))
    clip_sdxl.with_field(String("crop_w"), FieldValue.int_(Int64(0)))
    clip_sdxl.with_field(String("crop_h"), FieldValue.int_(Int64(0)))
    clip_sdxl.with_field(String("target_width"), FieldValue.int_(Int64(1024)))
    clip_sdxl.with_field(String("target_height"), FieldValue.int_(Int64(1024)))
    clip_sdxl.with_field(String("text_g"), FieldValue.string(String("")))
    clip_sdxl.with_field(String("text_l"), FieldValue.string(String("")))
    clip_sdxl.with_size(Vec2(420.0, 300.0))
    registry.register(clip_sdxl^)

    var empty_latent = NodeTypeDef(
        String("comfy/EmptyLatentImage"),
        String("Empty Latent Image"),
        String("comfy/latent"),
    )
    empty_latent.with_output(String("LATENT"), NVT_LATENT)
    empty_latent.with_field(String("width"), FieldValue.int_(Int64(1024)))
    empty_latent.with_field(String("height"), FieldValue.int_(Int64(1024)))
    empty_latent.with_field(String("batch_size"), FieldValue.int_(Int64(1)))
    empty_latent.with_size(Vec2(260.0, 140.0))
    registry.register(empty_latent^)

    var latent_batch = NodeTypeDef(
        String("comfy/LatentFromBatch"),
        String("Latent From Batch"),
        String("comfy/latent"),
    )
    latent_batch.with_input(String("samples"), NVT_LATENT)
    latent_batch.with_output(String("LATENT"), NVT_LATENT)
    latent_batch.with_field(String("batch_index"), FieldValue.int_(Int64(0)))
    latent_batch.with_field(String("length"), FieldValue.int_(Int64(1)))
    latent_batch.with_size(Vec2(260.0, 122.0))
    registry.register(latent_batch^)

    var vae_encode = NodeTypeDef(
        String("comfy/VAEEncode"),
        String("VAE Encode"),
        String("comfy/vae"),
    )
    vae_encode.with_input(String("pixels"), NVT_IMAGE)
    vae_encode.with_input(String("vae"), NVT_VAE)
    vae_encode.with_output(String("LATENT"), NVT_LATENT)
    vae_encode.with_size(Vec2(220.0, 98.0))
    registry.register(vae_encode^)

    var vae_decode = NodeTypeDef(
        String("comfy/VAEDecode"),
        String("VAE Decode"),
        String("comfy/vae"),
    )
    vae_decode.with_input(String("samples"), NVT_LATENT)
    vae_decode.with_input(String("vae"), NVT_VAE)
    vae_decode.with_output(String("IMAGE"), NVT_IMAGE)
    vae_decode.with_size(Vec2(220.0, 98.0))
    registry.register(vae_decode^)

    var vae_inpaint = NodeTypeDef(
        String("comfy/VAEEncodeForInpaint"),
        String("VAE Encode For Inpaint"),
        String("comfy/vae"),
    )
    vae_inpaint.with_input(String("pixels"), NVT_IMAGE)
    vae_inpaint.with_input(String("vae"), NVT_VAE)
    vae_inpaint.with_input(String("mask"), NVT_IMAGE)
    vae_inpaint.with_output(String("LATENT"), NVT_LATENT)
    vae_inpaint.with_field(String("grow_mask_by"), FieldValue.int_(Int64(6)))
    vae_inpaint.with_size(Vec2(290.0, 130.0))
    registry.register(vae_inpaint^)

    var noise_mask = NodeTypeDef(
        String("comfy/SetLatentNoiseMask"),
        String("Set Latent Noise Mask"),
        String("comfy/latent"),
    )
    noise_mask.with_input(String("samples"), NVT_LATENT)
    noise_mask.with_input(String("mask"), NVT_IMAGE)
    noise_mask.with_output(String("LATENT"), NVT_LATENT)
    noise_mask.with_size(Vec2(260.0, 100.0))
    registry.register(noise_mask^)

    var ksampler = NodeTypeDef(
        String("comfy/KSampler"),
        String("KSampler"),
        String("comfy/sampling"),
    )
    ksampler.with_input(String("model"), NVT_MODEL)
    ksampler.with_input(String("positive"), NVT_CONDITIONING)
    ksampler.with_input(String("negative"), NVT_CONDITIONING)
    ksampler.with_input(String("latent_image"), NVT_LATENT)
    ksampler.with_output(String("LATENT"), NVT_LATENT)
    ksampler.with_field(String("seed"), FieldValue.int_(Int64(0)))
    ksampler.with_field(String("control_after_generate"), FieldValue.string(String("randomize")))
    ksampler.with_field(String("steps"), FieldValue.int_(Int64(20)))
    ksampler.with_field(String("cfg"), FieldValue.number(8.0))
    ksampler.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    ksampler.with_field(String("scheduler"), FieldValue.string(String("normal")))
    ksampler.with_field(String("denoise"), FieldValue.number(1.0))
    ksampler.with_size(Vec2(340.0, 235.0))
    registry.register(ksampler^)

    var ksampler_adv = NodeTypeDef(
        String("comfy/KSamplerAdvanced"),
        String("KSampler Advanced"),
        String("comfy/sampling"),
    )
    ksampler_adv.with_input(String("model"), NVT_MODEL)
    ksampler_adv.with_input(String("positive"), NVT_CONDITIONING)
    ksampler_adv.with_input(String("negative"), NVT_CONDITIONING)
    ksampler_adv.with_input(String("latent_image"), NVT_LATENT)
    ksampler_adv.with_output(String("LATENT"), NVT_LATENT)
    ksampler_adv.with_field(String("add_noise"), FieldValue.string(String("enable")))
    ksampler_adv.with_field(String("noise_seed"), FieldValue.int_(Int64(0)))
    ksampler_adv.with_field(String("steps"), FieldValue.int_(Int64(20)))
    ksampler_adv.with_field(String("cfg"), FieldValue.number(8.0))
    ksampler_adv.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    ksampler_adv.with_field(String("scheduler"), FieldValue.string(String("normal")))
    ksampler_adv.with_field(String("start_at_step"), FieldValue.int_(Int64(0)))
    ksampler_adv.with_field(String("end_at_step"), FieldValue.int_(Int64(10000)))
    ksampler_adv.with_field(String("return_with_leftover_noise"), FieldValue.string(String("disable")))
    ksampler_adv.with_size(Vec2(380.0, 290.0))
    registry.register(ksampler_adv^)

    var sampler_custom = NodeTypeDef(
        String("comfy/SamplerCustom"),
        String("Sampler Custom"),
        String("comfy/sampling"),
    )
    sampler_custom.with_input(String("model"), NVT_MODEL)
    sampler_custom.with_input(String("add_noise"), NVT_BOOL)
    sampler_custom.with_input(String("noise_seed"), NVT_SEED)
    sampler_custom.with_input(String("cfg"), NVT_NUMBER)
    sampler_custom.with_input(String("positive"), NVT_CONDITIONING)
    sampler_custom.with_input(String("negative"), NVT_CONDITIONING)
    sampler_custom.with_input(String("sampler"), NVT_TEXT)
    sampler_custom.with_input(String("sigmas"), NVT_NUMBER)
    sampler_custom.with_input(String("latent_image"), NVT_LATENT)
    sampler_custom.with_output(String("LATENT"), NVT_LATENT)
    sampler_custom.with_output(String("LATENT_DENOISED"), NVT_LATENT)
    sampler_custom.with_size(Vec2(380.0, 250.0))
    registry.register(sampler_custom^)

    var load_image = NodeTypeDef(
        String("comfy/LoadImage"),
        String("Load Image"),
        String("comfy/image"),
    )
    load_image.with_output(String("IMAGE"), NVT_IMAGE)
    load_image.with_output(String("MASK"), NVT_IMAGE)
    load_image.with_field(String("image"), FieldValue.string(String("input.png")))
    load_image.with_field(String("upload"), FieldValue.string(String("image")))
    load_image.with_size(Vec2(300.0, 300.0))
    registry.register(load_image^)

    var save_image = NodeTypeDef(
        String("comfy/SaveImage"),
        String("Save Image"),
        String("comfy/image"),
    )
    save_image.with_input(String("images"), NVT_IMAGE)
    save_image.with_field(String("filename_prefix"), FieldValue.string(String("ComfyUI")))
    save_image.with_size(Vec2(320.0, 150.0))
    registry.register(save_image^)

    var preview_image = NodeTypeDef(
        String("comfy/PreviewImage"),
        String("Preview Image"),
        String("comfy/image"),
    )
    preview_image.with_input(String("images"), NVT_IMAGE)
    preview_image.with_size(Vec2(320.0, 240.0))
    registry.register(preview_image^)

    var image_scale = NodeTypeDef(
        String("comfy/ImageScale"),
        String("Image Scale"),
        String("comfy/image"),
    )
    image_scale.with_input(String("image"), NVT_IMAGE)
    image_scale.with_output(String("IMAGE"), NVT_IMAGE)
    image_scale.with_field(String("upscale_method"), FieldValue.string(String("lanczos")))
    image_scale.with_field(String("width"), FieldValue.int_(Int64(1024)))
    image_scale.with_field(String("height"), FieldValue.int_(Int64(1024)))
    image_scale.with_field(String("crop"), FieldValue.string(String("disabled")))
    image_scale.with_size(Vec2(300.0, 160.0))
    registry.register(image_scale^)

    var image_scale_by = NodeTypeDef(
        String("comfy/ImageScaleBy"),
        String("Image Scale By"),
        String("comfy/image"),
    )
    image_scale_by.with_input(String("image"), NVT_IMAGE)
    image_scale_by.with_output(String("IMAGE"), NVT_IMAGE)
    image_scale_by.with_field(String("upscale_method"), FieldValue.string(String("lanczos")))
    image_scale_by.with_field(String("scale_by"), FieldValue.number(2.0))
    image_scale_by.with_size(Vec2(280.0, 132.0))
    registry.register(image_scale_by^)

    var image_invert = NodeTypeDef(
        String("comfy/ImageInvert"),
        String("Image Invert"),
        String("comfy/image"),
    )
    image_invert.with_input(String("image"), NVT_IMAGE)
    image_invert.with_output(String("IMAGE"), NVT_IMAGE)
    image_invert.with_size(Vec2(220.0, 90.0))
    registry.register(image_invert^)

    var upscale_loader = NodeTypeDef(
        String("comfy/UpscaleModelLoader"),
        String("Upscale Model Loader"),
        String("comfy/image"),
    )
    upscale_loader.with_output(String("UPSCALE_MODEL"), NVT_MODEL)
    upscale_loader.with_field(String("model_name"), FieldValue.string(String("upscale_model.pth")))
    upscale_loader.with_size(Vec2(300.0, 112.0))
    registry.register(upscale_loader^)

    var upscale = NodeTypeDef(
        String("comfy/ImageUpscaleWithModel"),
        String("Image Upscale With Model"),
        String("comfy/image"),
    )
    upscale.with_input(String("upscale_model"), NVT_MODEL)
    upscale.with_input(String("image"), NVT_IMAGE)
    upscale.with_output(String("IMAGE"), NVT_IMAGE)
    upscale.with_size(Vec2(320.0, 110.0))
    registry.register(upscale^)

    var control_loader = NodeTypeDef(
        String("comfy/ControlNetLoader"),
        String("ControlNet Loader"),
        String("comfy/controlnet"),
    )
    control_loader.with_output(String("CONTROL_NET"), NVT_MODEL)
    control_loader.with_field(String("control_net_name"), FieldValue.string(String("controlnet.safetensors")))
    control_loader.with_size(Vec2(320.0, 110.0))
    registry.register(control_loader^)

    var control_apply = NodeTypeDef(
        String("comfy/ControlNetApply"),
        String("ControlNet Apply"),
        String("comfy/controlnet"),
    )
    control_apply.with_input(String("conditioning"), NVT_CONDITIONING)
    control_apply.with_input(String("control_net"), NVT_MODEL)
    control_apply.with_input(String("image"), NVT_IMAGE)
    control_apply.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    control_apply.with_field(String("strength"), FieldValue.number(1.0))
    control_apply.with_size(Vec2(320.0, 150.0))
    registry.register(control_apply^)

    var control_adv = NodeTypeDef(
        String("comfy/ControlNetApplyAdvanced"),
        String("ControlNet Apply Advanced"),
        String("comfy/controlnet"),
    )
    control_adv.with_input(String("positive"), NVT_CONDITIONING)
    control_adv.with_input(String("negative"), NVT_CONDITIONING)
    control_adv.with_input(String("control_net"), NVT_MODEL)
    control_adv.with_input(String("image"), NVT_IMAGE)
    control_adv.with_output(String("positive"), NVT_CONDITIONING)
    control_adv.with_output(String("negative"), NVT_CONDITIONING)
    control_adv.with_field(String("strength"), FieldValue.number(1.0))
    control_adv.with_field(String("start_percent"), FieldValue.number(0.0))
    control_adv.with_field(String("end_percent"), FieldValue.number(1.0))
    control_adv.with_size(Vec2(360.0, 190.0))
    registry.register(control_adv^)

    var preview_any = NodeTypeDef(
        String("comfy/PreviewAny"),
        String("Preview Any"),
        String("comfy/utility"),
    )
    preview_any.with_input(String("source"), NVT_TEXT)
    preview_any.with_output(String("STRING"), NVT_TEXT)
    preview_any.with_size(Vec2(320.0, 180.0))
    registry.register(preview_any^)

    var markdown = NodeTypeDef(
        String("comfy/MarkdownNote"),
        String("Markdown Note"),
        String("comfy/utility"),
    )
    markdown.with_field(String("text"), FieldValue.string(String("")))
    markdown.with_size(Vec2(420.0, 240.0))
    registry.register(markdown^)

    var resolution = NodeTypeDef(
        String("comfy/ResolutionSelector"),
        String("Resolution Selector"),
        String("comfy/utility"),
    )
    resolution.with_output(String("width"), NVT_NUMBER)
    resolution.with_output(String("height"), NVT_NUMBER)
    resolution.with_field(String("aspect_ratio"), FieldValue.string(String("1:1")))
    resolution.with_field(String("megapixels"), FieldValue.number(1.0))
    resolution.with_size(Vec2(300.0, 130.0))
    registry.register(resolution^)

    var rg_config = NodeTypeDef(
        String("rgthree/KSamplerConfig"),
        String("rgthree KSampler Config"),
        String("rgthree"),
    )
    rg_config.with_output(String("STEPS"), NVT_NUMBER)
    rg_config.with_output(String("REFINER_STEP"), NVT_NUMBER)
    rg_config.with_output(String("CFG"), NVT_NUMBER)
    rg_config.with_output(String("SAMPLER"), NVT_TEXT)
    rg_config.with_output(String("SCHEDULER"), NVT_TEXT)
    rg_config.with_field(String("steps_total"), FieldValue.int_(Int64(30)))
    rg_config.with_field(String("refiner_step"), FieldValue.int_(Int64(24)))
    rg_config.with_field(String("cfg"), FieldValue.number(8.0))
    rg_config.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    rg_config.with_field(String("scheduler"), FieldValue.string(String("normal")))
    rg_config.with_size(Vec2(330.0, 165.0))
    registry.register(rg_config^)

    var rg_loras = NodeTypeDef(
        String("rgthree/LoraLoaderStack"),
        String("rgthree LoRA Loader Stack"),
        String("rgthree"),
    )
    rg_loras.with_input(String("model"), NVT_MODEL)
    rg_loras.with_input(String("clip"), NVT_CLIP)
    rg_loras.with_output(String("MODEL"), NVT_MODEL)
    rg_loras.with_output(String("CLIP"), NVT_CLIP)
    rg_loras.with_field(String("lora_01"), FieldValue.string(String("None")))
    rg_loras.with_field(String("strength_01"), FieldValue.number(1.0))
    rg_loras.with_field(String("lora_02"), FieldValue.string(String("None")))
    rg_loras.with_field(String("strength_02"), FieldValue.number(1.0))
    rg_loras.with_field(String("lora_03"), FieldValue.string(String("None")))
    rg_loras.with_field(String("strength_03"), FieldValue.number(1.0))
    rg_loras.with_field(String("lora_04"), FieldValue.string(String("None")))
    rg_loras.with_field(String("strength_04"), FieldValue.number(1.0))
    rg_loras.with_size(Vec2(360.0, 260.0))
    registry.register(rg_loras^)

    var rg_power_lora = NodeTypeDef(
        String("rgthree/PowerLoraLoader"),
        String("rgthree Power LoRA Loader"),
        String("rgthree"),
    )
    rg_power_lora.with_input(String("model"), NVT_MODEL)
    rg_power_lora.with_input(String("clip"), NVT_CLIP)
    rg_power_lora.with_output(String("MODEL"), NVT_MODEL)
    rg_power_lora.with_output(String("CLIP"), NVT_CLIP)
    rg_power_lora.with_field(String("lora_stack_json"), FieldValue.string(String("[]")))
    rg_power_lora.with_size(Vec2(360.0, 220.0))
    registry.register(rg_power_lora^)

    var kj_ckpt = NodeTypeDef(
        String("kj/CheckpointLoaderKJ"),
        String("Checkpoint Loader KJ"),
        String("kj"),
    )
    kj_ckpt.with_output(String("MODEL"), NVT_MODEL)
    kj_ckpt.with_output(String("CLIP"), NVT_CLIP)
    kj_ckpt.with_output(String("VAE"), NVT_VAE)
    kj_ckpt.with_field(String("ckpt_name"), FieldValue.string(String("model.safetensors")))
    kj_ckpt.with_field(String("weight_dtype"), FieldValue.string(String("default")))
    kj_ckpt.with_field(String("compute_dtype"), FieldValue.string(String("default")))
    kj_ckpt.with_field(String("patch_cublaslinear"), FieldValue.bool_(False))
    kj_ckpt.with_field(String("sage_attention"), FieldValue.string(String("disabled")))
    kj_ckpt.with_field(String("enable_fp16_accumulation"), FieldValue.bool_(False))
    kj_ckpt.with_size(Vec2(390.0, 230.0))
    registry.register(kj_ckpt^)

    var kj_vae_loop = NodeTypeDef(
        String("kj/VAEDecodeLoopKJ"),
        String("VAE Decode Loop KJ"),
        String("kj"),
    )
    kj_vae_loop.with_input(String("samples"), NVT_LATENT)
    kj_vae_loop.with_input(String("vae"), NVT_VAE)
    kj_vae_loop.with_output(String("IMAGE"), NVT_IMAGE)
    kj_vae_loop.with_field(String("overlap_latent_frames"), FieldValue.int_(Int64(2)))
    kj_vae_loop.with_size(Vec2(300.0, 125.0))
    registry.register(kj_vae_loop^)

    var kj_ideo = NodeTypeDef(
        String("kj/Ideogram4PromptBuilderKJ"),
        String("Ideogram 4 Prompt Builder KJ"),
        String("kj"),
    )
    kj_ideo.with_input(String("text"), NVT_TEXT)
    kj_ideo.with_input(String("width"), NVT_NUMBER)
    kj_ideo.with_input(String("height"), NVT_NUMBER)
    kj_ideo.with_output(String("STRING"), NVT_TEXT)
    kj_ideo.with_output(String("BBOXES"), NVT_BBOX)
    kj_ideo.with_field(String("caption_json"), FieldValue.string(String("")))
    kj_ideo.with_field(String("elements_data"), FieldValue.string(String("")))
    kj_ideo.with_size(Vec2(440.0, 690.0))
    registry.register(kj_ideo^)

    var swarm_sampler = NodeTypeDef(
        String("swarm/SwarmKSampler"),
        String("Swarm KSampler"),
        String("swarm"),
    )
    swarm_sampler.with_input(String("model"), NVT_MODEL)
    swarm_sampler.with_input(String("positive"), NVT_CONDITIONING)
    swarm_sampler.with_input(String("negative"), NVT_CONDITIONING)
    swarm_sampler.with_input(String("latent_image"), NVT_LATENT)
    swarm_sampler.with_output(String("LATENT"), NVT_LATENT)
    swarm_sampler.with_field(String("noise_seed"), FieldValue.int_(Int64(0)))
    swarm_sampler.with_field(String("steps"), FieldValue.int_(Int64(20)))
    swarm_sampler.with_field(String("cfg"), FieldValue.number(8.0))
    swarm_sampler.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    swarm_sampler.with_field(String("scheduler"), FieldValue.string(String("normal")))
    swarm_sampler.with_field(String("start_at_step"), FieldValue.int_(Int64(0)))
    swarm_sampler.with_field(String("end_at_step"), FieldValue.int_(Int64(10000)))
    swarm_sampler.with_field(String("tile_sample"), FieldValue.bool_(False))
    swarm_sampler.with_field(String("tile_size"), FieldValue.int_(Int64(1024)))
    swarm_sampler.with_size(Vec2(400.0, 300.0))
    registry.register(swarm_sampler^)

    var swarm_lora = NodeTypeDef(
        String("swarm/SwarmLoraLoader"),
        String("Swarm LoRA Loader"),
        String("swarm"),
    )
    swarm_lora.with_input(String("model"), NVT_MODEL)
    swarm_lora.with_input(String("clip"), NVT_CLIP)
    swarm_lora.with_output(String("MODEL"), NVT_MODEL)
    swarm_lora.with_output(String("CLIP"), NVT_CLIP)
    swarm_lora.with_field(String("lora_names"), FieldValue.string(String("")))
    swarm_lora.with_field(String("lora_weights"), FieldValue.string(String("")))
    swarm_lora.with_size(Vec2(350.0, 170.0))
    registry.register(swarm_lora^)

    var swarm_load_b64 = NodeTypeDef(
        String("swarm/SwarmLoadImageB64"),
        String("Swarm Load Image B64"),
        String("swarm"),
    )
    swarm_load_b64.with_output(String("IMAGE"), NVT_IMAGE)
    swarm_load_b64.with_output(String("MASK"), NVT_IMAGE)
    swarm_load_b64.with_field(String("image_base64"), FieldValue.string(String("")))
    swarm_load_b64.with_size(Vec2(360.0, 220.0))
    registry.register(swarm_load_b64^)

    var swarm_save_ws = NodeTypeDef(
        String("swarm/SwarmSaveImageWS"),
        String("Swarm Save Image WS"),
        String("swarm"),
    )
    swarm_save_ws.with_input(String("images"), NVT_IMAGE)
    swarm_save_ws.with_field(String("filename_prefix"), FieldValue.string(String("SwarmUI")))
    swarm_save_ws.with_size(Vec2(330.0, 145.0))
    registry.register(swarm_save_ws^)

    var uuid_image_gen = NodeTypeDef(
        String("comfy/83e6e004-48ea-408e-9024-eb49c3d7dc14"),
        String("SerenityUI Ideogram Image Node"),
        String("comfy/imported"),
    )
    uuid_image_gen.with_input(String("text"), NVT_TEXT)
    uuid_image_gen.with_input(String("value"), NVT_NUMBER)
    uuid_image_gen.with_input(String("value_1"), NVT_NUMBER)
    uuid_image_gen.with_output(String("IMAGE"), NVT_IMAGE)
    uuid_image_gen.with_field(String("mode"), FieldValue.string(String("generate")))
    uuid_image_gen.with_size(Vec2(440.0, 690.0))
    registry.register(uuid_image_gen^)

    var uuid_prompt = NodeTypeDef(
        String("comfy/f5f04613-ee09-4cd9-9ada-a880360891d4"),
        String("SerenityUI Prompt Composer"),
        String("comfy/imported"),
    )
    uuid_prompt.with_input(String("value"), NVT_TEXT)
    uuid_prompt.with_input(String("source"), NVT_NUMBER)
    uuid_prompt.with_input(String("source_1"), NVT_NUMBER)
    uuid_prompt.with_output(String("STRING"), NVT_TEXT)
    uuid_prompt.with_size(Vec2(480.0, 400.0))
    registry.register(uuid_prompt^)

    register_comfy_compat_extension_nodes(registry)


def register_comfy_compat_extension_nodes(mut registry: NodeRegistry):
    """Extra Comfy core + popular extension contracts.

    These exact `comfy/<class_type>` registrations let imported API/visual
    workflows from ComfyUI, rgthree, KJNodes, and Swarm resolve without a
    Python node server. Runtime behavior still lives in the app executor.
    """
    var ckpt = NodeTypeDef(
        String("comfy/CheckpointLoader"),
        String("Checkpoint Loader"),
        String("comfy/loaders"),
    )
    ckpt.with_output(String("MODEL"), NVT_MODEL)
    ckpt.with_output(String("CLIP"), NVT_CLIP)
    ckpt.with_output(String("VAE"), NVT_VAE)
    ckpt.with_field(String("config_name"), FieldValue.string(String("config.yaml")))
    ckpt.with_field(String("ckpt_name"), FieldValue.string(String("model.safetensors")))
    ckpt.with_size(Vec2(330.0, 145.0))
    registry.register(ckpt^)

    var clip_loader = NodeTypeDef(
        String("comfy/CLIPLoader"),
        String("CLIP Loader"),
        String("comfy/loaders"),
    )
    clip_loader.with_output(String("CLIP"), NVT_CLIP)
    clip_loader.with_field(String("clip_name"), FieldValue.string(String("clip.safetensors")))
    clip_loader.with_field(String("type"), FieldValue.string(String("stable_diffusion")))
    clip_loader.with_size(Vec2(300.0, 125.0))
    registry.register(clip_loader^)

    var triple_clip = NodeTypeDef(
        String("comfy/TripleCLIPLoader"),
        String("Triple CLIP Loader"),
        String("comfy/loaders"),
    )
    triple_clip.with_output(String("CLIP"), NVT_CLIP)
    triple_clip.with_field(String("clip_name1"), FieldValue.string(String("clip_l.safetensors")))
    triple_clip.with_field(String("clip_name2"), FieldValue.string(String("clip_g.safetensors")))
    triple_clip.with_field(String("clip_name3"), FieldValue.string(String("t5xxl.safetensors")))
    triple_clip.with_size(Vec2(340.0, 158.0))
    registry.register(triple_clip^)

    var lora_model = NodeTypeDef(
        String("comfy/LoraLoaderModelOnly"),
        String("LoRA Loader Model Only"),
        String("comfy/loaders"),
    )
    lora_model.with_input(String("model"), NVT_MODEL)
    lora_model.with_output(String("MODEL"), NVT_MODEL)
    lora_model.with_field(String("lora_name"), FieldValue.string(String("lora.safetensors")))
    lora_model.with_field(String("strength_model"), FieldValue.number(1.0))
    lora_model.with_size(Vec2(320.0, 135.0))
    registry.register(lora_model^)

    var tiled_decode = NodeTypeDef(
        String("comfy/VAEDecodeTiled"),
        String("VAE Decode Tiled"),
        String("comfy/vae"),
    )
    tiled_decode.with_input(String("samples"), NVT_LATENT)
    tiled_decode.with_input(String("vae"), NVT_VAE)
    tiled_decode.with_output(String("IMAGE"), NVT_IMAGE)
    tiled_decode.with_field(String("tile_size"), FieldValue.int_(Int64(512)))
    tiled_decode.with_size(Vec2(260.0, 122.0))
    registry.register(tiled_decode^)

    var tiled_encode = NodeTypeDef(
        String("comfy/VAEEncodeTiled"),
        String("VAE Encode Tiled"),
        String("comfy/vae"),
    )
    tiled_encode.with_input(String("pixels"), NVT_IMAGE)
    tiled_encode.with_input(String("vae"), NVT_VAE)
    tiled_encode.with_output(String("LATENT"), NVT_LATENT)
    tiled_encode.with_field(String("tile_size"), FieldValue.int_(Int64(512)))
    tiled_encode.with_size(Vec2(260.0, 122.0))
    registry.register(tiled_encode^)

    var cond_combine = NodeTypeDef(
        String("comfy/ConditioningCombine"),
        String("Conditioning Combine"),
        String("comfy/conditioning"),
    )
    cond_combine.with_input(String("conditioning_1"), NVT_CONDITIONING)
    cond_combine.with_input(String("conditioning_2"), NVT_CONDITIONING)
    cond_combine.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    cond_combine.with_size(Vec2(310.0, 120.0))
    registry.register(cond_combine^)

    var cond_zero = NodeTypeDef(
        String("comfy/ConditioningZeroOut"),
        String("Conditioning Zero Out"),
        String("comfy/conditioning"),
    )
    cond_zero.with_input(String("conditioning"), NVT_CONDITIONING)
    cond_zero.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    cond_zero.with_size(Vec2(290.0, 100.0))
    registry.register(cond_zero^)

    var latent_repeat = NodeTypeDef(
        String("comfy/RepeatLatentBatch"),
        String("Repeat Latent Batch"),
        String("comfy/latent"),
    )
    latent_repeat.with_input(String("samples"), NVT_LATENT)
    latent_repeat.with_output(String("LATENT"), NVT_LATENT)
    latent_repeat.with_field(String("amount"), FieldValue.int_(Int64(1)))
    latent_repeat.with_size(Vec2(280.0, 120.0))
    registry.register(latent_repeat^)

    var latent_upscale = NodeTypeDef(
        String("comfy/LatentUpscale"),
        String("Latent Upscale"),
        String("comfy/latent"),
    )
    latent_upscale.with_input(String("samples"), NVT_LATENT)
    latent_upscale.with_output(String("LATENT"), NVT_LATENT)
    latent_upscale.with_field(String("upscale_method"), FieldValue.string(String("nearest-exact")))
    latent_upscale.with_field(String("width"), FieldValue.int_(Int64(1024)))
    latent_upscale.with_field(String("height"), FieldValue.int_(Int64(1024)))
    latent_upscale.with_size(Vec2(310.0, 155.0))
    registry.register(latent_upscale^)

    var latent_upscale_by = NodeTypeDef(
        String("comfy/LatentUpscaleBy"),
        String("Latent Upscale By"),
        String("comfy/latent"),
    )
    latent_upscale_by.with_input(String("samples"), NVT_LATENT)
    latent_upscale_by.with_output(String("LATENT"), NVT_LATENT)
    latent_upscale_by.with_field(String("scale_by"), FieldValue.number(2.0))
    latent_upscale_by.with_size(Vec2(290.0, 125.0))
    registry.register(latent_upscale_by^)

    var rg_seed = NodeTypeDef(
        String("comfy/Seed (rgthree)"),
        String("rgthree Seed"),
        String("rgthree"),
    )
    rg_seed.with_output(String("SEED"), NVT_SEED)
    rg_seed.with_field(String("seed"), FieldValue.int_(Int64(0)))
    rg_seed.with_size(Vec2(250.0, 105.0))
    registry.register(rg_seed^)

    var rg_any = NodeTypeDef(
        String("comfy/Any Switch (rgthree)"),
        String("rgthree Any Switch"),
        String("rgthree"),
    )
    rg_any.with_input(String("any_01"), NVT_TEXT)
    rg_any.with_input(String("any_02"), NVT_TEXT)
    rg_any.with_input(String("any_03"), NVT_TEXT)
    rg_any.with_output(String("*"), NVT_TEXT)
    rg_any.with_size(Vec2(310.0, 145.0))
    registry.register(rg_any^)

    var rg_power_prompt = NodeTypeDef(
        String("comfy/Power Prompt (rgthree)"),
        String("rgthree Power Prompt"),
        String("rgthree"),
    )
    rg_power_prompt.with_input(String("opt_model"), NVT_MODEL)
    rg_power_prompt.with_input(String("opt_clip"), NVT_CLIP)
    rg_power_prompt.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    rg_power_prompt.with_output(String("MODEL"), NVT_MODEL)
    rg_power_prompt.with_output(String("CLIP"), NVT_CLIP)
    rg_power_prompt.with_output(String("TEXT"), NVT_TEXT)
    rg_power_prompt.with_field(String("prompt"), FieldValue.string(String("")))
    rg_power_prompt.with_size(Vec2(430.0, 230.0))
    registry.register(rg_power_prompt^)

    var rg_power_prompt_simple = NodeTypeDef(
        String("comfy/Power Prompt - Simple (rgthree)"),
        String("rgthree Power Prompt Simple"),
        String("rgthree"),
    )
    rg_power_prompt_simple.with_input(String("opt_clip"), NVT_CLIP)
    rg_power_prompt_simple.with_output(String("CONDITIONING"), NVT_CONDITIONING)
    rg_power_prompt_simple.with_output(String("TEXT"), NVT_TEXT)
    rg_power_prompt_simple.with_field(String("prompt"), FieldValue.string(String("")))
    rg_power_prompt_simple.with_size(Vec2(410.0, 200.0))
    registry.register(rg_power_prompt_simple^)

    var rg_size = NodeTypeDef(
        String("comfy/Image or Latent Size (rgthree)"),
        String("rgthree Image or Latent Size"),
        String("rgthree"),
    )
    rg_size.with_input(String("input"), NVT_IMAGE)
    rg_size.with_output(String("WIDTH"), NVT_NUMBER)
    rg_size.with_output(String("HEIGHT"), NVT_NUMBER)
    rg_size.with_size(Vec2(315.0, 115.0))
    registry.register(rg_size^)

    var rg_resize = NodeTypeDef(
        String("comfy/Image Resize (rgthree)"),
        String("rgthree Image Resize"),
        String("rgthree"),
    )
    rg_resize.with_input(String("image"), NVT_IMAGE)
    rg_resize.with_output(String("IMAGE"), NVT_IMAGE)
    rg_resize.with_output(String("WIDTH"), NVT_NUMBER)
    rg_resize.with_output(String("HEIGHT"), NVT_NUMBER)
    rg_resize.with_field(String("measurement"), FieldValue.string(String("pixels")))
    rg_resize.with_field(String("width"), FieldValue.int_(Int64(1024)))
    rg_resize.with_field(String("height"), FieldValue.int_(Int64(1024)))
    rg_resize.with_field(String("fit"), FieldValue.string(String("contain")))
    rg_resize.with_field(String("method"), FieldValue.string(String("lanczos")))
    rg_resize.with_size(Vec2(360.0, 210.0))
    registry.register(rg_resize^)

    var kj_int = NodeTypeDef(
        String("comfy/INTConstant"),
        String("KJ INT Constant"),
        String("kj/constants"),
    )
    kj_int.with_output(String("INT"), NVT_NUMBER)
    kj_int.with_field(String("value"), FieldValue.int_(Int64(0)))
    kj_int.with_size(Vec2(240.0, 95.0))
    registry.register(kj_int^)

    var kj_float = NodeTypeDef(
        String("comfy/FloatConstant"),
        String("KJ Float Constant"),
        String("kj/constants"),
    )
    kj_float.with_output(String("FLOAT"), NVT_NUMBER)
    kj_float.with_field(String("value"), FieldValue.number(0.0))
    kj_float.with_size(Vec2(240.0, 95.0))
    registry.register(kj_float^)

    var kj_bool = NodeTypeDef(
        String("comfy/BOOLConstant"),
        String("KJ BOOL Constant"),
        String("kj/constants"),
    )
    kj_bool.with_output(String("BOOLEAN"), NVT_BOOL)
    kj_bool.with_field(String("value"), FieldValue.bool_(False))
    kj_bool.with_size(Vec2(240.0, 95.0))
    registry.register(kj_bool^)

    var kj_string = NodeTypeDef(
        String("comfy/StringConstant"),
        String("KJ String Constant"),
        String("kj/constants"),
    )
    kj_string.with_output(String("STRING"), NVT_TEXT)
    kj_string.with_field(String("string"), FieldValue.string(String("")))
    kj_string.with_size(Vec2(300.0, 125.0))
    registry.register(kj_string^)

    var kj_string_ml = NodeTypeDef(
        String("comfy/StringConstantMultiline"),
        String("KJ String Constant Multiline"),
        String("kj/constants"),
    )
    kj_string_ml.with_output(String("STRING"), NVT_TEXT)
    kj_string_ml.with_field(String("string"), FieldValue.string(String("")))
    kj_string_ml.with_size(Vec2(380.0, 210.0))
    registry.register(kj_string_ml^)

    var kj_join = NodeTypeDef(
        String("comfy/JoinStrings"),
        String("KJ Join Strings"),
        String("kj/text"),
    )
    kj_join.with_input(String("string_1"), NVT_TEXT)
    kj_join.with_input(String("string_2"), NVT_TEXT)
    kj_join.with_output(String("STRING"), NVT_TEXT)
    kj_join.with_field(String("delimiter"), FieldValue.string(String(" ")))
    kj_join.with_size(Vec2(330.0, 145.0))
    registry.register(kj_join^)

    var kj_cond_pass = NodeTypeDef(
        String("comfy/CondPassThrough"),
        String("KJ Conditioning Pass Through"),
        String("kj/misc"),
    )
    kj_cond_pass.with_input(String("positive"), NVT_CONDITIONING)
    kj_cond_pass.with_input(String("negative"), NVT_CONDITIONING)
    kj_cond_pass.with_output(String("positive"), NVT_CONDITIONING)
    kj_cond_pass.with_output(String("negative"), NVT_CONDITIONING)
    kj_cond_pass.with_size(Vec2(330.0, 130.0))
    registry.register(kj_cond_pass^)

    var kj_model_pass = NodeTypeDef(
        String("comfy/ModelPassThrough"),
        String("KJ Model Pass Through"),
        String("kj/misc"),
    )
    kj_model_pass.with_input(String("model"), NVT_MODEL)
    kj_model_pass.with_output(String("MODEL"), NVT_MODEL)
    kj_model_pass.with_size(Vec2(300.0, 105.0))
    registry.register(kj_model_pass^)

    var kj_latent_preset = NodeTypeDef(
        String("comfy/EmptyLatentImagePresets"),
        String("KJ Empty Latent Presets"),
        String("kj/latents"),
    )
    kj_latent_preset.with_output(String("LATENT"), NVT_LATENT)
    kj_latent_preset.with_output(String("width"), NVT_NUMBER)
    kj_latent_preset.with_output(String("height"), NVT_NUMBER)
    kj_latent_preset.with_field(String("width"), FieldValue.int_(Int64(1024)))
    kj_latent_preset.with_field(String("height"), FieldValue.int_(Int64(1024)))
    kj_latent_preset.with_field(String("batch_size"), FieldValue.int_(Int64(1)))
    kj_latent_preset.with_size(Vec2(330.0, 155.0))
    registry.register(kj_latent_preset^)

    var lanpaint_ksampler = NodeTypeDef(
        String("comfy/LanPaint_KSampler"),
        String("LanPaint KSampler"),
        String("lanpaint/sampling"),
    )
    lanpaint_ksampler.with_input(String("model"), NVT_MODEL)
    lanpaint_ksampler.with_input(String("positive"), NVT_CONDITIONING)
    lanpaint_ksampler.with_input(String("negative"), NVT_CONDITIONING)
    lanpaint_ksampler.with_input(String("latent_image"), NVT_LATENT)
    lanpaint_ksampler.with_output(String("LATENT"), NVT_LATENT)
    lanpaint_ksampler.with_field(String("seed"), FieldValue.int_(Int64(0)))
    lanpaint_ksampler.with_field(String("steps"), FieldValue.int_(Int64(20)))
    lanpaint_ksampler.with_field(String("cfg"), FieldValue.number(7.0))
    lanpaint_ksampler.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    lanpaint_ksampler.with_field(String("scheduler"), FieldValue.string(String("normal")))
    lanpaint_ksampler.with_field(String("denoise"), FieldValue.number(1.0))
    lanpaint_ksampler.with_field(String("LanPaint_NumSteps"), FieldValue.int_(Int64(5)))
    lanpaint_ksampler.with_field(String("LanPaint_PromptMode"), FieldValue.string(String("Image First")))
    lanpaint_ksampler.with_field(String("LanPaint_Info"), FieldValue.string(String("LanPaint KSampler.")))
    lanpaint_ksampler.with_field(String("Inpainting_mode"), FieldValue.string(String("Image Inpainting")))
    lanpaint_ksampler.with_size(Vec2(390.0, 572.0))
    registry.register(lanpaint_ksampler^)

    var lanpaint_ksampler_adv = NodeTypeDef(
        String("comfy/LanPaint_KSamplerAdvanced"),
        String("LanPaint KSampler Advanced"),
        String("lanpaint/sampling"),
    )
    lanpaint_ksampler_adv.with_input(String("model"), NVT_MODEL)
    lanpaint_ksampler_adv.with_input(String("positive"), NVT_CONDITIONING)
    lanpaint_ksampler_adv.with_input(String("negative"), NVT_CONDITIONING)
    lanpaint_ksampler_adv.with_input(String("latent_image"), NVT_LATENT)
    lanpaint_ksampler_adv.with_output(String("LATENT"), NVT_LATENT)
    lanpaint_ksampler_adv.with_field(String("add_noise"), FieldValue.string(String("enable")))
    lanpaint_ksampler_adv.with_field(String("noise_seed"), FieldValue.int_(Int64(0)))
    lanpaint_ksampler_adv.with_field(String("steps"), FieldValue.int_(Int64(30)))
    lanpaint_ksampler_adv.with_field(String("cfg"), FieldValue.number(5.0))
    lanpaint_ksampler_adv.with_field(String("sampler_name"), FieldValue.string(String("euler")))
    lanpaint_ksampler_adv.with_field(String("scheduler"), FieldValue.string(String("normal")))
    lanpaint_ksampler_adv.with_field(String("start_at_step"), FieldValue.int_(Int64(0)))
    lanpaint_ksampler_adv.with_field(String("end_at_step"), FieldValue.int_(Int64(10000)))
    lanpaint_ksampler_adv.with_field(String("return_with_leftover_noise"), FieldValue.string(String("disable")))
    lanpaint_ksampler_adv.with_field(String("LanPaint_NumSteps"), FieldValue.int_(Int64(5)))
    lanpaint_ksampler_adv.with_field(String("LanPaint_Lambda"), FieldValue.number(16.0))
    lanpaint_ksampler_adv.with_field(String("LanPaint_StepSize"), FieldValue.number(0.2))
    lanpaint_ksampler_adv.with_field(String("LanPaint_Beta"), FieldValue.number(1.0))
    lanpaint_ksampler_adv.with_field(String("LanPaint_Friction"), FieldValue.number(15.0))
    lanpaint_ksampler_adv.with_field(String("LanPaint_PromptMode"), FieldValue.string(String("Image First")))
    lanpaint_ksampler_adv.with_field(String("LanPaint_EarlyStop"), FieldValue.int_(Int64(1)))
    lanpaint_ksampler_adv.with_field(String("LanPaint_Info"), FieldValue.string(String("LanPaint KSampler Adv.")))
    lanpaint_ksampler_adv.with_field(String("Inpainting_mode"), FieldValue.string(String("Image Inpainting")))
    lanpaint_ksampler_adv.with_field(String("LanPaint_InnerThreshold"), FieldValue.number(0.0))
    lanpaint_ksampler_adv.with_field(String("LanPaint_InnerPatience"), FieldValue.int_(Int64(1)))
    lanpaint_ksampler_adv.with_size(Vec2(400.0, 620.0))
    registry.register(lanpaint_ksampler_adv^)

    var lanpaint_custom = NodeTypeDef(
        String("comfy/LanPaint_SamplerCustom"),
        String("LanPaint Sampler Custom"),
        String("lanpaint/sampling"),
    )
    lanpaint_custom.with_input(String("model"), NVT_MODEL)
    lanpaint_custom.with_input(String("positive"), NVT_CONDITIONING)
    lanpaint_custom.with_input(String("negative"), NVT_CONDITIONING)
    lanpaint_custom.with_input(String("sampler"), NVT_TEXT)
    lanpaint_custom.with_input(String("sigmas"), NVT_NUMBER)
    lanpaint_custom.with_input(String("latent_image"), NVT_LATENT)
    lanpaint_custom.with_output(String("output"), NVT_LATENT)
    lanpaint_custom.with_output(String("denoised_output"), NVT_LATENT)
    lanpaint_custom.with_field(String("add_noise"), FieldValue.bool_(True))
    lanpaint_custom.with_field(String("noise_seed"), FieldValue.int_(Int64(0)))
    lanpaint_custom.with_field(String("cfg"), FieldValue.number(8.0))
    lanpaint_custom.with_field(String("LanPaint_NumSteps"), FieldValue.int_(Int64(5)))
    lanpaint_custom.with_field(String("LanPaint_PromptMode"), FieldValue.string(String("Image First")))
    lanpaint_custom.with_field(String("LanPaint_Info"), FieldValue.string(String("LanPaint Custom Sampler.")))
    lanpaint_custom.with_size(Vec2(420.0, 360.0))
    registry.register(lanpaint_custom^)

    var lanpaint_custom_adv = NodeTypeDef(
        String("comfy/LanPaint_SamplerCustomAdvanced"),
        String("LanPaint Sampler Custom Advanced"),
        String("lanpaint/sampling"),
    )
    lanpaint_custom_adv.with_input(String("noise"), NVT_TEXT)
    lanpaint_custom_adv.with_input(String("guider"), NVT_TEXT)
    lanpaint_custom_adv.with_input(String("sampler"), NVT_TEXT)
    lanpaint_custom_adv.with_input(String("sigmas"), NVT_NUMBER)
    lanpaint_custom_adv.with_input(String("latent_image"), NVT_LATENT)
    lanpaint_custom_adv.with_output(String("output"), NVT_LATENT)
    lanpaint_custom_adv.with_output(String("denoised_output"), NVT_LATENT)
    lanpaint_custom_adv.with_field(String("LanPaint_NumSteps"), FieldValue.int_(Int64(5)))
    lanpaint_custom_adv.with_field(String("LanPaint_Lambda"), FieldValue.number(16.0))
    lanpaint_custom_adv.with_field(String("LanPaint_StepSize"), FieldValue.number(0.2))
    lanpaint_custom_adv.with_field(String("LanPaint_Beta"), FieldValue.number(1.0))
    lanpaint_custom_adv.with_field(String("LanPaint_Friction"), FieldValue.number(15.0))
    lanpaint_custom_adv.with_field(String("LanPaint_PromptMode"), FieldValue.string(String("Image First")))
    lanpaint_custom_adv.with_field(String("LanPaint_EarlyStop"), FieldValue.int_(Int64(1)))
    lanpaint_custom_adv.with_field(String("LanPaint_Info"), FieldValue.string(String("LanPaint Custom Sampler Adv.")))
    lanpaint_custom_adv.with_field(String("LanPaint_InnerThreshold"), FieldValue.number(0.0))
    lanpaint_custom_adv.with_field(String("LanPaint_InnerPatience"), FieldValue.int_(Int64(1)))
    lanpaint_custom_adv.with_size(Vec2(420.0, 420.0))
    registry.register(lanpaint_custom_adv^)

    var lanpaint_mask_blend = NodeTypeDef(
        String("comfy/LanPaint_MaskBlend"),
        String("LanPaint Mask Blend"),
        String("lanpaint/image"),
    )
    lanpaint_mask_blend.with_input(String("image1"), NVT_IMAGE)
    lanpaint_mask_blend.with_input(String("image2"), NVT_IMAGE)
    lanpaint_mask_blend.with_input(String("mask"), NVT_IMAGE)
    lanpaint_mask_blend.with_output(String("IMAGE"), NVT_IMAGE)
    lanpaint_mask_blend.with_field(String("blend_overlap"), FieldValue.int_(Int64(1)))
    lanpaint_mask_blend.with_size(Vec2(280.0, 135.0))
    registry.register(lanpaint_mask_blend^)

    _register_vhs_nodes(registry)


def _register_vhs_nodes(mut registry: NodeRegistry):
    var combine = NodeTypeDef(String("comfy/VHS_VideoCombine"), String("VHS Video Combine"), String("vhs"))
    combine.with_input(String("images"), NVT_IMAGE)
    combine.with_input(String("audio"), NVT_TEXT)
    combine.with_input(String("meta_batch"), NVT_TEXT)
    combine.with_input(String("vae"), NVT_VAE)
    combine.with_output(String("Filenames"), NVT_TEXT)
    combine.with_field(String("frame_rate"), FieldValue.number(8.0))
    combine.with_field(String("loop_count"), FieldValue.int_(Int64(0)))
    combine.with_field(String("filename_prefix"), FieldValue.string(String("AnimateDiff")))
    combine.with_field(String("format"), FieldValue.string(String("video/mp4")))
    combine.with_field(String("pingpong"), FieldValue.bool_(False))
    combine.with_field(String("save_output"), FieldValue.bool_(True))
    combine.with_size(Vec2(330.0, 255.0))
    registry.register(combine^)

    _register_vhs_load_video(registry, String("comfy/VHS_LoadVideo"), String("VHS Load Video"), False)
    _register_vhs_load_video(registry, String("comfy/VHS_LoadVideoPath"), String("VHS Load Video Path"), False)
    _register_vhs_load_video(registry, String("comfy/VHS_LoadVideoFFmpeg"), String("VHS Load Video FFmpeg"), True)
    _register_vhs_load_video(registry, String("comfy/VHS_LoadVideoFFmpegPath"), String("VHS Load Video FFmpeg Path"), True)

    var load_image = NodeTypeDef(String("comfy/VHS_LoadImagePath"), String("VHS Load Image Path"), String("vhs"))
    load_image.with_output(String("IMAGE"), NVT_IMAGE)
    load_image.with_output(String("mask"), NVT_IMAGE)
    load_image.with_field(String("image"), FieldValue.string(String("")))
    load_image.with_field(String("custom_width"), FieldValue.int_(Int64(0)))
    load_image.with_field(String("custom_height"), FieldValue.int_(Int64(0)))
    load_image.with_size(Vec2(320.0, 145.0))
    registry.register(load_image^)

    _register_vhs_load_images(registry, String("comfy/VHS_LoadImages"), String("VHS Load Images"))
    _register_vhs_load_images(registry, String("comfy/VHS_LoadImagesPath"), String("VHS Load Images Path"))

    var audio = NodeTypeDef(String("comfy/VHS_LoadAudio"), String("VHS Load Audio"), String("vhs/audio"))
    audio.with_output(String("audio"), NVT_TEXT)
    audio.with_output(String("duration"), NVT_NUMBER)
    audio.with_field(String("audio"), FieldValue.string(String("")))
    audio.with_size(Vec2(290.0, 110.0))
    registry.register(audio^)

    var audio_upload = NodeTypeDef(String("comfy/VHS_LoadAudioUpload"), String("VHS Load Audio Upload"), String("vhs/audio"))
    audio_upload.with_output(String("audio"), NVT_TEXT)
    audio_upload.with_output(String("duration"), NVT_NUMBER)
    audio_upload.with_field(String("audio"), FieldValue.string(String("")))
    audio_upload.with_size(Vec2(290.0, 110.0))
    registry.register(audio_upload^)

    var audio_to_vhs = NodeTypeDef(String("comfy/VHS_AudioToVHSAudio"), String("VHS Audio To Legacy Audio"), String("vhs/audio"))
    audio_to_vhs.with_input(String("audio"), NVT_TEXT)
    audio_to_vhs.with_output(String("audio"), NVT_TEXT)
    audio_to_vhs.with_size(Vec2(300.0, 95.0))
    registry.register(audio_to_vhs^)

    var vhs_to_audio = NodeTypeDef(String("comfy/VHS_VHSAudioToAudio"), String("VHS Legacy Audio To Audio"), String("vhs/audio"))
    vhs_to_audio.with_input(String("audio"), NVT_TEXT)
    vhs_to_audio.with_output(String("audio"), NVT_TEXT)
    vhs_to_audio.with_size(Vec2(300.0, 95.0))
    registry.register(vhs_to_audio^)

    var prune = NodeTypeDef(String("comfy/VHS_PruneOutputs"), String("VHS Prune Outputs"), String("vhs"))
    prune.with_field(String("filenames"), FieldValue.string(String("")))
    prune.with_size(Vec2(280.0, 90.0))
    registry.register(prune^)

    var batch = NodeTypeDef(String("comfy/VHS_BatchManager"), String("VHS Meta Batch Manager"), String("vhs"))
    batch.with_output(String("VHS_BatchManager"), NVT_TEXT)
    batch.with_field(String("frames_per_batch"), FieldValue.int_(Int64(0)))
    batch.with_size(Vec2(300.0, 105.0))
    registry.register(batch^)

    _register_vhs_video_info(registry, String("comfy/VHS_VideoInfo"), String("VHS Video Info"), True, True)
    _register_vhs_video_info(registry, String("comfy/VHS_VideoInfoSource"), String("VHS Video Info Source"), True, False)
    _register_vhs_video_info(registry, String("comfy/VHS_VideoInfoLoaded"), String("VHS Video Info Loaded"), False, True)

    var select_filename = NodeTypeDef(String("comfy/VHS_SelectFilename"), String("VHS Select Filename"), String("vhs"))
    select_filename.with_input(String("filenames"), NVT_TEXT)
    select_filename.with_output(String("Filename"), NVT_TEXT)
    select_filename.with_field(String("index"), FieldValue.int_(Int64(-1)))
    select_filename.with_size(Vec2(280.0, 115.0))
    registry.register(select_filename^)

    var select_latest = NodeTypeDef(String("comfy/VHS_SelectLatest"), String("VHS Select Latest"), String("vhs"))
    select_latest.with_output(String("Filename"), NVT_TEXT)
    select_latest.with_field(String("filename_prefix"), FieldValue.string(String("output/AnimateDiff")))
    select_latest.with_field(String("filename_postfix"), FieldValue.string(String(".webm")))
    select_latest.with_size(Vec2(300.0, 135.0))
    registry.register(select_latest^)

    _register_vhs_batched(registry, String("comfy/VHS_VAEEncodeBatched"), String("VHS VAE Encode Batched"), True)
    _register_vhs_batched(registry, String("comfy/VHS_VAEDecodeBatched"), String("VHS VAE Decode Batched"), False)

    _register_vhs_sequence_family(registry, String("Latents"), String("LATENT"), NVT_LATENT, String("latents"), String("vhs/latent"))
    _register_vhs_sequence_family(registry, String("Images"), String("IMAGE"), NVT_IMAGE, String("images"), String("vhs/image"))
    _register_vhs_sequence_family(registry, String("Masks"), String("MASK"), NVT_IMAGE, String("masks"), String("vhs/mask"))

    var unbatch = NodeTypeDef(String("comfy/VHS_Unbatch"), String("VHS Unbatch"), String("vhs"))
    unbatch.with_input(String("batched"), NVT_TEXT)
    unbatch.with_output(String("unbatched"), NVT_TEXT)
    unbatch.with_size(Vec2(260.0, 95.0))
    registry.register(unbatch^)


def _register_vhs_load_video(mut registry: NodeRegistry, type_id: String, display: String, with_mask: Bool):
    var td = NodeTypeDef(type_id, display, String("vhs"))
    td.with_output(String("IMAGE"), NVT_IMAGE)
    if with_mask:
        td.with_output(String("mask"), NVT_IMAGE)
    else:
        td.with_output(String("frame_count"), NVT_NUMBER)
    td.with_output(String("audio"), NVT_TEXT)
    td.with_output(String("video_info"), NVT_TEXT)
    td.with_field(String("video"), FieldValue.string(String("")))
    td.with_field(String("force_rate"), FieldValue.number(0.0))
    td.with_field(String("custom_width"), FieldValue.int_(Int64(0)))
    td.with_field(String("custom_height"), FieldValue.int_(Int64(0)))
    td.with_field(String("frame_load_cap"), FieldValue.int_(Int64(0)))
    td.with_field(String("skip_first_frames"), FieldValue.int_(Int64(0)))
    td.with_field(String("select_every_nth"), FieldValue.int_(Int64(1)))
    td.with_size(Vec2(330.0, 360.0))
    registry.register(td^)


def _register_vhs_load_images(mut registry: NodeRegistry, type_id: String, display: String):
    var td = NodeTypeDef(type_id, display, String("vhs"))
    td.with_output(String("IMAGE"), NVT_IMAGE)
    td.with_output(String("MASK"), NVT_IMAGE)
    td.with_output(String("frame_count"), NVT_NUMBER)
    td.with_field(String("directory"), FieldValue.string(String("")))
    td.with_field(String("image_load_cap"), FieldValue.int_(Int64(0)))
    td.with_field(String("skip_first_images"), FieldValue.int_(Int64(0)))
    td.with_field(String("select_every_nth"), FieldValue.int_(Int64(1)))
    td.with_size(Vec2(330.0, 195.0))
    registry.register(td^)


def _register_vhs_video_info(mut registry: NodeRegistry, type_id: String, display: String, source: Bool, loaded: Bool):
    var td = NodeTypeDef(type_id, display, String("vhs"))
    td.with_input(String("video_info"), NVT_TEXT)
    if source:
        td.with_output(String("source_fps"), NVT_NUMBER)
        td.with_output(String("source_frame_count"), NVT_NUMBER)
        td.with_output(String("source_duration"), NVT_NUMBER)
        td.with_output(String("source_width"), NVT_NUMBER)
        td.with_output(String("source_height"), NVT_NUMBER)
    if loaded:
        td.with_output(String("loaded_fps"), NVT_NUMBER)
        td.with_output(String("loaded_frame_count"), NVT_NUMBER)
        td.with_output(String("loaded_duration"), NVT_NUMBER)
        td.with_output(String("loaded_width"), NVT_NUMBER)
        td.with_output(String("loaded_height"), NVT_NUMBER)
    td.with_size(Vec2(330.0, 205.0))
    registry.register(td^)


def _register_vhs_batched(mut registry: NodeRegistry, type_id: String, display: String, encode: Bool):
    var td = NodeTypeDef(type_id, display, String("vhs/batched"))
    if encode:
        td.with_input(String("pixels"), NVT_IMAGE)
        td.with_input(String("vae"), NVT_VAE)
        td.with_output(String("LATENT"), NVT_LATENT)
    else:
        td.with_input(String("samples"), NVT_LATENT)
        td.with_input(String("vae"), NVT_VAE)
        td.with_output(String("IMAGE"), NVT_IMAGE)
    td.with_field(String("per_batch"), FieldValue.int_(Int64(16)))
    td.with_size(Vec2(310.0, 130.0))
    registry.register(td^)


def _register_vhs_sequence_family(
    mut registry: NodeRegistry,
    plural: String,
    output_name: String,
    value_type: Int32,
    input_name: String,
    category: String,
):
    var split = NodeTypeDef(String("comfy/VHS_Split") + plural, String("VHS Split ") + plural, category)
    split.with_input(input_name, value_type)
    split.with_output(output_name + String("_A"), value_type)
    split.with_output(String("A_count"), NVT_NUMBER)
    split.with_output(output_name + String("_B"), value_type)
    split.with_output(String("B_count"), NVT_NUMBER)
    split.with_field(String("split_index"), FieldValue.int_(Int64(0)))
    split.with_size(Vec2(315.0, 150.0))
    registry.register(split^)

    var merge = NodeTypeDef(String("comfy/VHS_Merge") + plural, String("VHS Merge ") + plural, category)
    merge.with_input(input_name + String("_A"), value_type)
    merge.with_input(input_name + String("_B"), value_type)
    merge.with_output(output_name, value_type)
    merge.with_output(String("count"), NVT_NUMBER)
    merge.with_field(String("merge_strategy"), FieldValue.string(String("match A")))
    merge.with_field(String("scale_method"), FieldValue.string(String("nearest-exact")))
    merge.with_field(String("crop"), FieldValue.string(String("disabled")))
    merge.with_size(Vec2(350.0, 180.0))
    registry.register(merge^)

    var count = NodeTypeDef(String("comfy/VHS_Get") + _singular(plural) + String("Count"), String("VHS Get ") + _singular(plural) + String(" Count"), category)
    count.with_input(input_name, value_type)
    count.with_output(String("count"), NVT_NUMBER)
    count.with_size(Vec2(280.0, 95.0))
    registry.register(count^)

    var duplicate = NodeTypeDef(String("comfy/VHS_Duplicate") + plural, String("VHS Duplicate ") + plural, category)
    duplicate.with_input(input_name, value_type)
    duplicate.with_output(output_name, value_type)
    duplicate.with_output(String("count"), NVT_NUMBER)
    duplicate.with_field(String("multiply_by"), FieldValue.int_(Int64(2)))
    duplicate.with_size(Vec2(315.0, 125.0))
    registry.register(duplicate^)

    var nth = NodeTypeDef(String("comfy/VHS_SelectEveryNth") + _singular(plural), String("VHS Select Every Nth ") + _singular(plural), category)
    nth.with_input(input_name, value_type)
    nth.with_output(output_name, value_type)
    nth.with_output(String("count"), NVT_NUMBER)
    nth.with_field(String("select_every_nth"), FieldValue.int_(Int64(1)))
    nth.with_size(Vec2(330.0, 125.0))
    registry.register(nth^)

    var select = NodeTypeDef(String("comfy/VHS_Select") + plural, String("VHS Select ") + plural, category)
    select.with_input(input_name, value_type)
    select.with_output(output_name, value_type)
    select.with_output(String("count"), NVT_NUMBER)
    select.with_field(String("indexes"), FieldValue.string(String("")))
    select.with_size(Vec2(330.0, 125.0))
    registry.register(select^)


def _singular(plural: String) -> String:
    if plural == String("Latents"):
        return String("Latent")
    if plural == String("Images"):
        return String("Image")
    if plural == String("Masks"):
        return String("Mask")
    return plural
