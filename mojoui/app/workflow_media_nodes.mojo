"""Media and utility node executors for workflow graphs."""

from std.math import sqrt
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.nodes.port import NVT_MODEL
from mojoui.app.workflow_types import (
    WorkflowArtifact,
    WorkflowExecutionResult,
    WorkflowValue,
    WV_IMAGE,
    WV_MODEL,
    WV_TEXT,
)
from mojoui.app.workflow_support import (
    add_handle_outputs,
    first_incoming_kind,
    first_int_field,
    first_number_field,
    first_output_name,
    first_string_field,
    incoming_value,
    node_matches,
    prompt_from_node,
)


def is_media_node(node: Node) -> Bool:
    return (
        node_matches(node, String("save_image"))
        or node_matches(node, String("saveimage"))
        or node_matches(node, String("load_video"))
        or node_matches(node, String("preview_video"))
        or node_matches(node, String("save_video"))
        or node_matches(node, String("load_image"))
        or node_matches(node, String("loadimage"))
        or node_matches(node, String("preview_image"))
        or node_matches(node, String("previewimage"))
        or node_matches(node, String("preview_text"))
        or node_matches(node, String("preview as text"))
        or node_matches(node, String("previewany"))
        or node_matches(node, String("markdownnote"))
        or node_matches(node, String("resolutionselector"))
        or node_matches(node, String("ksamplerconfig"))
        or node_matches(node, String("imagescale"))
        or node_matches(node, String("imagescaleby"))
        or node_matches(node, String("imageinvert"))
        or node_matches(node, String("imageupscalewithmodel"))
        or node_matches(node, String("upscalemodelloader"))
    )


def execute_media_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if node_matches(node, String("save_image")) or node_matches(node, String("saveimage")):
        return execute_save_image(graph, node, result)
    if node_matches(node, String("load_video")):
        return execute_load_video(node, result)
    if node_matches(node, String("preview_video")):
        return execute_preview_video(graph, node, result)
    if node_matches(node, String("save_video")):
        return execute_save_video(graph, node, result)
    if node_matches(node, String("load_image")) or node_matches(node, String("loadimage")):
        return execute_load_image(node, result)
    if node_matches(node, String("preview_image")) or node_matches(node, String("previewimage")):
        return execute_preview_image(graph, node, result)
    if node_matches(node, String("preview_text")) or node_matches(node, String("preview as text")):
        return execute_preview_text(graph, node, result)
    if node_matches(node, String("previewany")):
        return execute_preview_any(graph, node, result)
    if node_matches(node, String("markdownnote")):
        return execute_markdown_note(node, result)
    if node_matches(node, String("resolutionselector")):
        return execute_resolution_selector(node, result)
    if node_matches(node, String("ksamplerconfig")):
        return execute_ksampler_config(node, result)
    if node_matches(node, String("upscalemodelloader")):
        return execute_upscale_model_loader(node, result)
    if (
        node_matches(node, String("imagescale"))
        or node_matches(node, String("imagescaleby"))
        or node_matches(node, String("imageinvert"))
        or node_matches(node, String("imageupscalewithmodel"))
    ):
        return execute_image_transform(graph, node, result)
    return False


def execute_save_image(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("image"))
    if image.kind != WV_IMAGE:
        image = incoming_value(graph, result, node.id, String("images"))
    var path = first_string_field(
        node,
        String("output_path"),
        String("path"),
        String("filename_prefix"),
        result.request.output_path,
    )
    if image.kind == WV_IMAGE and image.path.byte_length() > 0:
        path = image.path.copy()
    result.add_artifact(WorkflowArtifact(node.id, String("image"), path, String("Save image")))
    result.add_log(String("save_image ") + path)
    return True


