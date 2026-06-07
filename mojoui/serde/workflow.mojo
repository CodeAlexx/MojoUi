"""Workflow serialization — `Graph` ↔ JSON round-trip (M2.5 capstone).

The capstone of the M2.5 serde stack. Builds on:

- `mojoui/serde/version.mojo` (c35) — peek-before-parse schema gate;
- `mojoui/serde/json.mojo` (c34) — JsonValue + `emit_json`/`parse_json` (with
  alphabetical key sort enforced at emit);
- `mojoui/nodes/node.mojo` (c32) — `Node` + `FieldValue`;
- `mojoui/nodes/graph.mojo` (c36) — `Graph` + `Edge`.

The on-disk JSON format mirrors EriGui's wire shape verbatim (see
`internal audit notes` §"Serde Schema"):

```json
{
  "version": 1,
  "nodes": [
    {
      "id": 1,
      "type_id": "core/load_checkpoint",
      "title": "Load Checkpoint",
      "position": {"x": 40.0, "y": 80.0},
      "fields": {"path": "/models/foo.safetensors"}
    }
  ],
  "edges": [
    {"from": {"node": 1, "port": "model"},
     "to":   {"node": 7, "port": "model"}}
  ]
}
```

EriGui invariants mirrored:

1. **Port identity by NAME, not index** — `edge.from.port` / `edge.to.port`
   are strings. Adding or reordering ports in a node implementation never
   silently reroutes saved workflows (load-bearing top lesson #1).
2. **Peek-before-parse version gate** — `parse_workflow` runs c35's
   `peek_version` BEFORE the full `parse_json`, so a v1 loader sees a v2
   file and raises `UnsupportedVersion` cleanly instead of failing mid-
   stream after constructing half a graph.
3. **Alphabetically-sorted object keys** — `JsonValue.set_object_field`
   stores insertion-ordered, `emit_json` sorts on emit (c34). The result
   is byte-stable: `emit(parse(emit(g))) == emit(g)` for any graph.
4. **No `\\uXXXX` / NaN / Infinity / comments / trailing commas** — same
   subset as c34's parser. Full Unicode escape is M3.

M2.5 SCOPE — deliberately deferred:

- ComfyUI-API execution-payload format (the sidecar `ui` block that lays
  out z-order, theme, viewport zoom etc. for the canvas widget). M3.
- Migration / upgrade logic between schema versions. Version mismatch is
  a hard error for M2.5; the v1 → v2 migration ships alongside the v2
  schema change itself, not here.
- File I/O — `emit_workflow` returns `String`, `parse_workflow` takes
  `String`. The caller decides whether to `sys_pread`/`sys_pwrite` it,
  embed it in a larger document, or hold it in memory.

`FieldValue` round-trip note: JSON has only "number", not int-vs-float, so
`FK_INT` collapses into a JSON number on emit AND comes back as
`FK_NUMBER` after parse. Applications that need to recover int-vs-float
distinction should re-type fields per the node's registry schema after
load. This matches EriGui's behavior (`fields` is `serde_json::Value`,
which has the same int-vs-float collapse).
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.node import (
    Node,
    PortRef,
    FieldValue,
    FK_NONE,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
)
from mojoui.nodes.port import (
    NVT_COUNT,
    node_value_type_name,
    node_value_type_from_name,
)
from mojoui.nodes.graph import Graph, Edge
from mojoui.serde.json import (
    JsonValue,
    JK_NULL,
    JK_BOOL,
    JK_NUMBER,
    JK_STRING,
    JK_ARRAY,
    JK_OBJECT,
    emit_json,
    parse_json,
)
from mojoui.serde.version import SUPPORTED_WORKFLOW_VERSION, peek_version


# ============================================================================
# emit — Graph → JSON String
# ============================================================================


def emit_workflow(graph: Graph) raises -> String:
    """Serialize `graph` into the workflow JSON format.

    Object keys are sorted alphabetically at emit (c34 invariant — VCS
    diff stability). `FK_INT` field values are emitted as JSON numbers
    (the JSON "number" type has no int-vs-float distinction).

    Declared `raises` because the `node.fields[key]` Dict access raises on
    missing key in current beta (c37 finding); in practice the lookup is
    guaranteed-present because we just enumerated the keys from
    `fields.keys()`, but the `raises` is a compiler-satisfaction tax.
    """
    var root = JsonValue.empty_object()
    root.set_object_field(String("version"), JsonValue.number_i(Int(SUPPORTED_WORKFLOW_VERSION)))

    # Nodes array.
    var nodes_array = List[JsonValue]()
    var nn = graph.node_count()
    for ni in range(nn):
        var n_obj = JsonValue.empty_object()
        var node_id = graph.nodes[ni].id
        # RetainedId is UInt64; Float64 holds integers up to 2^53 exactly,
        # which is well above any plausible graph size.
        n_obj.set_object_field(String("id"), JsonValue.number(Float64(node_id)))
        n_obj.set_object_field(String("type_id"), JsonValue.string(graph.nodes[ni].type_id))
        n_obj.set_object_field(String("title"), JsonValue.string(graph.nodes[ni].title))

        var pos_obj = JsonValue.empty_object()
        pos_obj.set_object_field(String("x"), JsonValue.number(Float64(graph.nodes[ni].position.x)))
        pos_obj.set_object_field(String("y"), JsonValue.number(Float64(graph.nodes[ni].position.y)))
        n_obj.set_object_field(String("position"), pos_obj)

        var size_obj = JsonValue.empty_object()
        size_obj.set_object_field(String("x"), JsonValue.number(Float64(graph.nodes[ni].size.x)))
        size_obj.set_object_field(String("y"), JsonValue.number(Float64(graph.nodes[ni].size.y)))
        n_obj.set_object_field(String("size"), size_obj)

        n_obj.set_object_field(String("inputs"), _ports_to_json(graph.nodes[ni].inputs))
        n_obj.set_object_field(String("outputs"), _ports_to_json(graph.nodes[ni].outputs))

        # Fields dict → JSON object. The c37 Dict-aliasing wall requires us
        # to materialize the keys into a List[String] first, then index by
        # integer position, rather than iterating `for k in d.keys():` and
        # passing `k` back into `d[k]` in the same expression.
        var fields_obj = JsonValue.empty_object()
        var field_keys = List[String]()
        for k in graph.nodes[ni].fields.keys():
            field_keys.append(k.copy())
        var nf = len(field_keys)
        for fi in range(nf):
            var key = field_keys[fi].copy()
            var fv = graph.nodes[ni].fields[key].copy()
            fields_obj.set_object_field(key, field_value_to_json(fv))
        n_obj.set_object_field(String("fields"), fields_obj)

        nodes_array.append(n_obj^)
    root.set_object_field(String("nodes"), JsonValue.array(nodes_array))

    # Edges array.
    var edges_array = List[JsonValue]()
    var ne = graph.edge_count()
    for ei in range(ne):
        var e_obj = JsonValue.empty_object()
        var from_obj = JsonValue.empty_object()
        from_obj.set_object_field(String("node"), JsonValue.number(Float64(graph.edges[ei].from_node)))
        from_obj.set_object_field(String("port"), JsonValue.string(graph.edges[ei].from_port))
        var to_obj = JsonValue.empty_object()
        to_obj.set_object_field(String("node"), JsonValue.number(Float64(graph.edges[ei].to_node)))
        to_obj.set_object_field(String("port"), JsonValue.string(graph.edges[ei].to_port))
        e_obj.set_object_field(String("from"), from_obj)
        e_obj.set_object_field(String("to"), to_obj)
        edges_array.append(e_obj^)
    root.set_object_field(String("edges"), JsonValue.array(edges_array))

    return emit_json(root)


# ============================================================================
# parse — JSON String → Graph (with version gate)
# ============================================================================


def parse_workflow(raw: String) raises -> Graph:
    """Parse a workflow JSON into a fresh `Graph`. Verifies the schema
    version FIRST via c35's `peek_version` before invoking the full c34
    JSON parser — a v1 loader rejects a v2 file cleanly via
    `UnsupportedVersion` rather than failing mid-stream.

    Raises:
        Error("UnsupportedVersion: ...") when `version` is found but not
            equal to `SUPPORTED_WORKFLOW_VERSION`.
        Error from `parse_json` for malformed JSON.
        Error("workflow JSON root must be an object") for non-object roots.
    """
    var peeked = peek_version(raw)
    if peeked.found and peeked.version != SUPPORTED_WORKFLOW_VERSION:
        raise Error(
            "UnsupportedVersion: found="
            + String(peeked.version)
            + " supported="
            + String(SUPPORTED_WORKFLOW_VERSION)
        )

    var root = parse_json(raw)
    if root.kind != JK_OBJECT:
        raise Error("workflow JSON root must be an object")

    var graph = Graph()

    # Nodes.
    var nodes_arr = root.get_object_field(String("nodes"))
    if nodes_arr.kind == JK_ARRAY:
        var nn = len(nodes_arr.arr_val)
        for ni in range(nn):
            var n_val = nodes_arr.arr_val[ni].copy()
            var node = _parse_node(n_val)
            graph.nodes.append(node^)

    # Seed the id allocator past the high-water mark of any parsed node id
    # so a subsequent `graph.add_node()` cannot collide with a loaded node.
    # (M2.5 skeptic FRAGILE #3.) `RetainedId` is `(gen << 48) | idx`; we mask
    # off the generation bits to recover the slot index, take the max + 1,
    # and seed `id_alloc.next_index`. Free list stays empty — M3 can add
    # proper compaction (recovering unused slot indices below the max).
    var nn_seed = len(graph.nodes)
    if nn_seed > 0:
        var max_idx: UInt64 = 0
        for ni in range(nn_seed):
            var idx = UInt64(graph.nodes[ni].id) & UInt64(0x0000FFFFFFFFFFFF)
            if idx > max_idx:
                max_idx = idx
        graph.id_alloc.next_index = max_idx + UInt64(1)
        # `generations` table must be sized so `generations[idx - 1]` is
        # in-bounds for every parsed id and for every future alloc. The
        # allocator's `alloc()` reads `self.generations[Int(idx) - 1]`
        # after extending; pre-populate one entry per slot up to max_idx
        # so existing parsed ids' generations don't fault on later lookups.
        while UInt64(len(graph.id_alloc.generations)) < max_idx:
            graph.id_alloc.generations.append(UInt16(0))

    # Edges.
    var edges_arr = root.get_object_field(String("edges"))
    if edges_arr.kind == JK_ARRAY:
        var ne = len(edges_arr.arr_val)
        for ei in range(ne):
            var e_val = edges_arr.arr_val[ei].copy()
            var edge = _parse_edge(e_val)
            graph.edges.append(edge^)

    return graph^


def _parse_node(n_val: JsonValue) raises -> Node:
    """Construct a Node from a JsonValue object. Raises on missing/
    malformed required fields (`id`, `type_id`)."""
    if n_val.kind != JK_OBJECT:
        raise Error("workflow node must be an object")

    var id_val = n_val.get_object_field(String("id"))
    if id_val.kind != JK_NUMBER:
        raise Error("workflow node.id must be a number")
    var id = RetainedId(Int(id_val.num_val))

    var type_id_val = n_val.get_object_field(String("type_id"))
    var type_id = String("")
    if type_id_val.kind == JK_STRING:
        type_id = type_id_val.str_val.copy()

    var node = Node(id, type_id)

    var title_val = n_val.get_object_field(String("title"))
    if title_val.kind == JK_STRING:
        node.title = title_val.str_val.copy()

    var pos_val = n_val.get_object_field(String("position"))
    if pos_val.kind == JK_OBJECT:
        var x_val = pos_val.get_object_field(String("x"))
        var y_val = pos_val.get_object_field(String("y"))
        var px: Float32 = 0.0
        var py: Float32 = 0.0
        if x_val.kind == JK_NUMBER:
            px = Float32(x_val.num_val)
        if y_val.kind == JK_NUMBER:
            py = Float32(y_val.num_val)
        node.position = Vec2(px, py)

    var size_val = n_val.get_object_field(String("size"))
    if size_val.kind == JK_OBJECT:
        var w_val = size_val.get_object_field(String("x"))
        var h_val = size_val.get_object_field(String("y"))
        var sx = node.size.x
        var sy = node.size.y
        if w_val.kind == JK_NUMBER:
            sx = Float32(w_val.num_val)
        if h_val.kind == JK_NUMBER:
            sy = Float32(h_val.num_val)
        node.size = Vec2(sx, sy)

    var fields_val = n_val.get_object_field(String("fields"))
    if fields_val.kind == JK_OBJECT:
        var nk = len(fields_val.obj_keys)
        for fi in range(nk):
            var key = fields_val.obj_keys[fi].copy()
            var val = fields_val.obj_values[fi].copy()
            var fv = field_value_from_json(val)
            node.fields[key] = fv^

    _parse_port_refs(node, n_val.get_object_field(String("inputs")), True)
    _parse_port_refs(node, n_val.get_object_field(String("outputs")), False)

    return node^


def _ports_to_json(ports: List[PortRef]) -> JsonValue:
    var ports_array = List[JsonValue]()
    for pi in range(len(ports)):
        var p_obj = JsonValue.empty_object()
        p_obj.set_object_field(String("name"), JsonValue.string(ports[pi].name))
        p_obj.set_object_field(
            String("type"),
            JsonValue.string(node_value_type_name(ports[pi].value_type)),
        )
        p_obj.set_object_field(
            String("value_type"),
            JsonValue.number_i(Int(ports[pi].value_type)),
        )
        ports_array.append(p_obj^)
    return JsonValue.array(ports_array)


def _parse_port_refs(mut node: Node, ports_val: JsonValue, is_input: Bool):
    if ports_val.kind != JK_ARRAY:
        return
    for pi in range(len(ports_val.arr_val)):
        var p_val = ports_val.arr_val[pi].copy()
        if p_val.kind != JK_OBJECT:
            continue
        var fallback = String("input_") + String(pi)
        if not is_input:
            fallback = String("output_") + String(pi)

        var name = fallback.copy()
        var name_val = p_val.get_object_field(String("name"))
        if name_val.kind == JK_STRING:
            name = name_val.str_val.copy()

        var value_type = NVT_COUNT
        var value_type_val = p_val.get_object_field(String("value_type"))
        if value_type_val.kind == JK_NUMBER:
            value_type = Int32(Int(value_type_val.num_val))
        else:
            var type_val = p_val.get_object_field(String("type"))
            if type_val.kind == JK_STRING:
                value_type = node_value_type_from_name(type_val.str_val)

        var port = PortRef(name, value_type)
        if is_input:
            node.add_input(port)
        else:
            node.add_output(port)


def _parse_edge(e_val: JsonValue) raises -> Edge:
    """Construct an Edge from a JsonValue object. Raises on missing/
    malformed `from`/`to`/`node`/`port` fields."""
    if e_val.kind != JK_OBJECT:
        raise Error("workflow edge must be an object")

    var from_val = e_val.get_object_field(String("from"))
    var to_val = e_val.get_object_field(String("to"))
    if from_val.kind != JK_OBJECT or to_val.kind != JK_OBJECT:
        raise Error("workflow edge endpoints must be objects")

    var from_node_val = from_val.get_object_field(String("node"))
    var from_port_val = from_val.get_object_field(String("port"))
    var to_node_val = to_val.get_object_field(String("node"))
    var to_port_val = to_val.get_object_field(String("port"))

    if from_node_val.kind != JK_NUMBER or to_node_val.kind != JK_NUMBER:
        raise Error("workflow edge node must be a number")
    if from_port_val.kind != JK_STRING or to_port_val.kind != JK_STRING:
        raise Error("workflow edge port must be a string")

    return Edge(
        RetainedId(Int(from_node_val.num_val)),
        from_port_val.str_val,
        RetainedId(Int(to_node_val.num_val)),
        to_port_val.str_val,
    )


# ============================================================================
# FieldValue <-> JsonValue translation
# ============================================================================


def field_value_to_json(fv: FieldValue) -> JsonValue:
    """Encode a FieldValue as a JsonValue. `FK_INT` collapses to a JSON
    number; `FK_NONE` collapses to `null`."""
    if fv.kind == FK_NUMBER:
        return JsonValue.number(fv.num_val)
    elif fv.kind == FK_STRING:
        return JsonValue.string(fv.str_val)
    elif fv.kind == FK_BOOL:
        return JsonValue.bool_(fv.bool_val)
    elif fv.kind == FK_INT:
        # JSON has only one "number" type — int vs float distinction is
        # lost on round-trip. Applications that need to recover int can
        # re-type after load via the c37 NodeRegistry schema.
        return JsonValue.number(Float64(fv.int_val))
    return JsonValue.null()


def field_value_from_json(jv: JsonValue) -> FieldValue:
    """Decode a JsonValue into a FieldValue. `null` collapses to
    `FK_NONE`; numbers always come back as `FK_NUMBER` (the JSON `number`
    type has no int-vs-float distinction)."""
    if jv.kind == JK_NUMBER:
        return FieldValue.number(jv.num_val)
    elif jv.kind == JK_STRING:
        return FieldValue.string(jv.str_val)
    elif jv.kind == JK_BOOL:
        return FieldValue.bool_(jv.bool_val)
    # JK_NULL or any other (JK_ARRAY / JK_OBJECT not modelled by FieldValue):
    # collapse to FK_NONE. Applications that need rich nested values would
    # extend FieldValue (out of scope for M2.5).
    return FieldValue()
