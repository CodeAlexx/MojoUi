"""Shared helpers for workflow node executors."""

from mojoui.core.id import RetainedId
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node, FieldValue, FK_NUMBER, FK_STRING, FK_BOOL, FK_INT
from mojoui.nodes.port import (
    NVT_CLIP,
    NVT_IMAGE,
    NVT_LATENT,
    NVT_MODEL,
    NVT_TEXT,
    NVT_VAE,
)
from mojoui.app.sampler_runtime import LanPaintConfig, SamplerConfig
from mojoui.app.workflow_types import (
    WorkflowDeviceConfig,
    WorkflowExecutionResult,
    WorkflowValue,
    WorkflowValueKind,
    WV_BBOX,
    WV_CLIP,
    WV_CONDITIONING,
    WV_IMAGE,
    WV_LATENT,
    WV_MODEL,
    WV_NUMBER,
    WV_TEXT,
    WV_VAE,
    WV_VIDEO,
)


def add_handle_outputs(
    node: Node,
    mut result: WorkflowExecutionResult,
    value_type: Int32,
    value_kind: WorkflowValueKind,
    fallback_port: String,
    handle: String,
):
    var emitted = False
    for i in range(len(node.outputs)):
        if node.outputs[i].value_type == value_type or lower(node.outputs[i].name) == lower(fallback_port):
            result.add_value(WorkflowValue.handle_value(node.id, node.outputs[i].name, value_kind, handle))
            emitted = True
    if not emitted:
        result.add_value(WorkflowValue.handle_value(node.id, fallback_port, value_kind, handle))


def incoming_value(
    graph: Graph,
    result: WorkflowExecutionResult,
    node_id: RetainedId,
    input_port: String,
) -> WorkflowValue:
    var wanted = lower(input_port)
    for i in range(graph.edge_count()):
        if graph.edges[i].to_node == node_id and lower(graph.edges[i].to_port) == wanted:
            return result.find_value(graph.edges[i].from_node, graph.edges[i].from_port)
    if wanted == String("image") or wanted == String("images") or wanted == String("pixels"):
        return first_incoming_kind(graph, result, node_id, WV_IMAGE)
    if wanted == String("video") or wanted == String("videos"):
        return first_incoming_kind(graph, result, node_id, WV_VIDEO)
    if wanted == String("bboxes") or wanted == String("bbox"):
        return first_incoming_kind(graph, result, node_id, WV_BBOX)
    if wanted == String("model"):
        return first_incoming_kind(graph, result, node_id, WV_MODEL)
    if wanted == String("clip"):
        return first_incoming_kind(graph, result, node_id, WV_CLIP)
    if wanted == String("vae"):
        return first_incoming_kind(graph, result, node_id, WV_VAE)
    if wanted == String("latent") or wanted == String("latent_image") or wanted == String("samples"):
        return first_incoming_kind(graph, result, node_id, WV_LATENT)
    if (
        wanted == String("cfg")
        or wanted == String("steps")
        or wanted == String("seed")
        or wanted == String("width")
        or wanted == String("height")
    ):
        return first_incoming_kind(graph, result, node_id, WV_NUMBER)
    if (
        wanted == String("positive")
        or wanted == String("negative")
        or wanted == String("cond")
        or wanted == String("uncond")
        or wanted == String("conditioning")
    ):
        return first_incoming_kind(graph, result, node_id, WV_CONDITIONING)
    if wanted == String("prompt") or wanted == String("caption_json") or wanted == String("sampler") or wanted == String("sampler_name") or wanted == String("scheduler"):
        return first_incoming_kind(graph, result, node_id, WV_TEXT)
    if wanted == String("import_json"):
        return first_incoming_kind(graph, result, node_id, WV_TEXT)
    return WorkflowValue()


