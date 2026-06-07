"""Pure-Mojo graph execution planning.

This module is intentionally data-only. It turns a visual `Graph` into a
topologically ordered `ExecutionPlan` that an embedding app can dispatch
against its own runtime table. MojoUI does not execute model code here.
"""

from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.graph import Graph, topo_sort


comptime ExecutionStatus = Int32

comptime EXEC_PENDING: ExecutionStatus = 0
comptime EXEC_RUNNING: ExecutionStatus = 1
comptime EXEC_DONE: ExecutionStatus = 2
comptime EXEC_FAILED: ExecutionStatus = 3
comptime EXEC_SKIPPED: ExecutionStatus = 4


struct ExecutionStep(Copyable, Movable):
    """One node in runnable order."""

    var node_id: RetainedId
    var type_id: String
    var title: String
    var runnable: Bool
    var status: ExecutionStatus
    var order_index: Int32

    def __init__(
        out self,
        node_id: RetainedId,
        type_id: String,
        title: String,
        runnable: Bool,
        status: ExecutionStatus,
        order_index: Int32,
    ):
        self.node_id = node_id
        self.type_id = type_id.copy()
        self.title = title.copy()
        self.runnable = runnable
        self.status = status
        self.order_index = order_index


struct ExecutionPlan(Movable):
    """Topologically ordered node plan plus small lookup helpers."""

    var steps: List[ExecutionStep]
    var has_cycle: Bool
    var error_message: String

    def __init__(out self):
        self.steps = List[ExecutionStep]()
        self.has_cycle = False
        self.error_message = String("")

    def step_count(self) -> Int:
        return len(self.steps)

    def runnable_count(self) -> Int:
        var count = 0
        for i in range(len(self.steps)):
            if self.steps[i].runnable:
                count += 1
        return count

    def skipped_count(self) -> Int:
        var count = 0
        for i in range(len(self.steps)):
            if self.steps[i].status == EXEC_SKIPPED:
                count += 1
        return count

    def find_step_index(self, node_id: RetainedId) -> Int:
        for i in range(len(self.steps)):
            if self.steps[i].node_id == node_id:
                return i
        return -1

    def set_status(mut self, node_id: RetainedId, status: ExecutionStatus) -> Bool:
        var idx = self.find_step_index(node_id)
        if idx < 0:
            return False
        self.steps[idx].status = status
        return True


def compile_execution_plan(graph: Graph) raises -> ExecutionPlan:
    """Compile a visual graph into deterministic execution order.

    Muted and bypassed nodes remain in the plan, but are marked
    `EXEC_SKIPPED` and `runnable=False`. Cycles raise from `topo_sort`.
    """
    var order = topo_sort(graph)
    var plan = ExecutionPlan()
    for i in range(len(order)):
        var node_id = order[i]
        var idx = graph.find_node(node_id)
        if idx < 0:
            continue
        var n = graph.nodes[idx].copy()
        var runnable = not n.muted and not n.bypassed
        var status = EXEC_PENDING
        if not runnable:
            status = EXEC_SKIPPED
        plan.steps.append(
            ExecutionStep(
                n.id,
                n.type_id,
                n.title,
                runnable,
                status,
                Int32(i),
            )
        )
    return plan^


def empty_failed_execution_plan(message: String) -> ExecutionPlan:
    """Convenience for app layers that catch a compile failure and need a
    data object to surface in UI.
    """
    var plan = ExecutionPlan()
    plan.has_cycle = True
    plan.error_message = message.copy()
    return plan^
