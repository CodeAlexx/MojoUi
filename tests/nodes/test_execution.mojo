"""Smoke tests for pure-Mojo execution planning."""

from mojoui.core.types import Vec2
from mojoui.nodes.graph import Graph
from mojoui.nodes.execution import (
    EXEC_PENDING,
    EXEC_SKIPPED,
    EXEC_DONE,
    compile_execution_plan,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_linear_plan_order() raises:
    var graph = Graph()
    var a = graph.add_node(String("core/load_checkpoint"), Vec2.zero())
    var b = graph.add_node(String("core/k_sampler"), Vec2.zero())
    var c = graph.add_node(String("core/save_image"), Vec2.zero())
    _ = graph.add_edge(a, String("model"), b, String("model"))
    _ = graph.add_edge(b, String("latent"), c, String("image"))

    var plan = compile_execution_plan(graph)
    _expect(plan.step_count() == 3, "linear graph should compile 3 steps")
    _expect(plan.steps[0].node_id == a, "step 0 should be load_checkpoint")
    _expect(plan.steps[1].node_id == b, "step 1 should be k_sampler")
    _expect(plan.steps[2].node_id == c, "step 2 should be save_image")
    _expect(plan.runnable_count() == 3, "all linear nodes should be runnable")
    _expect(plan.steps[0].status == EXEC_PENDING, "fresh runnable step starts pending")
    print("PASS: linear execution plan order")


def test_muted_and_bypassed_skip() raises:
    var graph = Graph()
    var a = graph.add_node(String("a"), Vec2.zero())
    var b = graph.add_node(String("b"), Vec2.zero())
    var c = graph.add_node(String("c"), Vec2.zero())
    _ = graph.add_edge(a, String("out"), b, String("in"))
    _ = graph.add_edge(b, String("out"), c, String("in"))
    graph.nodes[1].muted = True
    graph.nodes[2].bypassed = True

    var plan = compile_execution_plan(graph)
    _expect(plan.step_count() == 3, "skipped nodes still stay in the plan")
    _expect(plan.runnable_count() == 1, "only one node should remain runnable")
    _expect(plan.skipped_count() == 2, "muted and bypassed nodes should skip")
    _expect(plan.steps[1].status == EXEC_SKIPPED, "muted node should be skipped")
    _expect(plan.steps[2].status == EXEC_SKIPPED, "bypassed node should be skipped")
    _expect(plan.find_step_index(c) == 2, "find_step_index should locate skipped nodes")
    _expect(plan.set_status(a, EXEC_DONE), "set_status should update known node")
    _expect(plan.steps[0].status == EXEC_DONE, "set_status should write status")
    print("PASS: muted/bypassed execution steps skip")


def test_cycle_raises() raises:
    var graph = Graph()
    var a = graph.add_node(String("a"), Vec2.zero())
    var b = graph.add_node(String("b"), Vec2.zero())
    _ = graph.add_edge(a, String("out"), b, String("in"))
    _ = graph.add_edge(b, String("out"), a, String("in"))

    var raised = False
    try:
        var plan = compile_execution_plan(graph)
        if plan.step_count() < 0:
            raised = False
    except e:
        raised = True
    _expect(raised, "cycle should raise during execution-plan compile")
    print("PASS: cycle raises")


def main() raises:
    test_linear_plan_order()
    test_muted_and_bypassed_skip()
    test_cycle_raises()
    print("PASS: all 3 execution tests")