def first_incoming_kind(
    graph: Graph,
    result: WorkflowExecutionResult,
    node_id: RetainedId,
    kind: WorkflowValueKind,
) -> WorkflowValue:
    for i in range(graph.edge_count()):
        if graph.edges[i].to_node == node_id:
            var value = result.find_value(graph.edges[i].from_node, graph.edges[i].from_port)
            if value.kind == kind:
                return value^
    return WorkflowValue()


def first_output_name(node: Node, fallback: String) -> String:
    if len(node.outputs) == 0:
        return fallback.copy()
    return node.outputs[0].name.copy()


def output_name_or(node: Node, desired: String, fallback: String) -> String:
    var wanted = lower(desired)
    for i in range(len(node.outputs)):
        if lower(node.outputs[i].name) == wanted:
            return node.outputs[i].name.copy()
    return fallback.copy()


def has_output_kind(node: Node, kind: Int32) -> Bool:
    for i in range(len(node.outputs)):
        if node.outputs[i].value_type == kind:
            return True
    return False


def string_field(node: Node, key: String, fallback: String) raises -> String:
    if not node.has_field(key):
        return fallback.copy()
    var value = field_to_string(node.get_field(key))
    if value.byte_length() == 0:
        return fallback.copy()
    return value^


def prompt_from_node(node: Node) raises -> String:
    return first_string_field(
        node,
        String("prompt"),
        String("positive"),
        String("text"),
        String(""),
    )


def first_string_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    fallback: String,
) raises -> String:
    var keys = field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = lower(key)
        if lower_key == key_a or lower_key == key_b or lower_key == key_c:
            var value = field_to_string(node.get_field(key))
            if value.byte_length() > 0:
                return value^
    return fallback.copy()


def int_field(node: Node, key: String, fallback: Int32) raises -> Int32:
    if not node.has_field(key):
        return fallback
    var value = node.get_field(key)
    if value.kind == FK_INT:
        return Int32(value.int_val)
    if value.kind == FK_NUMBER:
        return Int32(value.num_val)
    return fallback


def i64_field(node: Node, key: String, fallback: Int64) raises -> Int64:
    if not node.has_field(key):
        return fallback
    var value = node.get_field(key)
    if value.kind == FK_INT:
        return value.int_val
    if value.kind == FK_NUMBER:
        return Int64(value.num_val)
    return fallback


def first_int_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    fallback: Int32,
) raises -> Int32:
    var keys = field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = lower(key)
        if lower_key == key_a or lower_key == key_b or lower_key == key_c:
            var value = node.get_field(key)
            if value.kind == FK_INT:
                return Int32(value.int_val)
            if value.kind == FK_NUMBER:
                return Int32(value.num_val)
    return fallback


def first_i64_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    fallback: Int64,
) raises -> Int64:
    var keys = field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = lower(key)
        if lower_key == key_a or lower_key == key_b or lower_key == key_c:
            var value = node.get_field(key)
            if value.kind == FK_INT:
                return value.int_val
            if value.kind == FK_NUMBER:
                return Int64(value.num_val)
    return fallback


def first_number_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    fallback: Float64,
) raises -> Float64:
    var keys = field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = lower(key)
        if lower_key == key_a or lower_key == key_b or lower_key == key_c:
            var value = node.get_field(key)
            if value.kind == FK_NUMBER:
                return value.num_val
            if value.kind == FK_INT:
                return Float64(value.int_val)
    return fallback


def first_bool_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    fallback: Bool,
) raises -> Bool:
    var keys = field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = lower(key)
        if lower_key == key_a or lower_key == key_b or lower_key == key_c:
            var value = node.get_field(key)
            if value.kind == FK_BOOL:
                return value.bool_val
            if value.kind == FK_INT:
                return value.int_val != Int64(0)
            if value.kind == FK_NUMBER:
                return value.num_val != 0.0
            if value.kind == FK_STRING:
                var s = lower(value.str_val)
                if s == String("false") or s == String("disable") or s == String("disabled") or s == String("0") or s == String("no"):
                    return False
                if s.byte_length() > 0:
                    return True
    return fallback


