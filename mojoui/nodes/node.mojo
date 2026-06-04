"""Serializable visual node — pure data, no behavior.

Mirrors the EriGui visual node (`erigui-widgets/src/node_graph/mod.rs:61-71`).
Per `EriGui node audit notes`, the visual `Node` is plain serializable data; the
behavior lives in a registry (`NodeTypeDef` tagged union — chunk 37) and is
joined to the visual node by its `type_id` string at execute time.

This module ships THREE structs:

1. `FieldValue` — generic value carrier for node parameters. Tagged union of
   `Float64` / `String` / `Bool` / `Int64` (+ a `FK_NONE` sentinel). Mirrors
   `serde_json::Value` in EriGui's `Field { value: serde_json::Value }`.
2. `PortRef` — lightweight node-local port descriptor `{ name, value_type }`.
   The FULL `Port` struct (with id, direction, label) lives in c33
   (`port.mojo`); for c32 we use a minimal stub so node.mojo compiles
   standalone. **Design choice (b)**: define `PortRef` here for loose
   coupling to c33's `Port`. `Graph` (c36) bridges between Node.PortRef and
   c33's `Port` at runtime. This means changing `Port`'s storage layout in
   c33 does NOT force a re-build of node.mojo.
3. `Node` — `{ id, type_id, title, position, size, inputs, outputs, fields }`.
   No methods beyond `__init__`, `__copyinit__`, and the chainable mutator
   `with_position`. All behavior lives elsewhere (registry / canvas / graph).

**Port-by-name invariant** (EriGui top lesson #1): the `name` field of
`PortRef` IS the stable identifier across saves. Ports are never identified
by index in the serialized graph — adding or reordering ports in a node
implementation must not silently reroute saved workflows.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId, RET_ID_NONE


# ============================================================================
# FieldValue — generic value carrier for node parameters
# ============================================================================

comptime FieldKind = Int32

comptime FK_NONE: FieldKind = 0
"""Sentinel — no value set. The default-constructed FieldValue."""

comptime FK_NUMBER: FieldKind = 1
"""Float64 value (Rust `serde_json::Value::Number`). Use for floats like
`cfg`, `denoise_strength`, etc."""

comptime FK_STRING: FieldKind = 2
"""String value. Use for paths, sampler names, scheduler names, etc."""

comptime FK_BOOL: FieldKind = 3
"""Bool value. Use for toggles like `use_karras`, `enable_lora`, etc."""

comptime FK_INT: FieldKind = 4
"""Int64 value. Use for integer params like seeds, step counts."""


struct FieldValue(Copyable, Movable, Writable):
    """Tagged union: `{ FK_NONE, Float64, String, Bool, Int64 }`.

    Storage is "fat" — every field is held even when not in use. Acceptable
    for a node graph (typically <50 fields per node, <20 nodes per graph).
    The registry (c37) and serde (c34/c39) inspect `kind` before reading the
    matching `*_val` slot.

    Mirrors `Field.value: serde_json::Value` from EriGui's
    `erigui-widgets/src/node_graph/mod.rs:87-101`.
    """

    var kind: FieldKind
    """One of `FK_NONE/NUMBER/STRING/BOOL/INT`."""

    var num_val: Float64
    """Live only when `kind == FK_NUMBER`."""

    var str_val: String
    """Live only when `kind == FK_STRING`. Always present (default `""`) to
    keep `Copyable+Movable` trivial."""

    var bool_val: Bool
    """Live only when `kind == FK_BOOL`."""

    var int_val: Int64
    """Live only when `kind == FK_INT`."""

    def __init__(out self):
        """Default — `FK_NONE` with all slots zeroed."""
        self.kind = FK_NONE
        self.num_val = 0.0
        self.str_val = String("")
        self.bool_val = False
        self.int_val = 0

    @staticmethod
    def number(v: Float64) -> FieldValue:
        """Construct a `FK_NUMBER` FieldValue."""
        var fv = FieldValue()
        fv.kind = FK_NUMBER
        fv.num_val = v
        return fv^

    @staticmethod
    def string(v: String) -> FieldValue:
        """Construct a `FK_STRING` FieldValue."""
        var fv = FieldValue()
        fv.kind = FK_STRING
        fv.str_val = v.copy()
        return fv^

    @staticmethod
    def bool_(v: Bool) -> FieldValue:
        """Construct a `FK_BOOL` FieldValue (trailing underscore avoids the
        `bool` builtin)."""
        var fv = FieldValue()
        fv.kind = FK_BOOL
        fv.bool_val = v
        return fv^

    @staticmethod
    def int_(v: Int64) -> FieldValue:
        """Construct a `FK_INT` FieldValue (trailing underscore avoids the
        `int` builtin)."""
        var fv = FieldValue()
        fv.kind = FK_INT
        fv.int_val = v
        return fv^

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == FK_NUMBER:
            writer.write(self.num_val)
        elif self.kind == FK_STRING:
            writer.write("\"", self.str_val, "\"")
        elif self.kind == FK_BOOL:
            writer.write(self.bool_val)
        elif self.kind == FK_INT:
            writer.write(self.int_val)
        else:
            writer.write("null")


# ============================================================================
# PortRef — node-local port descriptor (stub; full Port in c33)
# ============================================================================


struct PortRef(Copyable, Movable, Writable):
    """Lightweight port descriptor stored inside Node.inputs/outputs.

    `name` is the STABLE identifier (per EriGui invariant — ports are
    referenced by name, never by index, in saved workflows). `value_type` is
    a tag whose values match c33's `NodeValueType` enum (Latent=1, Image=2,
    Conditioning=3, ...). Stored as `Int32` to avoid a hard dependency on c33;
    `Graph`/`NodeRegistry` (c36/c37) translates between this and c33's enum.

    For c32 the actual numeric values are caller-supplied; the registry
    chunk pins them.
    """

    var name: String
    """Port name (stable across saves — port-by-name invariant)."""

    var value_type: Int32
    """Tag matching c33 `NodeValueType` (e.g. Latent=1). Caller-supplied for
    now; the c37 registry pins the values."""

    def __init__(out self, name: String, value_type: Int32):
        self.name = name.copy()
        self.value_type = value_type

    def write_to(self, mut writer: Some[Writer]):
        writer.write("PortRef(", self.name, ", value_type=", self.value_type, ")")


# ============================================================================
# Node — serializable visual node (pure data)
# ============================================================================


comptime _DEFAULT_NODE_W: Float32 = 200.0
comptime _DEFAULT_NODE_H: Float32 = 80.0


struct Node(Copyable, Movable):
    """Visual / serializable node. Pure data, no behavior.

    Behavior lives in the c37 `NodeTypeDef` registry; the join key is
    `type_id`. This struct mirrors EriGui's `Node` from
    `erigui-widgets/src/node_graph/mod.rs:61-71`.
    """

    var id: RetainedId
    """Stable retained-mode id (allocated by `RetainedIdAllocator` per c11).
    Survives save/load via the Workflow JSON serde (c34/c39)."""

    var type_id: String
    """Category/name (e.g. `"core/k_sampler"`) for c37 registry lookup."""

    var title: String
    """Display title; may differ from `type_id` (e.g. localized). Defaults
    to `type_id` if not overridden."""

    var position: Vec2
    """Canvas-world position (top-left corner). Float to match Vec2."""

    var size: Vec2
    """Visual size (width, height). Defaults to 200×80."""

    var inputs: List[PortRef]
    """Input port descriptors. Order is presentation-only; identity is by
    `name` (EriGui invariant)."""

    var outputs: List[PortRef]
    """Output port descriptors. Same invariant as `inputs`."""

    var fields: Dict[String, FieldValue]
    """Parameter values keyed by field name. EriGui serialises this as a
    sorted-key JSON object so saved workflows are VCS-diff stable (c34
    enforces sort)."""

    def __init__(out self, id: RetainedId, type_id: String):
        """Construct with id + type_id. Title defaults to `type_id`,
        position to origin, size to 200×80, ports/fields empty.
        """
        self.id = id
        self.type_id = type_id.copy()
        self.title = type_id.copy()
        self.position = Vec2.zero()
        self.size = Vec2(_DEFAULT_NODE_W, _DEFAULT_NODE_H)
        self.inputs = List[PortRef]()
        self.outputs = List[PortRef]()
        self.fields = Dict[String, FieldValue]()

    def with_position(mut self, pos: Vec2):
        """Mutator — set the canvas position."""
        self.position = pos.copy()

    def with_size(mut self, size: Vec2):
        """Mutator — override the default 200×80 size."""
        self.size = size.copy()

    def with_title(mut self, title: String):
        """Mutator — override the title (default = type_id)."""
        self.title = title.copy()

    def add_input(mut self, port: PortRef):
        """Append an input port descriptor."""
        self.inputs.append(port.copy())

    def add_output(mut self, port: PortRef):
        """Append an output port descriptor."""
        self.outputs.append(port.copy())

    def set_field(mut self, name: String, value: FieldValue):
        """Insert or replace a parameter value by name."""
        self.fields[name.copy()] = value.copy()

    def get_field(self, name: String) raises -> FieldValue:
        """Look up a parameter value by name. Raises if absent.

        Use `has_field` first if absence is expected.
        """
        return self.fields[name].copy()

    def has_field(self, name: String) -> Bool:
        """True iff a field with this name has been set."""
        return name in self.fields

    def field_count(self) -> Int:
        """Number of fields set."""
        return len(self.fields)
