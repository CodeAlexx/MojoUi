"""Compatibility executors for Comfy extension-style utility nodes.

These handlers cover pure graph plumbing from popular packs such as rgthree
and KJNodes. They intentionally do not call Python extension code; they
produce typed Mojo workflow values that downstream model/sampler nodes can use.
"""

from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.app.sampler_runtime import text_conditioning_scalar
from mojoui.app.workflow_types import (
    WorkflowExecutionResult,
    WorkflowValue,
    WV_CONDITIONING,
    WV_IMAGE,
    WV_LATENT,
    WV_MODEL,
    WV_CLIP,
    WV_NONE,
    WV_TEXT,
)
from mojoui.app.workflow_support import (
    first_bool_field,
    first_i64_field,
    first_incoming_kind,
    first_int_field,
    first_number_field,
    first_output_name,
    first_string_field,
    incoming_value,
    node_matches,
    output_name_or,
)


def is_compat_node(node: Node) -> Bool:
    return (
        is_constant_node(node)
        or node_matches(node, String("joinstrings"))
        or node_matches(node, String("joinstringmulti"))
        or node_matches(node, String("any switch"))
        or node_matches(node, String("lazyswitch"))
        or node_matches(node, String("power prompt"))
        or node_matches(node, String("seed (rgthree)"))
        or node_matches(node, String("image or latent size"))
        or node_matches(node, String("imageresize"))
        or node_matches(node, String("image resize"))
        or node_matches(node, String("getimagesize"))
        or node_matches(node, String("getlatentsize"))
        or node_matches(node, String("condpassthrough"))
        or node_matches(node, String("modelpassthrough"))
        or node_matches(node, String("conditioningcombine"))
        or node_matches(node, String("conditioningmulticombine"))
        or node_matches(node, String("conditioningsetmaskandcombine"))
        or node_matches(node, String("repeatlatentbatch"))
        or node_matches(node, String("latentupscale"))
        or node_matches(node, String("emptylatentimagepresets"))
    )


def execute_compat_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if is_constant_node(node):
        return execute_constant_node(node, result)
    if node_matches(node, String("joinstrings")) or node_matches(node, String("joinstringmulti")):
        return execute_join_strings(graph, node, result)
    if node_matches(node, String("any switch")) or node_matches(node, String("lazyswitch")):
        return execute_any_switch(graph, node, result)
    if node_matches(node, String("power prompt")):
        return execute_power_prompt(graph, node, result)
    if node_matches(node, String("seed (rgthree)")):
        return execute_seed_node(node, result)
    if (
        node_matches(node, String("image or latent size"))
        or node_matches(node, String("getimagesize"))
        or node_matches(node, String("getlatentsize"))
    ):
        return execute_size_probe(graph, node, result)
    if node_matches(node, String("imageresize")) or node_matches(node, String("image resize")):
        return execute_image_resize(graph, node, result)
    if node_matches(node, String("condpassthrough")):
        return execute_cond_passthrough(graph, node, result)
    if node_matches(node, String("modelpassthrough")):
        return execute_model_passthrough(graph, node, result)
    if (
        node_matches(node, String("conditioningcombine"))
        or node_matches(node, String("conditioningmulticombine"))
        or node_matches(node, String("conditioningsetmaskandcombine"))
    ):
        return execute_conditioning_combine(graph, node, result)
    if (
        node_matches(node, String("repeatlatentbatch"))
        or node_matches(node, String("latentupscale"))
        or node_matches(node, String("emptylatentimagepresets"))
    ):
        return execute_latent_compat(graph, node, result)
    return False


def is_constant_node(node: Node) -> Bool:
    return (
        node_matches(node, String("intconstant"))
        or node_matches(node, String("floatconstant"))
        or node_matches(node, String("boolconstant"))
        or node_matches(node, String("stringconstant"))
    )


def execute_constant_node(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if node_matches(node, String("stringconstant")):
        var text = first_string_field(node, String("string"), String("value"), String("widget_0"), String(""))
        result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("STRING")), text))
        result.add_log(String("compat_string_constant ") + String(text.byte_length()) + String(" bytes"))
        return True
    if node_matches(node, String("boolconstant")):
        var flag = first_bool_field(node, String("value"), String("widget_0"), String(""), False)
        var text = String("0")
        if flag:
            text = String("1")
        result.add_value(WorkflowValue.number_value(node.id, first_output_name(node, String("BOOLEAN")), text))
        result.add_log(String("compat_bool_constant ") + text)
        return True
    if node_matches(node, String("intconstant")):
        var value = first_i64_field(node, String("value"), String("widget_0"), String(""), Int64(0))
        result.add_value(WorkflowValue.number_value(node.id, first_output_name(node, String("INT")), String(value)))
        result.add_log(String("compat_int_constant ") + String(value))
        return True
    var number = first_number_field(node, String("value"), String("widget_0"), String(""), 0.0)
    result.add_value(WorkflowValue.number_value(node.id, first_output_name(node, String("FLOAT")), String(number)))
    result.add_log(String("compat_float_constant ") + String(number))
    return True