def gpu_command(
    entry: String,
    device: WorkflowDeviceConfig,
    output_path: String,
    width: Int32,
    height: Int32,
    seed: Int64,
) -> String:
    var command = (
        String("mojo run -I ")
        + device.mojodiffusion_root
        + String(" ")
        + entry
        + String(" --device ")
        + device.device_kind
        + String(":")
        + String(device.device_index)
    )
    if output_path.byte_length() > 0:
        command = command + String(" --output ") + output_path
    if width > 0 and height > 0:
        command = command + String(" --width ") + String(width) + String(" --height ") + String(height)
    if seed >= 0:
        command = command + String(" --seed ") + String(seed)
    return command^


def sampler_gpu_command(
    entry: String,
    device: WorkflowDeviceConfig,
    sampler_name: String,
    scheduler_name: String,
    config: SamplerConfig,
    width: Int32,
    height: Int32,
) -> String:
    return (
        String("mojo run -I ")
        + device.mojodiffusion_root
        + String(" ")
        + entry
        + String(" --device ")
        + device.device_kind
        + String(":")
        + String(device.device_index)
        + String(" --sampler ")
        + sampler_name
        + String(" --scheduler ")
        + scheduler_name
        + String(" --steps ")
        + String(config.steps)
        + String(" --cfg ")
        + String(config.cfg)
        + String(" --denoise ")
        + String(config.denoise)
        + String(" --seed ")
        + String(config.seed)
        + String(" --width ")
        + String(width)
        + String(" --height ")
        + String(height)
    )


def lanpaint_sampler_gpu_command(
    entry: String,
    device: WorkflowDeviceConfig,
    sampler_name: String,
    scheduler_name: String,
    config: SamplerConfig,
    lanpaint: LanPaintConfig,
    width: Int32,
    height: Int32,
) -> String:
    return (
        sampler_gpu_command(entry, device, sampler_name, scheduler_name, config, width, height)
        + String(" --lanpaint-num-steps ")
        + String(lanpaint.num_steps)
        + String(" --lanpaint-lambda ")
        + String(lanpaint.lambda_scale)
        + String(" --lanpaint-step-size ")
        + String(lanpaint.step_size)
        + String(" --lanpaint-beta ")
        + String(lanpaint.beta)
        + String(" --lanpaint-friction ")
        + String(lanpaint.friction)
        + String(" --lanpaint-prompt-mode \"")
        + lanpaint.prompt_mode
        + String("\" --lanpaint-early-stop ")
        + String(lanpaint.early_stop)
        + String(" --lanpaint-inner-threshold ")
        + String(lanpaint.inner_threshold)
        + String(" --lanpaint-inner-patience ")
        + String(lanpaint.inner_patience)
    )


def field_to_string(value: FieldValue) -> String:
    if value.kind == FK_STRING:
        return value.str_val.copy()
    if value.kind == FK_INT:
        return String(value.int_val)
    if value.kind == FK_NUMBER:
        return String(value.num_val)
    if value.kind == FK_BOOL:
        if value.bool_val:
            return String("true")
        return String("false")
    return String("")


def field_keys(node: Node) -> List[String]:
    var keys = List[String]()
    for k in node.fields.keys():
        keys.append(k.copy())
    return keys^


def node_matches(node: Node, needle: String) -> Bool:
    var n = lower(needle)
    return contains_substr(lower(node.type_id), n) or contains_substr(lower(node.title), n)


def lower(s: String) -> String:
    var n = s.byte_length()
    var out = List[UInt8](capacity=n)
    var ptr = s.unsafe_ptr()
    for i in range(n):
        var b = ptr[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            b = b + UInt8(0x20)
        out.append(b)
    return String(unsafe_from_utf8=out)


def contains_substr(haystack: String, needle: String) -> Bool:
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
