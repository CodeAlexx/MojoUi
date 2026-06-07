"""Ideogram/Serenity prompt-builder node executors."""

from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.nodes.port import NVT_IMAGE
from mojoui.app.workflow_render import apply_magic_prompt
from mojoui.app.workflow_types import (
    WorkflowArtifact,
    WorkflowExecutionResult,
    WorkflowLaunchAction,
    WorkflowValue,
    WV_BBOX,
    WLS_LAUNCHED,
    WLS_STAGED,
)
from mojoui.app.workflow_support import (
    first_output_name,
    first_string_field,
    gpu_command,
    has_output_kind,
    i64_field,
    incoming_value,
    int_field,
    node_matches,
    output_name_or,
    string_field,
)
from mojoui.serde.json import (
    JsonValue,
    JK_ARRAY,
    JK_BOOL,
    JK_NUMBER,
    JK_OBJECT,
    JK_STRING,
    emit_json,
    parse_json,
)


def is_ideogram_node(node: Node) -> Bool:
    return (
        node_matches(node, String("ideogram4_prompt_builder"))
        or node_matches(node, String("ideogram prompt builder"))
        or node_matches(node, String("ideogram4_magic_prompt"))
        or node_matches(node, String("magic_prompt"))
        or node_matches(node, String("ideogram4_generate"))
        or (node_matches(node, String("ideogram")) and has_output_kind(node, NVT_IMAGE))
    )


def execute_ideogram_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if node_matches(node, String("ideogram4_prompt_builder")) or node_matches(node, String("ideogram prompt builder")):
        return execute_ideogram_prompt_builder(graph, node, result)
    if node_matches(node, String("ideogram4_magic_prompt")) or node_matches(node, String("magic_prompt")):
        return execute_ideogram_magic(graph, node, result)
    if node_matches(node, String("ideogram4_generate")) or (
        node_matches(node, String("ideogram")) and has_output_kind(node, NVT_IMAGE)
    ):
        return execute_ideogram_generate(graph, node, result)
    return False


