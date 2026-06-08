"""Pure-Mojo workflow executor orchestrator.

The executor owns DAG compilation and step status updates. Node behavior lives
in smaller modules so Comfy-style families can grow without turning this file
into a compiler stress point.
"""

from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.nodes.port import NVT_TEXT
from mojoui.nodes.execution import (
    EXEC_DONE,
    EXEC_FAILED,
    EXEC_SKIPPED,
    compile_execution_plan,
)
from mojoui.nodes.canvas_model import CanvasState
from mojoui.app.workflow_render import extract_render_request
from mojoui.app.workflow_types import (
    WorkflowArtifact,
    WorkflowDeviceConfig,
    WorkflowExecutionResult,
    WorkflowLaunchAction,
    WorkflowLaunchStatus,
    WorkflowValue,
    WorkflowValueKind,
    WLS_DONE,
    WLS_FAILED,
    WLS_LAUNCHED,
    WLS_STAGED,
    WV_BBOX,
    WV_CLIP,
    WV_CONDITIONING,
    WV_IMAGE,
    WV_LATENT,
    WV_LORA,
    WV_MODEL,
    WV_NONE,
    WV_NUMBER,
    WV_TEXT,
    WV_VAE,
    WV_VIDEO,
)
from mojoui.app.workflow_support import has_output_kind
from mojoui.app.workflow_compat_nodes import (
    execute_compat_node,
    is_compat_node,
)
from mojoui.app.workflow_diffusion_nodes import (
    execute_diffusion_node,
    is_diffusion_node,
)
from mojoui.app.workflow_ideogram_nodes import (
    execute_ideogram_node,
    is_ideogram_node,
)
from mojoui.app.workflow_media_nodes import (
    execute_media_node,
    execute_text_passthrough,
    is_media_node,
)
from mojoui.app.workflow_vhs_nodes import (
    execute_vhs_node,
    is_vhs_node,
)


def execute_workflow(graph: Graph, canvas: CanvasState) raises -> WorkflowExecutionResult:
    """Compile and execute a graph with the default GPU-required config."""
    var device = WorkflowDeviceConfig()
    return execute_workflow_with_device(graph, canvas, device)


def execute_workflow_with_device(
    graph: Graph,
    canvas: CanvasState,
    device: WorkflowDeviceConfig,
) raises -> WorkflowExecutionResult:
    """Compile and execute a graph with the built-in GPU-first handlers."""
    var plan = compile_execution_plan(graph)
    var request = extract_render_request(graph, canvas)
    var result = WorkflowExecutionResult(plan^, request, device)
    if result.device.require_gpu and result.device.device_kind != String("gpu"):
        result.success = False
        result.add_log(String("gpu_required"))
        return result^

    for i in range(result.plan.step_count()):
        if not result.plan.steps[i].runnable:
            result.plan.steps[i].status = EXEC_SKIPPED
            result.add_log(String("skip ") + result.plan.steps[i].title)
            continue

        var node_id = result.plan.steps[i].node_id
        var idx = graph.find_node(node_id)
        if idx < 0:
            result.plan.steps[i].status = EXEC_FAILED
            result.success = False
            result.add_log(String("missing node ") + String(node_id))
            continue

        var node = graph.nodes[idx].copy()
        var ok = execute_node(graph, node, result)
        if ok:
            result.plan.steps[i].status = EXEC_DONE
        else:
            result.plan.steps[i].status = EXEC_FAILED
            result.success = False
    return result^


def execute_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if is_compat_node(node):
        return execute_compat_node(graph, node, result)
    if is_diffusion_node(node):
        return execute_diffusion_node(graph, node, result)
    if is_ideogram_node(node):
        return execute_ideogram_node(graph, node, result)
    if is_vhs_node(node):
        return execute_vhs_node(graph, node, result)
    if is_media_node(node):
        return execute_media_node(graph, node, result)
    if has_output_kind(node, NVT_TEXT):
        return execute_text_passthrough(node, result, node.outputs[0].name)

    result.add_log(String("noop ") + node.title)
    return True
