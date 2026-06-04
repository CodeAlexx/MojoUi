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
    seed the 5 starter typedefs.

The 5 starter builtins registered by `register_builtins` mirror ComfyUI's
core nodes for parity testing:

  - `core/load_checkpoint` → outputs model/clip/vae; field `path` (string).
  - `core/encode_prompt` → input clip, output cond; field `text` (string).
  - `core/k_sampler` → inputs model/cond/uncond/latent, output latent;
    fields cfg (number), steps (int), seed (int), sampler (string).
  - `core/vae_decode` → inputs vae/latent, output image.
  - `core/save_image` → input image; field `path` (string).

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
# register_builtins — convenience starter set mirroring ComfyUI core nodes
# ============================================================================


def register_builtins(mut registry: NodeRegistry):
    """Register a starter set of 5 typedefs matching ComfyUI's core nodes.

    Apps may either:
      - Call this then add/override via `registry.register(...)`.
      - Skip it entirely and register a custom set.

    The 5 builtins are stable across MojoUI versions (the type_ids end up
    in saved workflow JSON); evolving the field/port shapes within a
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

    # core/save_image — terminal sink: image → file.
    var si = NodeTypeDef(
        String("core/save_image"),
        String("Save Image"),
        String("image"),
    )
    si.with_input(String("image"), NVT_IMAGE)
    si.with_field(String("path"), FieldValue.string(String("out.png")))
    registry.register(si^)