def execute_ideogram_prompt_builder(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var width = int_field(node, String("width"), result.request.width)
    var height = int_field(node, String("height"), result.request.height)
    var import_value = incoming_value(graph, result, node.id, String("import_json"))
    var import_json = import_value.text.copy()
    if import_json.byte_length() == 0:
        import_json = string_field(node, String("import_json"), String(""))
    var elements_data = string_field(node, String("elements_data"), String(""))
    var prompt = import_json.copy()
    if elements_data.byte_length() != 0 or import_json.byte_length() == 0:
        prompt = build_ideogram_prompt_builder_caption(node, elements_data)
    var incoming_boxes = incoming_value(graph, result, node.id, String("bboxes"))
    var bboxes_out = build_prompt_builder_bboxes(elements_data, width, height)
    if bboxes_out.byte_length() == 0 and incoming_boxes.kind == WV_BBOX:
        bboxes_out = incoming_boxes.text.copy()

    var image = incoming_value(graph, result, node.id, String("image"))
    result.add_value(
        WorkflowValue.text_value(
            node.id,
            output_name_or(node, String("prompt"), String("prompt")),
            prompt,
        )
    )
    result.add_value(
        WorkflowValue.image_path(
            node.id,
            output_name_or(node, String("preview"), String("preview")),
            image.path,
            width,
            height,
            -1,
        )
    )
    result.add_value(
        WorkflowValue.bbox_json(
            node.id,
            output_name_or(node, String("bboxes"), String("bboxes")),
            bboxes_out,
        )
    )
    result.add_value(
        WorkflowValue.number_value(
            node.id,
            output_name_or(node, String("width"), String("width")),
            String(width),
        )
    )
    result.add_value(
        WorkflowValue.number_value(
            node.id,
            output_name_or(node, String("height"), String("height")),
            String(height),
        )
    )
    result.add_log(
        String("ideogram_prompt_builder ")
        + String(width)
        + String("x")
        + String(height)
        + String(" boxes=")
        + String(prompt_builder_box_count(elements_data))
    )
    return True


def execute_ideogram_magic(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var input = incoming_value(graph, result, node.id, String("prompt"))
    var prompt = input.text.copy()
    if prompt.byte_length() == 0:
        prompt = first_string_field(node, String("prompt"), String("positive"), String("text"), String(""))
    if prompt.byte_length() == 0:
        prompt = result.request.prompt.copy()
    var request = result.request.copy()
    request.prompt = prompt.copy()
    var magic = apply_magic_prompt(request)
    var out_port = first_output_name(node, String("caption_json"))
    var entry = first_string_field(
        node,
        String("entry"),
        String("pipeline"),
        String("magic_prompt_entry"),
        result.request.magic_prompt_entry,
    )
    var status = WLS_STAGED
    if not result.device.dry_run:
        status = WLS_LAUNCHED
    result.add_launch(
        WorkflowLaunchAction(
            node.id,
            String("ideogram4_magic_prompt"),
            entry,
            result.device.device_kind,
            result.device.device_index,
            gpu_command(entry, result.device, String(""), 0, 0, -1),
            String(""),
            status,
            result.device.dry_run,
        )
    )
    result.add_value(WorkflowValue.text_value(node.id, out_port, magic.prompt))
    result.add_log(
        String("gpu magic_prompt ")
        + node.title
        + String(" device=")
        + result.device.device_kind
        + String(":")
        + String(result.device.device_index)
    )
    return True


def execute_ideogram_generate(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var caption = incoming_value(graph, result, node.id, String("caption_json"))
    var prompt = caption.text.copy()
    if prompt.byte_length() == 0:
        var magic = apply_magic_prompt(result.request)
        prompt = magic.prompt.copy()
    var output_path = first_string_field(
        node,
        String("output_path"),
        String("path"),
        String("filename_prefix"),
        result.request.output_path,
    )
    var width = int_field(node, String("width"), result.request.width)
    var height = int_field(node, String("height"), result.request.height)
    var seed = i64_field(node, String("seed"), result.request.seed)
    var out_port = first_output_name(node, String("image"))
    var entry = first_string_field(
        node,
        String("entry"),
        String("pipeline"),
        String("generate_entry"),
        result.request.generate_entry,
    )
    var command = gpu_command(
        entry,
        result.device,
        output_path,
        width,
        height,
        seed,
    )
    var status = WLS_STAGED
    if not result.device.dry_run:
        status = WLS_LAUNCHED
    result.add_launch(
        WorkflowLaunchAction(
            node.id,
            String("ideogram4"),
            entry,
            result.device.device_kind,
            result.device.device_index,
            command,
            output_path,
            status,
            result.device.dry_run,
        )
    )
    result.add_value(WorkflowValue.image_path(node.id, out_port, output_path, width, height, seed))
    result.add_artifact(WorkflowArtifact(node.id, String("image"), output_path, String("Ideogram4 image")))
    result.add_log(
        String("gpu ideogram_generate ")
        + String(width)
        + String("x")
        + String(height)
        + String(" device=")
        + result.device.device_kind
        + String(":")
        + String(result.device.device_index)
    )
    if prompt.byte_length() == 0:
        result.add_log(String("ideogram_generate used empty prompt"))
    return True


def json_object_string(value: JsonValue, key: String, fallback: String) -> String:
    if value.kind != JK_OBJECT:
        return fallback.copy()
    var field = value.get_object_field(key)
    if field.kind == JK_STRING:
        return field.str_val.copy()
    return fallback.copy()


def json_object_bool(value: JsonValue, key: String, fallback: Bool) -> Bool:
    if value.kind != JK_OBJECT:
        return fallback
    var field = value.get_object_field(key)
    if field.kind == JK_BOOL:
        return field.bool_val
    return fallback


def json_object_number(value: JsonValue, key: String, fallback: Float64) -> Float64:
    if value.kind != JK_OBJECT:
        return fallback
    var field = value.get_object_field(key)
    if field.kind == JK_NUMBER:
        return field.num_val
    return fallback


def parse_json_array_or_empty(raw: String) raises -> JsonValue:
    if raw.byte_length() == 0:
        return JsonValue.empty_array()
    try:
        var parsed = parse_json(raw)
        if parsed.kind == JK_ARRAY:
            return parsed^
    except e:
        return JsonValue.empty_array()
    return JsonValue.empty_array()


def append_palette_from_json(mut elem: JsonValue, palette: JsonValue, limit: Int):
    if palette.kind != JK_ARRAY:
        return
    var colors = List[JsonValue]()
    for i in range(len(palette.arr_val)):
        if i >= limit:
            break
        var c = palette.arr_val[i].copy()
        if c.kind == JK_STRING and c.str_val.byte_length() > 0:
            colors.append(JsonValue.string(c.str_val))
    if len(colors) > 0:
        elem.set_object_field(String("color_palette"), JsonValue.array(colors^))


def normalized_bbox_json(box: JsonValue) -> JsonValue:
    var x = json_object_number(box, String("x"), 0.0)
    var y = json_object_number(box, String("y"), 0.0)
    var w = json_object_number(box, String("w"), 0.0)
    var h = json_object_number(box, String("h"), 0.0)
    var ymin = clamp_1000(y)
    var xmin = clamp_1000(x)
    var ymax = clamp_1000(y + h)
    var xmax = clamp_1000(x + w)
    if ymin > ymax:
        var tmp = ymin
        ymin = ymax
        ymax = tmp
    if xmin > xmax:
        var tmp_x = xmin
        xmin = xmax
        xmax = tmp_x
    var arr = List[JsonValue]()
    arr.append(JsonValue.number(Float64(ymin)))
    arr.append(JsonValue.number(Float64(xmin)))
    arr.append(JsonValue.number(Float64(ymax)))
    arr.append(JsonValue.number(Float64(xmax)))
    return JsonValue.array(arr^)


def clamp_1000(v: Float64) -> Int64:
    var out = Int64(v * 1000.0 + 0.5)
    if out < Int64(0):
        out = Int64(0)
    if out > Int64(1000):
        out = Int64(1000)
    return out


def pixel_dim(v: Float64, dim: Int32) -> Int64:
    var out = Int64(v * Float64(dim) + 0.5)
    if out < Int64(0):
        out = -out
    return out


def build_ideogram_prompt_builder_caption(node: Node, elements_data: String) raises -> String:
    var caption = JsonValue.empty_object()
    var high = string_field(node, String("high_level_description"), String(""))
    if high.byte_length() > 0:
        caption.set_object_field(String("high_level_description"), JsonValue.string(high))

    var style = string_field(node, String("style"), String("none"))
    if style != String("none"):
        var sd = JsonValue.empty_object()
        sd.set_object_field(String("aesthetics"), JsonValue.string(string_field(node, String("aesthetics"), String(""))))
        sd.set_object_field(String("lighting"), JsonValue.string(string_field(node, String("lighting"), String(""))))
        sd.set_object_field(String("medium"), JsonValue.string(string_field(node, String("medium"), String(""))))
        if style == String("photo"):
            sd.set_object_field(String("photo"), JsonValue.string(string_field(node, String("photo"), String(""))))
        else:
            sd.set_object_field(String("art_style"), JsonValue.string(string_field(node, String("art_style"), String(""))))
        var style_palette = parse_json_array_or_empty(string_field(node, String("style_palette_data"), String("")))
        append_palette_from_json(sd, style_palette, 8)
        caption.set_object_field(String("style_description"), sd)

    var boxes = parse_json_array_or_empty(elements_data)
    var elems = List[JsonValue]()
    for i in range(len(boxes.arr_val)):
        var box = boxes.arr_val[i].copy()
        if box.kind != JK_OBJECT:
            continue
        var etype = json_object_string(box, String("type"), String("obj"))
        if etype != String("text"):
            etype = String("obj")
        var elem = JsonValue.empty_object()
        elem.set_object_field(String("type"), JsonValue.string(etype))
        if not json_object_bool(box, String("nobbox"), False):
            elem.set_object_field(String("bbox"), normalized_bbox_json(box))
        if etype == String("text"):
            elem.set_object_field(String("text"), JsonValue.string(json_object_string(box, String("text"), String(""))))
        elem.set_object_field(String("desc"), JsonValue.string(json_object_string(box, String("desc"), String(""))))
        append_palette_from_json(elem, box.get_object_field(String("palette")), 5)
        elems.append(elem^)

    var comp = JsonValue.empty_object()
    comp.set_object_field(String("background"), JsonValue.string(string_field(node, String("background"), String(""))))
    comp.set_object_field(String("elements"), JsonValue.array(elems^))
    caption.set_object_field(String("compositional_deconstruction"), comp)
    return emit_json(caption)


def build_prompt_builder_bboxes(elements_data: String, width: Int32, height: Int32) raises -> String:
    var boxes = parse_json_array_or_empty(elements_data)
    var frame = List[JsonValue]()
    for i in range(len(boxes.arr_val)):
        var box = boxes.arr_val[i].copy()
        if box.kind != JK_OBJECT:
            continue
        if json_object_bool(box, String("nobbox"), False):
            continue
        var x = json_object_number(box, String("x"), 0.0)
        var y = json_object_number(box, String("y"), 0.0)
        var w = json_object_number(box, String("w"), 0.0)
        var h = json_object_number(box, String("h"), 0.0)
        if w < 0.0:
            x = x + w
            w = -w
        if h < 0.0:
            y = y + h
            h = -h
        var bb = JsonValue.empty_object()
        bb.set_object_field(String("x"), JsonValue.number(Float64(pixel_dim(x, width))))
        bb.set_object_field(String("y"), JsonValue.number(Float64(pixel_dim(y, height))))
        bb.set_object_field(String("width"), JsonValue.number(Float64(pixel_dim(w, width))))
        bb.set_object_field(String("height"), JsonValue.number(Float64(pixel_dim(h, height))))
        frame.append(bb^)
    if len(frame) == 0:
        return String("")
    var outer = List[JsonValue]()
    outer.append(JsonValue.array(frame^))
    return emit_json(JsonValue.array(outer^))


def prompt_builder_box_count(elements_data: String) raises -> Int:
    var boxes = parse_json_array_or_empty(elements_data)
    return len(boxes.arr_val)
