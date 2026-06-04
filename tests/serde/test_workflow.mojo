"""Smoke tests for `mojoui/serde/workflow.mojo` (M2.5 c41).

Coverage:
  (1)  Empty graph emit/parse round-trip: 0 nodes / 0 edges preserved.
  (2)  Single-node round-trip: id / type_id / position preserved.
  (3)  Node with fields (string + number + bool): preserved across r-trip.
  (4)  Multi-node linear chain (3 nodes, 2 edges) — port names preserved.
  (5)  Emit contains the `"version":1` substring.
  (6)  Parse rejects `version: 2` with UnsupportedVersion.
  (7)  Parse rejects malformed JSON.
  (8)  Byte-equivalent round-trip: emit(parse(emit(g))) == emit(g).
  (9)  FieldValue round-trip across all 4 kinds (note INT collapses to
       NUMBER per the JSON number-type limitation).
  (10) Empty fields dict round-trips as the empty object `{}`.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId
from mojoui.nodes.node import (
    Node,
    FieldValue,
    FK_NONE,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
)
from mojoui.nodes.graph import Graph
from mojoui.serde.workflow import (
    emit_workflow,
    parse_workflow,
    field_value_to_json,
    field_value_from_json,
)


def _contains(haystack: String, needle: String) -> Bool:
    """Naive byte-substring check; only used to spot-check JSON output."""
    var hn = haystack.byte_length()
    var nn = needle.byte_length()
    if nn == 0:
        return True
    if nn > hn:
        return False
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return True
    return False


def test_empty_graph_round_trip() raises:
    var g = Graph()
    var json = emit_workflow(g)
    var g2 = parse_workflow(json)
    if g2.node_count() != 0:
        raise Error("empty graph round-trip: expected 0 nodes, got " + String(g2.node_count()))
    if g2.edge_count() != 0:
        raise Error("empty graph round-trip: expected 0 edges, got " + String(g2.edge_count()))


def test_single_node_round_trip() raises:
    var g = Graph()
    var nid = g.add_node(String("core/load_checkpoint"), Vec2(40.0, 80.0))
    var json = emit_workflow(g)
    var g2 = parse_workflow(json)
    if g2.node_count() != 1:
        raise Error("single-node: expected 1 node, got " + String(g2.node_count()))
    if g2.edge_count() != 0:
        raise Error("single-node: expected 0 edges, got " + String(g2.edge_count()))
    if g2.nodes[0].id != nid:
        raise Error("single-node: id mismatch")
    if g2.nodes[0].type_id != String("core/load_checkpoint"):
        raise Error("single-node: type_id mismatch, got '" + g2.nodes[0].type_id + "'")
    var p = g2.nodes[0].position.copy()
    if p.x != 40.0 or p.y != 80.0:
        raise Error("single-node: position mismatch")


def test_node_with_fields_round_trip() raises:
    var g = Graph()
    var _nid = g.add_node(String("core/k_sampler"), Vec2(0.0, 0.0))
    g.nodes[0].set_field(String("sampler"), FieldValue.string(String("euler")))
    g.nodes[0].set_field(String("cfg"), FieldValue.number(7.5))
    g.nodes[0].set_field(String("use_karras"), FieldValue.bool_(True))
    var json = emit_workflow(g)
    var g2 = parse_workflow(json)
    if g2.node_count() != 1:
        raise Error("fields: expected 1 node")
    if g2.nodes[0].field_count() != 3:
        raise Error("fields: expected 3 fields, got " + String(g2.nodes[0].field_count()))
    var sampler = g2.nodes[0].get_field(String("sampler"))
    if sampler.kind != FK_STRING or sampler.str_val != String("euler"):
        raise Error("fields: sampler mismatch")
    var cfg = g2.nodes[0].get_field(String("cfg"))
    if cfg.kind != FK_NUMBER or cfg.num_val != 7.5:
        raise Error("fields: cfg mismatch (kind=" + String(cfg.kind) + " val=" + String(cfg.num_val) + ")")
    var uk = g2.nodes[0].get_field(String("use_karras"))
    if uk.kind != FK_BOOL or uk.bool_val != True:
        raise Error("fields: use_karras mismatch")


def test_multi_node_edges_round_trip() raises:
    var g = Graph()
    var a = g.add_node(String("core/load_checkpoint"), Vec2(0.0, 0.0))
    var b = g.add_node(String("core/k_sampler"), Vec2(100.0, 0.0))
    var c = g.add_node(String("core/vae_decode"), Vec2(200.0, 0.0))
    var ok1 = g.add_edge(a, String("model"), b, String("model"))
    var ok2 = g.add_edge(b, String("latent"), c, String("latent"))
    if not ok1 or not ok2:
        raise Error("multi-node setup: add_edge failed")

    var json = emit_workflow(g)
    var g2 = parse_workflow(json)
    if g2.node_count() != 3:
        raise Error("multi-node: expected 3 nodes, got " + String(g2.node_count()))
    if g2.edge_count() != 2:
        raise Error("multi-node: expected 2 edges, got " + String(g2.edge_count()))

    # Port identity by NAME — verify both edges' port strings survived.
    var e0 = g2.edges[0].copy()
    var e1 = g2.edges[1].copy()
    if e0.from_port != String("model") or e0.to_port != String("model"):
        raise Error("multi-node: edge 0 port names corrupted")
    if e1.from_port != String("latent") or e1.to_port != String("latent"):
        raise Error("multi-node: edge 1 port names corrupted")
    if e0.from_node != a or e0.to_node != b:
        raise Error("multi-node: edge 0 endpoints corrupted")
    if e1.from_node != b or e1.to_node != c:
        raise Error("multi-node: edge 1 endpoints corrupted")


def test_emit_contains_version_one() raises:
    var g = Graph()
    var json = emit_workflow(g)
    # Version emits as the integer fast-path in c34 — `"version":1` not
    # `"version":1.0`.
    if not _contains(json, String("\"version\":1")):
        raise Error("emit_contains_version: expected substring '\"version\":1' in: " + json)


def test_parse_rejects_v2() raises:
    # Synthesise a v=2 workflow JSON (we can't emit it because emit uses
    # SUPPORTED). Hand-roll the smallest possible v2 payload.
    var v2_json = String("{\"version\":2,\"nodes\":[],\"edges\":[]}")
    var raised = False
    try:
        var _g = parse_workflow(v2_json)
    except e:
        raised = True
    if not raised:
        raise Error("parse_rejects_v2: expected UnsupportedVersion raise")


def test_parse_rejects_malformed() raises:
    var raised = False
    try:
        var _g = parse_workflow(String("{not json}"))
    except e:
        raised = True
    if not raised:
        raise Error("parse_rejects_malformed: expected raise on malformed JSON")


def test_round_trip_byte_equivalence() raises:
    """Verify byte-equivalent round-trip: `emit(parse(emit(g))) == emit(g)`.

    Both emits sort keys, so the bytes match exactly. Verifies the
    sort-on-emit invariant survives the round trip.
    """
    var g = Graph()
    var a = g.add_node(String("core/load_checkpoint"), Vec2(40.0, 80.0))
    var b = g.add_node(String("core/k_sampler"), Vec2(240.0, 80.0))
    g.nodes[0].set_field(String("path"), FieldValue.string(String("models/foo.safetensors")))
    g.nodes[1].set_field(String("cfg"), FieldValue.number(7.5))
    g.nodes[1].set_field(String("steps"), FieldValue.number(30.0))
    g.nodes[1].set_field(String("sampler"), FieldValue.string(String("euler")))
    var _ok = g.add_edge(a, String("model"), b, String("model"))

    var first = emit_workflow(g)
    var g2 = parse_workflow(first)
    var second = emit_workflow(g2)
    if first != second:
        raise Error(
            "byte_equivalence: first=" + first + "\nsecond=" + second
        )


def test_field_value_round_trip_all_kinds() raises:
    # FK_NONE -> JSON null -> FK_NONE
    var none = FieldValue()
    var none2 = field_value_from_json(field_value_to_json(none))
    if none2.kind != FK_NONE:
        raise Error("field_value: NONE round-trip kind mismatch")

    # FK_NUMBER -> JSON number -> FK_NUMBER (3.14)
    var num = FieldValue.number(3.14)
    var num2 = field_value_from_json(field_value_to_json(num))
    if num2.kind != FK_NUMBER or num2.num_val != 3.14:
        raise Error("field_value: NUMBER round-trip mismatch")

    # FK_STRING -> JSON string -> FK_STRING ("hi")
    var s = FieldValue.string(String("hi"))
    var s2 = field_value_from_json(field_value_to_json(s))
    if s2.kind != FK_STRING or s2.str_val != String("hi"):
        raise Error("field_value: STRING round-trip mismatch")

    # FK_BOOL -> JSON bool -> FK_BOOL
    var t = FieldValue.bool_(True)
    var t2 = field_value_from_json(field_value_to_json(t))
    if t2.kind != FK_BOOL or t2.bool_val != True:
        raise Error("field_value: BOOL True round-trip mismatch")
    var fbool = FieldValue.bool_(False)
    var fbool2 = field_value_from_json(field_value_to_json(fbool))
    if fbool2.kind != FK_BOOL or fbool2.bool_val != False:
        raise Error("field_value: BOOL False round-trip mismatch")

    # FK_INT -> JSON number -> FK_NUMBER (documented collapse — JSON has
    # only one "number" type). Numeric value is preserved.
    var i = FieldValue.int_(42)
    var i2 = field_value_from_json(field_value_to_json(i))
    if i2.kind != FK_NUMBER:
        raise Error("field_value: INT->JSON->NUMBER expected (kind=" + String(i2.kind) + ")")
    if i2.num_val != 42.0:
        raise Error("field_value: INT round-trip value mismatch (got " + String(i2.num_val) + ")")


def test_empty_fields_dict_round_trip() raises:
    var g = Graph()
    var _nid = g.add_node(String("core/k_sampler"), Vec2(0.0, 0.0))
    # Default Node has an empty fields dict — verified by c32 tests.
    if g.nodes[0].field_count() != 0:
        raise Error("setup: node should start with 0 fields")

    var json = emit_workflow(g)
    # Empty object emits as `"fields":{}` after the alphabetical sort.
    if not _contains(json, String("\"fields\":{}")):
        raise Error("empty_fields: expected substring '\"fields\":{}' in: " + json)

    var g2 = parse_workflow(json)
    if g2.nodes[0].field_count() != 0:
        raise Error("empty_fields: round-trip should preserve 0 fields, got " + String(g2.nodes[0].field_count()))


def test_parse_rejects_v99_in_large_workflow() raises:
    """Regression for M2.5 skeptic BLOCKER #1.

    `emit_json` sorts top-level keys alphabetically — `edges < nodes <
    version` — so `"version"` is emitted LAST for any workflow JSON. The
    pre-fix `peek_version` scanned only the first 512 bytes; a v=99 buried
    past that window was silently accepted, defeating the peek-before-parse
    gate.

    This test builds a workflow large enough that the (alphabetically-last)
    `"version"` literal lands well past byte 512, then hand-rolls the
    equivalent JSON with `"version":99` and asserts `parse_workflow` raises.
    """
    # Build a Graph with 6 nodes carrying padded type ids — c42's demo shape
    # emits ~1311 bytes; we go a bit further to be unambiguous.
    var g = Graph()
    for i in range(6):
        var _id = g.add_node(
            String("test/foo_with_a_long_type_id_string_to_pad_the_json"),
            Vec2(Float32(i) * 100.0, 0.0),
        )
        g.nodes[i].set_field(
            String("seed_long_name_field"),
            FieldValue.string(String("a-fairly-long-string-value-here")),
        )

    var v1_json = emit_workflow(g)
    if v1_json.byte_length() <= 512:
        raise Error(
            "v99-large setup: emit too small to exercise the scan ("
            + String(v1_json.byte_length())
            + " bytes)"
        )

    # Find the trailing `"version":1` and rewrite it to `"version":99`.
    # The alphabetical sort guarantees this literal lives near the end.
    var v1_marker = String("\"version\":1")
    if not _contains(v1_json, v1_marker):
        raise Error(
            "v99-large setup: emit_workflow did not contain '\"version\":1'"
        )
    # Hand-build the v=99 variant by replacing `"version":1` with
    # `"version":99` at the unique occurrence near the tail.
    var v99_json = String("")
    var hp = v1_json.unsafe_ptr()
    var n = v1_json.byte_length()
    var marker_len = v1_marker.byte_length()
    var mp = v1_marker.unsafe_ptr()
    var pos = 0
    var matched_once = False
    while pos < n:
        var match_here = False
        if pos + marker_len <= n and not matched_once:
            match_here = True
            for j in range(marker_len):
                if hp[pos + j] != mp[j]:
                    match_here = False
                    break
            # Require the next byte to be NOT a digit (so we match the
            # literal `1`, not the start of `10`, `12`, etc.).
            if match_here and pos + marker_len < n:
                var next_b = Int(hp[pos + marker_len])
                if next_b >= 0x30 and next_b <= 0x39:
                    match_here = False
        if match_here:
            v99_json = v99_json + String("\"version\":99")
            pos = pos + marker_len
            matched_once = True
        else:
            # Append one byte. Build a tiny single-byte String via a list.
            var buf = List[UInt8](capacity=1)
            buf.append(hp[pos])
            v99_json = v99_json + String(unsafe_from_utf8=buf)
            pos = pos + 1

    if v99_json.byte_length() <= 512:
        raise Error(
            "v99-large: rewritten JSON unexpectedly small ("
            + String(v99_json.byte_length())
            + " bytes)"
        )
    if not _contains(v99_json, String("\"version\":99")):
        raise Error("v99-large: rewrite failed to embed version:99")

    var raised = False
    try:
        var _g = parse_workflow(v99_json)
    except e:
        raised = True
    if not raised:
        raise Error(
            "BLOCKER regression: v=99 in a "
            + String(v99_json.byte_length())
            + "-byte workflow was silently accepted"
        )


def test_parse_seeds_id_alloc_past_loaded_ids() raises:
    """Regression for M2.5 skeptic FRAGILE #3.

    `parse_workflow` previously left `Graph.id_alloc.next_index` at the
    fresh-constructor default (1). A `graph.add_node()` AFTER load would
    then collide with any parsed node whose slot index was also 1.

    Chosen behavior: seed `next_index = max(parsed_node.idx) + 1` (no gap
    recycling — that's M3). Verify a subsequent `add_node` returns a fresh
    id that does NOT match any loaded id.
    """
    # Build a graph with two nodes (assigned ids idx=1, idx=2 by the
    # fresh allocator), serialize, and re-parse.
    var g = Graph()
    var id_a = g.add_node(String("test/a"), Vec2(0.0, 0.0))
    var id_b = g.add_node(String("test/b"), Vec2(0.0, 0.0))
    var json = emit_workflow(g)
    var g2 = parse_workflow(json)
    if g2.node_count() != 2:
        raise Error("setup: expected 2 nodes after parse, got " + String(g2.node_count()))

    # Now allocate a third node. It must NOT collide with id_a or id_b.
    var id_c = g2.add_node(String("test/c"), Vec2(0.0, 0.0))
    if id_c == id_a or id_c == id_b:
        raise Error(
            "FRAGILE #3 regression: post-parse add_node collided with"
            " loaded id (got "
            + String(id_c)
            + ", existing="
            + String(id_a)
            + ","
            + String(id_b)
            + ")"
        )
    # The allocator seeds past the high-water mark — id_c's slot index
    # must be strictly greater than the max loaded slot index.
    var mask = UInt64(0x0000FFFFFFFFFFFF)
    var idx_a = UInt64(id_a) & mask
    var idx_b = UInt64(id_b) & mask
    var idx_c = UInt64(id_c) & mask
    var max_loaded = idx_a if idx_a > idx_b else idx_b
    if idx_c <= max_loaded:
        raise Error(
            "FRAGILE #3 regression: post-parse alloc slot idx ("
            + String(idx_c)
            + ") not greater than max loaded ("
            + String(max_loaded)
            + ")"
        )


def main() raises:
    test_empty_graph_round_trip()
    test_single_node_round_trip()
    test_node_with_fields_round_trip()
    test_multi_node_edges_round_trip()
    test_emit_contains_version_one()
    test_parse_rejects_v2()
    test_parse_rejects_malformed()
    test_round_trip_byte_equivalence()
    test_field_value_round_trip_all_kinds()
    test_empty_fields_dict_round_trip()
    test_parse_rejects_v99_in_large_workflow()
    test_parse_seeds_id_alloc_past_loaded_ids()
    print("PASS: all 12 workflow smoke tests")
