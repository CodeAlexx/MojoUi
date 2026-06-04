"""Graph — container of Nodes + Edges with topological sort.

The retained data model that the immediate-mode `NodeCanvas` widget (c39)
will operate on. Mirrors EriGui's `Graph` from
`erigui-widgets/src/node_graph/mod.rs:81-85` (plain `Vec<Node>+Vec<Edge>`
backing store; O(n) linear scan, no `slotmap` / `petgraph` dependency).

Three structs:

1. **`Edge`** — `{ from_node, from_port, to_node, to_port }`. Ports are
   identified by NAME, not index (the load-bearing EriGui invariant —
   `EriGui node audit notes` "Connection / Edge Model"). Adding/reordering
   ports must not silently reroute saved workflows.

2. **`Graph`** — `{ nodes, edges, id_alloc }`. Movable-only (not Copyable
   — copying would clone the id allocator and vend overlapping ids).

3. **`TopoSortError`** — companion struct carrying `sorted/total` counts
   for callers that catch the raise and want structured diagnostic info.

Plus free function **`topo_sort(graph) raises -> List[RetainedId]`** —
Kahn's algorithm (mirrors `erigui-runtime/src/topo.rs`). Returns nodes in
execution order; raises `Error` on cycle. **Stable seed order**: zero-
in-degree nodes enter the queue in `graph.nodes` declaration order, giving
deterministic output across hash-randomization runs (EriGui's content-hash
cache invariant — a non-deterministic topo sort would torpedo cache hits
on every cosmetic reorder).

**Deferred to later chunks**:
  - Port-type compatibility on `add_edge` — c39 (canvas widget, via c33's
    `ports_compatible` + c37's `NodeRegistry`). The storage layer just
    records the wire.
  - Serde — c41 `workflow.mojo` builds on top.
  - O(1) lookup via `Dict[RetainedId, Int]` index — graphs are small.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId, RET_ID_NONE, RetainedIdAllocator
from mojoui.nodes.node import Node


# ============================================================================
# Edge
# ============================================================================


struct Edge(Copyable, Movable):
    """One connection between an output of `from_node` and an input of
    `to_node`. Ports identified by NAME (EriGui invariant). No explicit
    `__copyinit__` per Mojo implementation notes c32/c33 — auto-derived handles the
    two String fields correctly via each field's own `.copy()`.
    """

    var from_node: RetainedId
    var from_port: String
    var to_node: RetainedId
    var to_port: String

    def __init__(
        out self,
        from_node: RetainedId,
        from_port: String,
        to_node: RetainedId,
        to_port: String,
    ):
        self.from_node = from_node
        self.from_port = from_port.copy()
        self.to_node = to_node
        self.to_port = to_port.copy()


# ============================================================================
# Graph
# ============================================================================


struct Graph(Movable):
    """Container of Nodes + Edges. Owns a `RetainedIdAllocator` so ids
    survive save/load. `Movable` only — copying would clone the allocator
    and vend overlapping ids; callers that need an independent graph
    should round-trip via c41 `workflow.mojo` serde.
    """

    var nodes: List[Node]
    var edges: List[Edge]
    var id_alloc: RetainedIdAllocator

    def __init__(out self):
        self.nodes = List[Node]()
        self.edges = List[Edge]()
        self.id_alloc = RetainedIdAllocator()

    def add_node(mut self, type_id: String, position: Vec2) -> RetainedId:
        """Allocate a fresh id, append a Node at `position`, return id."""
        var id = self.id_alloc.alloc()
        var n = Node(id, type_id)
        n.with_position(position)
        self.nodes.append(n^)
        return id

    def add_built_node(mut self, node: Node) -> RetainedId:
        """Append a pre-built `Node`, overwriting its id with a freshly
        allocated one. Returns the new id. Used by node duplication (the
        context menu) and any caller that already has a fully-populated
        Node it wants to insert atomically (the M3 atomic-spawn API the
        add-menu's allocate/remove/append dance approximated).
        """
        var id = self.id_alloc.alloc()
        var n = node.copy()
        n.id = id
        self.nodes.append(n^)
        return id

    def remove_node(mut self, id: RetainedId):
        """Remove the node AND every edge touching it. Returns the id slot
        to the allocator (generation bumps on next reuse).
        """
        var new_edges = List[Edge]()
        var ne = len(self.edges)
        for i in range(ne):
            var e = self.edges[i].copy()
            if e.from_node != id and e.to_node != id:
                new_edges.append(e^)
        self.edges = new_edges^

        var new_nodes = List[Node]()
        var nn = len(self.nodes)
        for i in range(nn):
            var n = self.nodes[i].copy()
            if n.id != id:
                new_nodes.append(n^)
        self.nodes = new_nodes^

        self.id_alloc.free(id)

    def find_node(self, id: RetainedId) -> Int:
        """Linear scan; returns list index, or -1 if not found."""
        var nn = len(self.nodes)
        for i in range(nn):
            if self.nodes[i].id == id:
                return i
        return -1

    def node_count(self) -> Int:
        return len(self.nodes)

    def edge_count(self) -> Int:
        return len(self.edges)

    def add_edge(
        mut self,
        from_node: RetainedId,
        from_port: String,
        to_node: RetainedId,
        to_port: String,
    ) -> Bool:
        """Append an edge. Returns True on success; False if either node
        id is unknown. Does NOT type-check ports — that lives in c39.
        """
        if self.find_node(from_node) < 0:
            return False
        if self.find_node(to_node) < 0:
            return False
        var e = Edge(from_node, from_port, to_node, to_port)
        self.edges.append(e^)
        return True

    def remove_edges_between(
        mut self,
        from_node: RetainedId,
        from_port: String,
        to_node: RetainedId,
        to_port: String,
    ):
        """Remove the matching edge if it exists. No-op when none match."""
        var new_edges = List[Edge]()
        var ne = len(self.edges)
        for i in range(ne):
            var e = self.edges[i].copy()
            var same = (
                e.from_node == from_node
                and e.from_port == from_port
                and e.to_node == to_node
                and e.to_port == to_port
            )
            if not same:
                new_edges.append(e^)
        self.edges = new_edges^

    def remove_edge_at(mut self, index: Int):
        """Remove the edge at list `index`. No-op if out of range. Used by
        the canvas wire-delete UX, which selects an edge by its current
        list index and removes it on the Delete key.
        """
        if index < 0 or index >= len(self.edges):
            return
        var new_edges = List[Edge]()
        var ne = len(self.edges)
        for i in range(ne):
            if i != index:
                new_edges.append(self.edges[i].copy())
        self.edges = new_edges^


# ============================================================================
# TopoSortError
# ============================================================================


struct TopoSortError(Copyable, Movable):
    """Cycle-detection diagnostic. `remaining()` is the count of nodes
    trapped in cycles. `topo_sort` raises `Error` (the only payload type
    Mojo's `raise` accepts in current beta); this struct is available for
    callers that want richer info alongside the raise.
    """

    var sorted: Int
    var total: Int

    def __init__(out self, sorted: Int, total: Int):
        self.sorted = sorted
        self.total = total

    def remaining(self) -> Int:
        return self.total - self.sorted


# ============================================================================
# topo_sort — Kahn's algorithm with stable seed order
# ============================================================================


def topo_sort(graph: Graph) raises -> List[RetainedId]:
    """Kahn's algorithm. Returns nodes in execution order (dependency
    first); raises `Error` on cycle.

    Stable seed order: zero-in-degree nodes enter the queue in
    `graph.nodes` declaration order, giving deterministic output across
    hash-randomization runs (EriGui's content-hash cache invariant).

    Algorithm:
      1. Build `in_degree[id]` per node.
      2. Seed queue with zero-in-degree nodes in declaration order.
      3. Pop front, append to `order`, decrement children's in-degree;
         enqueue any child that hits zero.
      4. If `len(order) != node_count`, raise — leftovers are in a cycle.

    Queue is `List[RetainedId]` with O(n) front-pop — fine for the 7-20
    node graphs typical of diffusion workflows. M4 can swap in a deque.
    """
    var nn = graph.node_count()
    var ne = graph.edge_count()

    # 1. in-degree map (UInt64 key — re-confirms c32 Dict[String, V] for
    # a numeric key type).
    var in_degree = Dict[RetainedId, Int]()
    for i in range(nn):
        in_degree[graph.nodes[i].id] = 0
    for i in range(ne):
        var to_id = graph.edges[i].to_node
        if to_id in in_degree:
            in_degree[to_id] = in_degree[to_id] + 1

    # 2. Seed queue in DECLARATION ORDER.
    var queue = List[RetainedId]()
    for i in range(nn):
        var nid = graph.nodes[i].id
        if in_degree[nid] == 0:
            queue.append(nid)

    # 3. BFS.
    var order = List[RetainedId]()
    while len(queue) > 0:
        var id = queue[0]

        # Pop front (O(n) shift; M4 can swap in a deque).
        var new_queue = List[RetainedId]()
        var qn = len(queue)
        for i in range(1, qn):
            new_queue.append(queue[i])
        queue = new_queue^

        order.append(id)

        for i in range(ne):
            if graph.edges[i].from_node == id:
                var child = graph.edges[i].to_node
                if child in in_degree:
                    in_degree[child] = in_degree[child] - 1
                    if in_degree[child] == 0:
                        queue.append(child)

    # 4. Cycle detection.
    if len(order) != nn:
        raise Error(
            "graph has a cycle; sorted "
            + String(len(order))
            + " of "
            + String(nn)
            + " nodes"
        )
    return order^