def execute_join_strings(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var a = incoming_value(graph, result, node.id, String("string1"))
    if a.kind != WV_TEXT:
        a = incoming_value(graph, result, node.id, String("string_1"))
    var b = incoming_value(graph, result, node.id, String("string2"))
    if b.kind != WV_TEXT:
        b = incoming_value(graph, result, node.id, String("string_2"))
    var text_a = a.text.copy()
    if text_a.byte_length() == 0:
        text_a = first_string_field(node, String("string1"), String("string_1"), String("widget_1"), String(""))
    var text_b = b.text.copy()
    if text_b.byte_length() == 0:
        text_b = first_string_field(node, String("string2"), String("string_2"), String("widget_2"), String(""))
    var delimiter = first_string_field(node, String("delimiter"), String("separator"), String("widget_0"), String(" "))
    var joined = text_a + delimiter + text_b
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("STRING")), joined))
    result.add_log(String("compat_join_strings ") + String(joined.byte_length()) + String(" bytes"))
    return True


def execute_any_switch(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    for i in range(graph.edge_count()):
        if graph.edges[i].to_node == node.id:
            var value = result.find_value(graph.edges[i].from_node, graph.edges[i].from_port)
            if value.kind != WV_NONE:
                _forward_value(node, first_output_name(node, String("*")), value, result)
                result.add_log(String("compat_any_switch ") + graph.edges[i].to_port)
                return True
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("*")), String("")))
    result.add_log(String("compat_any_switch empty"))
    return True


def execute_power_prompt(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var prompt = first_string_field(node, String("prompt"), String("text"), String("widget_0"), String(""))
    var scalar = text_conditioning_scalar(prompt)
    result.add_value(
        WorkflowValue.conditioning_value(
            node.id,
            output_name_or(node, String("CONDITIONING"), String("CONDITIONING")),
            prompt,
            scalar,
        )
    )
    result.add_value(WorkflowValue.text_value(node.id, output_name_or(node, String("TEXT"), String("TEXT")), prompt))

    var model = incoming_value(graph, result, node.id, String("opt_model"))
    if model.kind == WV_MODEL:
        _forward_value(node, output_name_or(node, String("MODEL"), String("MODEL")), model, result)
    var clip = incoming_value(graph, result, node.id, String("opt_clip"))
    if clip.kind == WV_CLIP:
        _forward_value(node, output_name_or(node, String("CLIP"), String("CLIP")), clip, result)
    result.add_log(String("compat_power_prompt ") + String(prompt.byte_length()) + String(" bytes"))
    return True


def execute_seed_node(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var seed = first_i64_field(node, String("seed"), String("value"), String("widget_0"), Int64(0))
    if seed < Int64(0):
        seed = Int64(0)
    result.add_value(WorkflowValue.number_value(node.id, first_output_name(node, String("SEED")), String(seed)))
    result.add_log(String("compat_seed ") + String(seed))
    return True


def execute_size_probe(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var value = incoming_value(graph, result, node.id, String("input"))
    if value.kind != WV_IMAGE and value.kind != WV_LATENT:
        value = first_incoming_kind(graph, result, node.id, WV_IMAGE)
    if value.kind != WV_IMAGE and value.kind != WV_LATENT:
        value = first_incoming_kind(graph, result, node.id, WV_LATENT)
    var width = value.width
    var height = value.height
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("WIDTH"), String("WIDTH")), String(width)))
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("HEIGHT"), String("HEIGHT")), String(height)))
    result.add_log(String("compat_size_probe ") + String(width) + String("x") + String(height))
    return True


def execute_image_resize(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("image"))
    if image.kind != WV_IMAGE:
        image = first_incoming_kind(graph, result, node.id, WV_IMAGE)
    var width = first_int_field(node, String("width"), String("widget_1"), String(""), image.width)
    var height = first_int_field(node, String("height"), String("widget_2"), String(""), image.height)
    if width <= 0:
        width = image.width
    if height <= 0:
        height = image.height
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    result.add_value(WorkflowValue.image_path(node.id, output_name_or(node, String("IMAGE"), String("IMAGE")), image.path, width, height, image.seed))
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("WIDTH"), String("WIDTH")), String(width)))
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("HEIGHT"), String("HEIGHT")), String(height)))
    result.add_log(String("compat_image_resize ") + String(width) + String("x") + String(height))
    return True