def execute_load_video(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var path = first_string_field(
        node,
        String("path"),
        String("video"),
        String("widget_0"),
        String(""),
    )
    result.add_value(WorkflowValue.video_path(node.id, first_output_name(node, String("video")), path))
    result.add_log(String("load_video ") + path)
    return True


def execute_preview_video(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var video = incoming_value(graph, result, node.id, String("video"))
    var path = video.path.copy()
    if path.byte_length() == 0:
        path = first_string_field(node, String("path"), String("video"), String("widget_0"), String(""))
    result.add_artifact(WorkflowArtifact(node.id, String("video_preview"), path, String("Preview video")))
    result.add_log(String("preview_video ") + path)
    return True


def execute_save_video(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var video = incoming_value(graph, result, node.id, String("video"))
    var path = first_string_field(node, String("output_path"), String("path"), String("filename"), String("out.mp4"))
    if path.byte_length() == 0 and video.path.byte_length() > 0:
        path = video.path.copy()
    result.add_artifact(WorkflowArtifact(node.id, String("video"), path, String("Save video")))
    result.add_log(String("save_video ") + path)
    return True


def execute_load_image(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var path = first_string_field(
        node,
        String("path"),
        String("image"),
        String("widget_0"),
        String(""),
    )
    result.add_value(WorkflowValue.image_path(node.id, first_output_name(node, String("image")), path, 0, 0, -1))
    result.add_log(String("load_image ") + path)
    return True


def execute_preview_image(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("image"))
    if image.kind != WV_IMAGE:
        image = incoming_value(graph, result, node.id, String("images"))
    var path = image.path.copy()
    result.add_artifact(WorkflowArtifact(node.id, String("image_preview"), path, String("Preview image")))
    result.add_log(String("preview_image ") + path)
    return True


def execute_preview_text(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var value = incoming_value(graph, result, node.id, String("source"))
    if value.kind != WV_TEXT:
        value = first_incoming_kind(graph, result, node.id, WV_TEXT)
    result.add_artifact(WorkflowArtifact(node.id, String("text_preview"), String(""), String("Preview as Text")))
    result.add_log(String("preview_text ") + String(value.text.byte_length()) + String(" bytes"))
    return True


def execute_preview_any(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var value = incoming_value(graph, result, node.id, String("source"))
    if value.kind != WV_TEXT:
        value = first_incoming_kind(graph, result, node.id, WV_TEXT)
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("STRING")), value.text))
    result.add_artifact(WorkflowArtifact(node.id, String("text_preview"), String(""), String("Preview Any")))
    result.add_log(String("preview_any ") + String(value.text.byte_length()) + String(" bytes"))
    return True


def execute_markdown_note(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var text = first_string_field(node, String("text"), String("widget_0"), String(""), String(""))
    result.add_log(String("markdown_note ") + String(text.byte_length()) + String(" bytes"))
    return True


def execute_resolution_selector(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var ratio_text = first_string_field(node, String("aspect_ratio"), String("ratio"), String("widget_0"), String("1:1"))
    var mp = first_number_field(node, String("megapixels"), String("mp"), String("widget_1"), 1.0)
    var ratio = _aspect_ratio_value(ratio_text)
    var pixels = mp * 1048576.0
    var width = Int32(sqrt(pixels * ratio))
    var height = Int32(sqrt(pixels / ratio))
    width = _round_dim8(width)
    height = _round_dim8(height)
    result.add_value(WorkflowValue.number_value(node.id, String("width"), String(width)))
    result.add_value(WorkflowValue.number_value(node.id, String("height"), String(height)))
    result.add_log(String("resolution_selector ") + String(width) + String("x") + String(height))
    return True


def execute_ksampler_config(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var steps = first_int_field(node, String("steps_total"), String("steps"), String("widget_0"), Int32(30))
    var refiner = first_int_field(node, String("refiner_step"), String("widget_1"), String(""), Int32(24))
    var cfg = first_number_field(node, String("cfg"), String("widget_2"), String(""), 8.0)
    var sampler = first_string_field(node, String("sampler_name"), String("sampler"), String("widget_3"), String("euler"))
    var scheduler = first_string_field(node, String("scheduler"), String("widget_4"), String(""), String("normal"))
    result.add_value(WorkflowValue.number_value(node.id, String("STEPS"), String(steps)))
    result.add_value(WorkflowValue.number_value(node.id, String("REFINER_STEP"), String(refiner)))
    result.add_value(WorkflowValue.number_value(node.id, String("CFG"), String(cfg)))
    result.add_value(WorkflowValue.text_value(node.id, String("SAMPLER"), sampler))
    result.add_value(WorkflowValue.text_value(node.id, String("SCHEDULER"), scheduler))
    result.add_log(String("ksampler_config ") + sampler + String("/") + scheduler)
    return True


def execute_upscale_model_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var name = first_string_field(node, String("model_name"), String("upscale_model"), String("widget_0"), String("upscale_model.pth"))
    add_handle_outputs(node, result, NVT_MODEL, WV_MODEL, String("UPSCALE_MODEL"), String("upscale_model:") + name)
    result.add_log(String("upscale_model_loader ") + name)
    return True


def execute_image_transform(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("image"))
    if image.kind != WV_IMAGE:
        image = incoming_value(graph, result, node.id, String("images"))
    var width = image.width
    var height = image.height
    if node_matches(node, String("imagescale")) and not node_matches(node, String("imagescaleby")):
        width = first_int_field(node, String("width"), String("widget_1"), String(""), width)
        height = first_int_field(node, String("height"), String("widget_2"), String(""), height)
    elif node_matches(node, String("imagescaleby")):
        var scale = first_number_field(node, String("scale_by"), String("scale"), String("widget_1"), 1.0)
        width = Int32(Float64(width) * scale)
        height = Int32(Float64(height) * scale)
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    result.add_value(WorkflowValue.image_path(node.id, first_output_name(node, String("IMAGE")), image.path, width, height, image.seed))
    result.add_log(String("image_transform ") + node.title + String(" ") + String(width) + String("x") + String(height))
    return True


def execute_text_passthrough(node: Node, mut result: WorkflowExecutionResult, output_port: String) raises -> Bool:
    var text = prompt_from_node(node)
    if text.byte_length() == 0:
        text = first_string_field(node, String("widget_0"), String("text"), String("prompt"), String(""))
    result.add_value(WorkflowValue.text_value(node.id, output_port, text))
    result.add_log(String("text ") + node.title)
    return True


def _aspect_ratio_value(ratio: String) -> Float64:
    if ratio == String("16:9"):
        return 16.0 / 9.0
    if ratio == String("9:16"):
        return 9.0 / 16.0
    if ratio == String("4:3"):
        return 4.0 / 3.0
    if ratio == String("3:4"):
        return 3.0 / 4.0
    if ratio == String("3:2"):
        return 3.0 / 2.0
    if ratio == String("2:3"):
        return 2.0 / 3.0
    return 1.0


def _round_dim8(value: Int32) -> Int32:
    if value < Int32(8):
        return Int32(8)
    var rem = value % Int32(8)
    return value - rem
