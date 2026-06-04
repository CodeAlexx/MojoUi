"""Port + NodeValueType — typed input/output sockets on a Node.

Mirrors EriGui's two-enum split (see AUDIT_erigui_nodes.md "Socket / Port Type
System"): `NodeValueType` is the schema/connect-time tag used to validate that
two ports are type-compatible BEFORE a wire is committed. The runtime
`NodeValue` (which carries the actual tensor / handle / arch-tag) is a separate
construct that lands later in M2.5.

Design invariants from `AUDIT_erigui_nodes.md`:
  - **Port identity by NAME, not index.** Adding or reordering ports in a node
    schema must not silently reroute saved workflows; the canonical stable
    identifier is the port's `name` string. The serialised workflow stores
    `{ "node": <id>, "port": "<name>" }`, never positional indices.
  - **Connect-time type checking is tag-only.** `ports_compatible(a, b)`
    returns True iff `a.value_type == b.value_type` AND the directions are
    opposite (one input, one output). The deeper `ArchTag` mismatch (e.g.
    Klein model into a ZImage sampler) is a *runtime* error inside the
    executor, NOT a canvas-time error.

`NodeValueType` is an `Int32`-backed compile-time-tagged enum (current beta
Mojo lacks `@value enum`; we follow the c11/c14 convention of `comptime
NAME: T = N` constants over `Int32` instead). The eleven variants mirror
EriGui's `NodeValueType` (`erigui-nodes/src/lib.rs:70-78`):

  - **Diffusion-domain types** (7): LATENT, IMAGE, CONDITIONING, MODEL, VAE,
    CLIP, LORA.
  - **Generic primitives** (4): NUMBER, TEXT, SEED, BOOL.

`NVT_COUNT` (= 11) is the sentinel returned by `node_value_type_from_name`
for an unknown name string — callers should treat it as the "unrecognised
type" error case.

Per MOJO_NOTES.md "Confirmed in M1 chunk 11 (core/id.mojo)": `alias TypeName
= T` is deprecated in current beta, replaced by `comptime TypeName = T`.
Used here for the `NodeValueType` type-alias declaration and every per-
variant value constant.
"""


comptime NodeValueType = Int32

# Diffusion-domain types (mirror EriGui erigui-nodes/src/lib.rs:70-78).
comptime NVT_LATENT: NodeValueType = 0
comptime NVT_IMAGE: NodeValueType = 1
comptime NVT_CONDITIONING: NodeValueType = 2
comptime NVT_MODEL: NodeValueType = 3
comptime NVT_VAE: NodeValueType = 4
comptime NVT_CLIP: NodeValueType = 5
comptime NVT_LORA: NodeValueType = 6

# Generic primitives.
comptime NVT_NUMBER: NodeValueType = 7
comptime NVT_TEXT: NodeValueType = 8
comptime NVT_SEED: NodeValueType = 9
comptime NVT_BOOL: NodeValueType = 10

# Sentinel — one past the last valid variant. Returned by
# `node_value_type_from_name` for an unrecognised name string. Also used by
# tests to assert the variant set is exactly 11 entries wide.
comptime NVT_COUNT: NodeValueType = 11


def node_value_type_name(t: NodeValueType) -> String:
    """Returns the canonical lowercase string name used for JSON serde.

    The 11 strings here MUST stay stable across MojoUI versions — they end up
    in workflow files on disk, and changing a name silently breaks every saved
    graph that referenced the old spelling. Mirrors EriGui's
    `serde(rename_all = "snake_case")` derivation on `NodeValueType` so a
    MojoUI workflow file is byte-for-byte interchangeable with an EriGui one
    for the type-tag portion.

    For an out-of-range `t` returns the string "unknown" (no raise — callers
    treat it as a soft error and emit a diagnostic).
    """
    if t == NVT_LATENT:
        return String("latent")
    elif t == NVT_IMAGE:
        return String("image")
    elif t == NVT_CONDITIONING:
        return String("conditioning")
    elif t == NVT_MODEL:
        return String("model")
    elif t == NVT_VAE:
        return String("vae")
    elif t == NVT_CLIP:
        return String("clip")
    elif t == NVT_LORA:
        return String("lora")
    elif t == NVT_NUMBER:
        return String("number")
    elif t == NVT_TEXT:
        return String("text")
    elif t == NVT_SEED:
        return String("seed")
    elif t == NVT_BOOL:
        return String("bool")
    return String("unknown")


def node_value_type_from_name(name: String) -> NodeValueType:
    """Inverse of `node_value_type_name`. Returns `NVT_COUNT` (11) for any
    unrecognised name — callers treat that as the "unknown type" sentinel.
    """
    if name == String("latent"):
        return NVT_LATENT
    elif name == String("image"):
        return NVT_IMAGE
    elif name == String("conditioning"):
        return NVT_CONDITIONING
    elif name == String("model"):
        return NVT_MODEL
    elif name == String("vae"):
        return NVT_VAE
    elif name == String("clip"):
        return NVT_CLIP
    elif name == String("lora"):
        return NVT_LORA
    elif name == String("number"):
        return NVT_NUMBER
    elif name == String("text"):
        return NVT_TEXT
    elif name == String("seed"):
        return NVT_SEED
    elif name == String("bool"):
        return NVT_BOOL
    return NVT_COUNT


struct Port(Copyable, Movable, Writable):
    """A single typed input or output socket on a Node.

    Fields:
      - `name`: stable port identifier — workflow JSON references this by
        string, NEVER by positional index (EriGui invariant; see file
        docstring + `AUDIT_erigui_nodes.md` "Port identity by name, not
        index").
      - `value_type`: the `NodeValueType` tag — used for connect-time
        compatibility checking via `ports_compatible`.
      - `is_input`: True for input sockets (left side of a node in the
        visual editor), False for output sockets (right side). Two ports
        with matching `value_type` can connect only if their `is_input`
        flags are opposite.

    Conforms to `Copyable, Movable, Writable` so it can live in
    `List[Port]` (per `Node.inputs` / `Node.outputs` in chunk 32) and so
    that `String(port)` / `print(port)` produce a human-readable summary.
    Auto-derived `__copyinit__` per c32/c33 wall — the compiler synthesizes
    a field-wise copy that calls each field's own copy semantics (including
    `String.copy()` for `name`). No explicit `__copyinit__` is defined.
    """

    var name: String
    var value_type: NodeValueType
    var is_input: Bool

    def __init__(out self, name: String, value_type: NodeValueType, is_input: Bool):
        self.name = name.copy()
        self.value_type = value_type
        self.is_input = is_input

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "Port(name='",
            self.name,
            "', type=",
            node_value_type_name(self.value_type),
            ", input=",
            self.is_input,
            ")",
        )


def ports_compatible(a: Port, b: Port) -> Bool:
    """Connect-time type check: returns True iff `a` and `b` share the same
    `value_type` AND have opposite directions (one input, one output).

    Two inputs cannot connect to each other; two outputs cannot connect to
    each other. The deeper arch-tag mismatch (Klein vs ZImage, etc.) is a
    runtime error reported by the executor, NOT a canvas-time error — this
    function intentionally only checks the connect-time tag.
    """
    if a.value_type != b.value_type:
        return False
    return a.is_input != b.is_input