def execute_cond_passthrough(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var positive = incoming_value(graph, result, node.id, String("positive"))
    if positive.kind == WV_CONDITIONING:
        _forward_value(node, output_name_or(node, String("positive"), String("positive")), positive, result)
    var negative = incoming_value(graph, result, node.id, String("negative"))
    if negative.kind == WV_CONDITIONING:
        _forward_value(node, output_name_or(node, String("negative"), String("negative")), negative, result)
    result.add_log(String("compat_cond_passthrough"))
    return True


def execute_model_passthrough(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var model = incoming_value(graph, result, node.id, String("model"))
    if model.kind == WV_MODEL:
        _forward_value(node, first_output_name(node, String("MODEL")), model, result)
    result.add_log(String("compat_model_passthrough"))
    return True


def execute_conditioning_combine(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var a = incoming_value(graph, result, node.id, String("conditioning_1"))
    if a.kind != WV_CONDITIONING:
        a = incoming_value(graph, result, node.id, String("positive"))
    var b = incoming_value(graph, result, node.id, String("conditioning_2"))
    if b.kind != WV_CONDITIONING:
        b = incoming_value(graph, result, node.id, String("negative"))
    if a.kind != WV_CONDITIONING:
        a = first_incoming_kind(graph, result, node.id, WV_CONDITIONING)
    var text = a.text.copy()
    var scalar = a.scalar
    if b.kind == WV_CONDITIONING:
        if text.byte_length() > 0 and b.text.byte_length() > 0:
            text = text + String("\n")
        text = text + b.text
        scalar = scalar + b.scalar
    result.add_value(WorkflowValue.conditioning_value(node.id, first_output_name(node, String("CONDITIONING")), text, scalar))
    result.add_log(String("compat_conditioning_combine"))
    return True


def execute_latent_compat(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if node_matches(node, String("emptylatentimagepresets")):
        var width = first_int_field(node, String("width"), String("widget_0"), String(""), Int32(1024))
        var height = first_int_field(node, String("height"), String("widget_1"), String(""), Int32(1024))
        var dims = first_string_field(node, String("dimensions"), String("widget_0"), String(""), String(""))
        if dims.byte_length() > 0:
            width = _dimension_part(dims, 0, width)
            height = _dimension_part(dims, 1, height)
        if first_bool_field(node, String("invert"), String("widget_1"), String(""), False):
            var tmp = width
            width = height
            height = tmp
        var batch = first_int_field(node, String("batch_size"), String("batch"), String("widget_2"), Int32(1))
        result.add_value(WorkflowValue.latent_value(node.id, output_name_or(node, String("LATENT"), String("LATENT")), width, height, batch, Int64(0), 0.0))
        result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("width"), String("width")), String(width)))
        result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("height"), String("height")), String(height)))
        result.add_log(String("compat_empty_latent_preset ") + String(width) + String("x") + String(height))
        return True

    var latent = incoming_value(graph, result, node.id, String("samples"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("latent"))
    var width = latent.width
    var height = latent.height
    var batch = latent.batch_size
    if node_matches(node, String("repeatlatentbatch")):
        var amount = first_int_field(node, String("amount"), String("batch_size"), String("widget_0"), Int32(1))
        if amount > 0:
            batch = batch * amount
    elif node_matches(node, String("latentupscaleby")):
        var scale = first_number_field(node, String("scale_by"), String("scale"), String("widget_1"), 1.0)
        width = Int32(Float64(width) * scale)
        height = Int32(Float64(height) * scale)
    elif node_matches(node, String("latentupscale")):
        width = first_int_field(node, String("width"), String("widget_1"), String(""), width)
        height = first_int_field(node, String("height"), String("widget_2"), String(""), height)
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    if batch <= 0:
        batch = 1
    result.add_value(WorkflowValue.latent_value(node.id, first_output_name(node, String("LATENT")), width, height, batch, latent.seed, latent.scalar))
    result.add_log(String("compat_latent ") + String(width) + String("x") + String(height) + String(" batch=") + String(batch))
    return True


def _forward_value(
    node: Node,
    port: String,
    value: WorkflowValue,
    mut result: WorkflowExecutionResult,
):
    var out = value.copy()
    out.node_id = node.id
    out.port = port.copy()
    result.add_value(out)


def _dimension_part(text: String, part: Int, fallback: Int32) -> Int32:
    var n = text.byte_length()
    var ptr = text.unsafe_ptr()
    var found_part = 0
    var value = Int32(0)
    var in_digits = False
    for i in range(n):
        var c = ptr[i]
        if c >= UInt8(48) and c <= UInt8(57):
            value = value * Int32(10) + Int32(c - UInt8(48))
            in_digits = True
        elif in_digits:
            if found_part == part:
                return value
            found_part = found_part + 1
            value = Int32(0)
            in_digits = False
    if in_digits and found_part == part:
        return value
    return fallback
