"""Smoke tests for mojoui.nodes.graph — Edge + Graph + topo_sort.

Covers the c36 builder contract:
  1. Empty graph: 0 nodes, 0 edges, topo_sort returns empty list.
  2. add_node: returns non-zero RetainedId, increments node count.
  3. add_edge: between 2 valid nodes returns True; with invalid endpoint
     returns False.
  4. remove_node: also removes connected edges.
  5. find_node: returns correct index, -1 for unknown.
  6. topo_sort linear: 3 nodes A→B→C → order is [A, B, C].
  7. topo_sort branched: A→B, A→C → A first, then B + C in declaration
     order (stable seed order).
  8. topo_sort cycle: A→B→A → raises Error.
  9. topo_sort disconnected: 2 components produce all nodes in declaration
     order.
  10. remove_edges_between exact match.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.graph import Graph, Edge, TopoSortError, topo_sort


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_empty_graph() raises:
    """Test 1: an empty graph has 0 nodes, 0 edges, and topo_sort returns
    an empty list (no raise).
    """
    var g = Graph()
    if g.node_count() != 0:
        _fail("empty graph node_count expected 0, got " + String(g.node_count()))
    if g.edge_count() != 0:
        _fail("empty graph edge_count expected 0, got " + String(g.edge_count()))
    var order = topo_sort(g)
    if len(order) != 0:
        _fail(
            "topo_sort on empty graph expected empty list, got "
            + String(len(order))
        )
    print("PASS: test_empty_graph (0/0/[])")


def test_add_node_returns_nonzero_id() raises:
    """Test 2: add_node returns a non-zero RetainedId and increments the
    node count. Multiple adds vend distinct ids.
    """
    var g = Graph()
    var id_a = g.add_node(String("core/load_checkpoint"), Vec2(10.0, 20.0))
    if id_a == RET_ID_NONE:
        _fail("add_node returned RET_ID_NONE (zero) — id should be non-zero")
    if g.node_count() != 1:
        _fail("after 1 add_node node_count expected 1, got " + String(g.node_count()))

    var id_b = g.add_node(String("core/k_sampler"), Vec2(200.0, 20.0))
    if id_b == RET_ID_NONE:
        _fail("second add_node returned RET_ID_NONE")
    if id_b == id_a:
        _fail("two add_node calls vended the same id")
    if g.node_count() != 2:
        _fail("after 2 add_node node_count expected 2, got " + String(g.node_count()))

    print("PASS: test_add_node_returns_nonzero_id (2 distinct non-zero ids)")


def test_add_edge_valid_and_invalid() raises:
    """Test 3: add_edge between two existing nodes returns True; with
    either endpoint unknown returns False.
    """
    var g = Graph()
    var id_a = g.add_node(String("core/load_checkpoint"), Vec2(0.0, 0.0))
    var id_b = g.add_node(String("core/k_sampler"), Vec2(0.0, 0.0))

    var ok = g.add_edge(id_a, String("model"), id_b, String("model"))
    if not ok:
        _fail("add_edge between two valid nodes expected True, got False")
    if g.edge_count() != 1:
        _fail("after 1 add_edge edge_count expected 1, got " + String(g.edge_count()))

    # Invalid from_node.
    var bad_id: RetainedId = 999999
    var bad1 = g.add_edge(bad_id, String("x"), id_b, String("model"))
    if bad1:
        _fail("add_edge with unknown from_node expected False, got True")
    if g.edge_count() != 1:
        _fail("after invalid add_edge edge_count expected 1, got " + String(g.edge_count()))

    # Invalid to_node.
    var bad2 = g.add_edge(id_a, String("model"), bad_id, String("x"))
    if bad2:
        _fail("add_edge with unknown to_node expected False, got True")
    if g.edge_count() != 1:
        _fail("after invalid add_edge edge_count expected 1, got " + String(g.edge_count()))

    print("PASS: test_add_edge_valid_and_invalid (1 ok + 2 rejected)")


def test_remove_node_cascades_edges() raises:
    """Test 4: remove_node also removes every edge connected to that node
    (both incoming and outgoing).
    """
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    var id_c = g.add_node(String("c"), Vec2.zero())

    # A → B, A → C, B → C. Removing B should drop the two B-touching edges
    # (A→B and B→C) but leave A→C alone.
    _ = g.add_edge(id_a, String("o"), id_b, String("i"))
    _ = g.add_edge(id_a, String("o"), id_c, String("i"))
    _ = g.add_edge(id_b, String("o"), id_c, String("i"))
    if g.edge_count() != 3:
        _fail("after 3 add_edge edge_count expected 3, got " + String(g.edge_count()))

    g.remove_node(id_b)

    if g.node_count() != 2:
        _fail("after remove_node node_count expected 2, got " + String(g.node_count()))
    if g.edge_count() != 1:
        _fail(
            "after remove_node edge_count expected 1 (only A→C remains), got "
            + String(g.edge_count())
        )
    # Verify the surviving edge is A → C.
    var surviving_from = g.edges[0].from_node
    var surviving_to = g.edges[0].to_node
    if surviving_from != id_a or surviving_to != id_c:
        _fail("surviving edge expected A→C, got different endpoints")

    print("PASS: test_remove_node_cascades_edges (B dropped + 2 edges cascaded)")


def test_find_node_index_and_missing() raises:
    """Test 5: find_node returns the correct list index for a known id,
    -1 for an unknown id.
    """
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    var id_c = g.add_node(String("c"), Vec2.zero())

    if g.find_node(id_a) != 0:
        _fail("find_node(id_a) expected 0, got " + String(g.find_node(id_a)))
    if g.find_node(id_b) != 1:
        _fail("find_node(id_b) expected 1, got " + String(g.find_node(id_b)))
    if g.find_node(id_c) != 2:
        _fail("find_node(id_c) expected 2, got " + String(g.find_node(id_c)))

    var bad_id: RetainedId = 999999
    if g.find_node(bad_id) != -1:
        _fail("find_node(unknown) expected -1, got " + String(g.find_node(bad_id)))
    if g.find_node(RET_ID_NONE) != -1:
        _fail(
            "find_node(RET_ID_NONE) expected -1, got "
            + String(g.find_node(RET_ID_NONE))
        )

    print("PASS: test_find_node_index_and_missing (3 hits + 2 misses)")


def test_topo_sort_linear() raises:
    """Test 6: A → B → C topological sort produces [A, B, C]."""
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    var id_c = g.add_node(String("c"), Vec2.zero())
    _ = g.add_edge(id_a, String("o"), id_b, String("i"))
    _ = g.add_edge(id_b, String("o"), id_c, String("i"))

    var order = topo_sort(g)
    if len(order) != 3:
        _fail("linear topo_sort expected len 3, got " + String(len(order)))
    if order[0] != id_a:
        _fail("linear topo_sort [0] expected A")
    if order[1] != id_b:
        _fail("linear topo_sort [1] expected B")
    if order[2] != id_c:
        _fail("linear topo_sort [2] expected C")

    print("PASS: test_topo_sort_linear (A→B→C → [A,B,C])")


def test_topo_sort_branched_stable_seed_order() raises:
    """Test 7: A → B, A → C. A must come first; B and C follow in
    declaration order (B before C, since B was added first). This is the
    stable-seed-order invariant from EriGui's runtime cache.
    """
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    var id_c = g.add_node(String("c"), Vec2.zero())
    _ = g.add_edge(id_a, String("o"), id_b, String("i"))
    _ = g.add_edge(id_a, String("o"), id_c, String("i"))

    var order = topo_sort(g)
    if len(order) != 3:
        _fail("branched topo_sort expected len 3, got " + String(len(order)))
    if order[0] != id_a:
        _fail("branched topo_sort [0] expected A (only zero-in-degree root)")
    # B and C both have in-degree 1; once A pops, both go to in-degree 0.
    # Stable seed order means B (declared first) comes before C.
    if order[1] != id_b:
        _fail("branched topo_sort [1] expected B (declaration order tiebreaker)")
    if order[2] != id_c:
        _fail("branched topo_sort [2] expected C")

    print("PASS: test_topo_sort_branched_stable_seed_order (A first, B before C)")


def test_topo_sort_cycle_raises() raises:
    """Test 8: a 2-cycle A → B → A raises Error (cycle detected)."""
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    _ = g.add_edge(id_a, String("o"), id_b, String("i"))
    _ = g.add_edge(id_b, String("o"), id_a, String("i"))

    var raised = False
    try:
        var _order = topo_sort(g)
        # If we reach here, no raise — that's a failure.
    except e:
        raised = True

    if not raised:
        _fail("topo_sort on cycle expected raise Error, none raised")

    print("PASS: test_topo_sort_cycle_raises (A→B→A → raise)")


def test_topo_sort_disconnected_components() raises:
    """Test 9: two disconnected components (A→B, plus standalone C, D)
    produce all 4 nodes in declaration order. Since A, C, D all have
    in-degree 0 initially, the seed queue is [A, C, D]; B follows when
    A pops.
    """
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    var id_c = g.add_node(String("c"), Vec2.zero())
    var id_d = g.add_node(String("d"), Vec2.zero())
    _ = g.add_edge(id_a, String("o"), id_b, String("i"))

    var order = topo_sort(g)
    if len(order) != 4:
        _fail("disconnected topo_sort expected len 4, got " + String(len(order)))

    # Seed queue is [A, C, D] (in declaration order, all zero in-degree).
    # Pop A → enqueue B (decrement). Pop C → nothing. Pop D → nothing.
    # Pop B → empty. Final order: A, C, D, B.
    if order[0] != id_a:
        _fail("disconnected topo_sort [0] expected A")
    if order[1] != id_c:
        _fail("disconnected topo_sort [1] expected C (seed order after A)")
    if order[2] != id_d:
        _fail("disconnected topo_sort [2] expected D")
    if order[3] != id_b:
        _fail("disconnected topo_sort [3] expected B (last after A pops)")

    print("PASS: test_topo_sort_disconnected_components (4 nodes, stable order)")


def test_remove_edges_between_exact_match() raises:
    """Test 10: remove_edges_between drops the matching edge (and only the
    matching edge). A near-miss on any of the four fields leaves the edge
    intact.
    """
    var g = Graph()
    var id_a = g.add_node(String("a"), Vec2.zero())
    var id_b = g.add_node(String("b"), Vec2.zero())
    _ = g.add_edge(id_a, String("out1"), id_b, String("in1"))
    _ = g.add_edge(id_a, String("out2"), id_b, String("in2"))
    if g.edge_count() != 2:
        _fail("setup expected 2 edges, got " + String(g.edge_count()))

    # Near-miss: wrong from_port.
    g.remove_edges_between(id_a, String("WRONG"), id_b, String("in1"))
    if g.edge_count() != 2:
        _fail(
            "near-miss remove_edges_between expected 2 edges left, got "
            + String(g.edge_count())
        )

    # Exact match on the first edge.
    g.remove_edges_between(id_a, String("out1"), id_b, String("in1"))
    if g.edge_count() != 1:
        _fail(
            "exact match remove_edges_between expected 1 edge left, got "
            + String(g.edge_count())
        )
    # The surviving edge must be out2 → in2.
    if g.edges[0].from_port != String("out2"):
        _fail("surviving edge from_port expected 'out2', got '" + g.edges[0].from_port + "'")
    if g.edges[0].to_port != String("in2"):
        _fail("surviving edge to_port expected 'in2', got '" + g.edges[0].to_port + "'")

    print("PASS: test_remove_edges_between_exact_match (near-miss kept, exact removed)")


def main() raises:
    test_empty_graph()
    test_add_node_returns_nonzero_id()
    test_add_edge_valid_and_invalid()
    test_remove_node_cascades_edges()
    test_find_node_index_and_missing()
    test_topo_sort_linear()
    test_topo_sort_branched_stable_seed_order()
    test_topo_sort_cycle_raises()
    test_topo_sort_disconnected_components()
    test_remove_edges_between_exact_match()
    print("PASS: all 10 smoke tests")
