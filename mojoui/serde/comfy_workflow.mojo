"""ComfyUI workflow JSON import.

This is a compatibility loader for Comfy/LiteGraph workflow files. It maps
the visual workflow shape (`nodes`, `links`, `groups`) into MojoUI's reusable
`Graph` plus `CanvasState` without changing MojoUI's native workflow schema.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import RetainedId
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node, PortRef, FieldValue
from mojoui.nodes.port import (
    NVT_LATENT,
    NVT_IMAGE,
    NVT_CONDITIONING,
    NVT_MODEL,
    NVT_VAE,
    NVT_CLIP,
    NVT_LORA,
    NVT_NUMBER,
    NVT_TEXT,
    NVT_SEED,
    NVT_BOOL,
    NVT_VIDEO,
    NVT_BBOX,
    NVT_COUNT,
)
from mojoui.nodes.canvas_model import CanvasState, CanvasGroup
from mojoui.serde.json import (
    JsonValue,
    JK_NULL,
    JK_BOOL,
    JK_NUMBER,
    JK_STRING,
    JK_ARRAY,
    JK_OBJECT,
    emit_json,
    parse_json,
)


struct ComfyWorkflowImport(Movable):
    """Result of importing a Comfy visual workflow."""

    var graph: Graph
    var canvas: CanvasState

    def __init__(out self, var graph: Graph, var canvas: CanvasState):
        self.graph = graph^
        self.canvas = canvas^

    def take_graph(mut self) -> Graph:
        var out = self.graph^
        self.graph = Graph()
        return out^

    def take_canvas(mut self) -> CanvasState:
        var out = self.canvas^
        self.canvas = CanvasState()
        return out^


def parse_comfy_workflow(raw: String) raises -> ComfyWorkflowImport:
    """Parse a ComfyUI/LiteGraph workflow JSON string.

    Supported shape:
      - top-level `nodes`: array of visual nodes;
      - top-level `workflow`: SwarmUI wrapper around a visual workflow;
      - Comfy API prompt object keyed by node id with `class_type`/`inputs`;
      - top-level `links`: array of `[id, from_node, from_slot, to_node,
        to_slot, type]`;
      - top-level `groups`: array with `bounding: [x, y, w, h]`.

    The importer preserves node arrangement and creates explicit MojoUI group
    membership by intersecting node rectangles with each Comfy group bound.
    """
    var root = parse_json(raw)
    if root.kind != JK_OBJECT:
        raise Error("Comfy workflow root must be an object")
    var wrapped = root.get_object_field(String("workflow"))
    if wrapped.kind == JK_OBJECT:
        root = wrapped^
    var nodes_val = root.get_object_field(String("nodes"))

    var graph = Graph()
    var canvas = CanvasState()
    if nodes_val.kind == JK_ARRAY:
        _parse_comfy_nodes(nodes_val, graph)
        _seed_graph_allocator(graph)
        _parse_comfy_links(root.get_object_field(String("links")), graph)
        _parse_comfy_groups(root.get_object_field(String("groups")), canvas, graph)
    else:
        _parse_comfy_api_prompt(root, graph, canvas)
    return ComfyWorkflowImport(graph^, canvas^)


def _json_number(value: JsonValue, fallback: Float64) -> Float64:
    if value.kind == JK_NUMBER:
        return value.num_val
    return fallback


def _json_i64(value: JsonValue, fallback: Int64) -> Int64:
    if value.kind == JK_NUMBER:
        return Int64(value.num_val)
    return fallback


def _json_bool(value: JsonValue, fallback: Bool) -> Bool:
    if value.kind == JK_BOOL:
        return value.bool_val
    return fallback


def _json_string(value: JsonValue, fallback: String) -> String:
    if value.kind == JK_STRING:
        return value.str_val.copy()
    return fallback.copy()


def _array_number(value: JsonValue, index: Int, fallback: Float64) -> Float64:
    if value.kind == JK_ARRAY:
        if index < 0 or index >= len(value.arr_val):
            return fallback
        return _json_number(value.arr_val[index].copy(), fallback)
    if value.kind == JK_OBJECT:
        return _json_number(value.get_object_field(String(index)), fallback)
    return fallback


def _field_from_json(value: JsonValue) -> FieldValue:
    if value.kind == JK_NUMBER:
        return FieldValue.number(value.num_val)
    if value.kind == JK_STRING:
        return FieldValue.string(value.str_val)
    if value.kind == JK_BOOL:
        return FieldValue.bool_(value.bool_val)
    if value.kind == JK_NULL:
        return FieldValue()
    return FieldValue.string(emit_json(value))


def _comfy_type_to_nvt(type_name: String) -> Int32:
    if type_name == String("LATENT") or type_name == String("latent"):
        return NVT_LATENT
    if type_name == String("IMAGE") or type_name == String("image"):
        return NVT_IMAGE
    if type_name == String("MASK") or type_name == String("mask"):
        return NVT_IMAGE
    if type_name == String("CONDITIONING") or type_name == String("conditioning"):
        return NVT_CONDITIONING
    if type_name == String("MODEL") or type_name == String("model"):
        return NVT_MODEL
    if type_name == String("VAE") or type_name == String("vae"):
        return NVT_VAE
    if type_name == String("CLIP") or type_name == String("clip"):
        return NVT_CLIP
    if type_name == String("LORA") or type_name == String("lora"):
        return NVT_LORA
    if (
        type_name == String("INT")
        or type_name == String("FLOAT")
        or type_name == String("NUMBER")
        or type_name == String("COMBO")
        or type_name == String("int")
        or type_name == String("float")
        or type_name == String("number")
        or type_name == String("combo")
    ):
        return NVT_NUMBER
    if type_name == String("STRING") or type_name == String("TEXT") or type_name == String("string") or type_name == String("text"):
        return NVT_TEXT
    if (
        type_name == String("SAMPLER")
        or type_name == String("GUIDER")
        or type_name == String("NOISE")
        or type_name == String("sampler")
        or type_name == String("guider")
        or type_name == String("noise")
    ):
        return NVT_TEXT
    if type_name == String("SIGMAS") or type_name == String("sigmas"):
        return NVT_NUMBER
    if type_name == String("SEED") or type_name == String("seed"):
        return NVT_SEED
    if type_name == String("BOOLEAN") or type_name == String("BOOL") or type_name == String("boolean") or type_name == String("bool"):
        return NVT_BOOL
    if type_name == String("VIDEO") or type_name == String("video"):
        return NVT_VIDEO
    if (
        type_name == String("AUDIO")
        or type_name == String("VHS_AUDIO")
        or type_name == String("VHS_VIDEOINFO")
        or type_name == String("VHS_FILENAMES")
        or type_name == String("VHS_BatchManager")
        or type_name == String("audio")
        or type_name == String("vhs_audio")
        or type_name == String("vhs_videoinfo")
        or type_name == String("vhs_filenames")
        or type_name == String("vhs_batchmanager")
        or type_name == String("*")
    ):
        return NVT_TEXT
    if (
        type_name == String("BBOX")
        or type_name == String("bbox")
        or type_name == String("BOUNDINGBOX")
        or type_name == String("BoundingBox")
        or type_name == String("boundingbox")
    ):
        return NVT_BBOX
    return NVT_COUNT


def _parse_comfy_nodes(nodes_val: JsonValue, mut graph: Graph) raises:
    for i in range(len(nodes_val.arr_val)):
        var node_val = nodes_val.arr_val[i].copy()
        if node_val.kind != JK_OBJECT:
            continue
        var id_num = _json_i64(node_val.get_object_field(String("id")), Int64(i + 1))
        if id_num < Int64(1):
            id_num = Int64(i + 1)
        var comfy_type = _json_string(node_val.get_object_field(String("type")), String("Unknown"))
        var node = Node(RetainedId(id_num), String("comfy/") + comfy_type)

        var title = _json_string(node_val.get_object_field(String("title")), comfy_type.copy())
        node.title = title.copy()

        var pos = node_val.get_object_field(String("pos"))
        node.position = Vec2(
            Float32(_array_number(pos, 0, 0.0)),
            Float32(_array_number(pos, 1, 0.0)),
        )
        var size = node_val.get_object_field(String("size"))
        if size.kind == JK_ARRAY or size.kind == JK_OBJECT:
            node.size = Vec2(
                Float32(_array_number(size, 0, Float64(node.size.x))),
                Float32(_array_number(size, 1, Float64(node.size.y))),
            )

        var flags = node_val.get_object_field(String("flags"))
        if flags.kind == JK_OBJECT:
            node.collapsed = _json_bool(flags.get_object_field(String("collapsed")), node.collapsed)
            node.pinned = _json_bool(flags.get_object_field(String("pinned")), node.pinned)
        var mode_val = node_val.get_object_field(String("mode"))
        if mode_val.kind == JK_NUMBER and Int(mode_val.num_val) == 2:
            node.muted = True

        _parse_comfy_ports(node, node_val.get_object_field(String("inputs")), True)
        _parse_comfy_ports(node, node_val.get_object_field(String("outputs")), False)
        node.set_field(String("comfy_type"), FieldValue.string(comfy_type.copy()))
        var order_val = node_val.get_object_field(String("order"))
        if order_val.kind == JK_NUMBER:
            node.set_field(String("comfy_order"), FieldValue.number(order_val.num_val))
        _parse_comfy_widget_values(node, node_val.get_object_field(String("widgets_values")))
        _parse_comfy_properties(node, node_val.get_object_field(String("properties")))

        graph.nodes.append(node^)


def _parse_comfy_api_prompt(root: JsonValue, mut graph: Graph, mut canvas: CanvasState) raises:
    """Import Comfy API prompt JSON: `{ "1": {"class_type": ..., "inputs": ...} }`.

    API prompts do not carry canvas coordinates or socket declarations, so this
    builds a deterministic grid layout and infers common Comfy socket types
    from node class names and input names.
    """
    var node_keys = List[String]()
    for i in range(len(root.obj_keys)):
        var key = root.obj_keys[i].copy()
        var node_val = root.obj_values[i].copy()
        if node_val.kind != JK_OBJECT:
            continue
        var class_val = node_val.get_object_field(String("class_type"))
        if class_val.kind == JK_STRING:
            node_keys.append(key^)
    if len(node_keys) == 0:
        raise Error("Comfy workflow must contain visual nodes or API prompt nodes")

    for i in range(len(node_keys)):
        var key = node_keys[i].copy()
        var node_val = root.get_object_field(key)
        var class_type = _json_string(node_val.get_object_field(String("class_type")), String("Unknown"))
        var id_num = _parse_id_string(key, Int64(i + 1))
        if id_num < Int64(1):
            id_num = Int64(i + 1)
        var node = Node(RetainedId(id_num), String("comfy/") + class_type)
        var meta = node_val.get_object_field(String("_meta"))
        node.title = _json_string(meta.get_object_field(String("title")), class_type.copy())
        node.position = Vec2(Float32(80 + (i % 5) * 390), Float32(80 + (i / 5) * 220))
        node.size = _default_api_node_size(class_type)
        node.set_field(String("comfy_type"), FieldValue.string(class_type.copy()))

        var inputs = node_val.get_object_field(String("inputs"))
        if inputs.kind == JK_OBJECT:
            _parse_api_node_inputs(node, inputs)
        _add_api_outputs(node, class_type)
        graph.nodes.append(node^)

    _seed_graph_allocator(graph)
    _parse_api_edges(root, graph)
    var rows = (len(node_keys) + 4) / 5
    var bounds = Rect(40.0, 40.0, Float32(5 * 390), Float32(rows * 220 + 120))
    var group = CanvasGroup(Int64(1), String("Comfy API Workflow"), bounds, Color(68, 110, 180, 70))
    for i in range(graph.node_count()):
        group.members.append(graph.nodes[i].id)
    canvas.groups.append(group^)
    canvas.next_group_id = Int64(2)


def _parse_api_node_inputs(mut node: Node, inputs: JsonValue):
    for i in range(len(inputs.obj_keys)):
        var key = inputs.obj_keys[i].copy()
        var value = inputs.obj_values[i].copy()
        if _is_api_link(value):
            node.add_input(PortRef(key.copy(), _infer_port_type_from_name(key)))
        else:
            node.set_field(key, _field_from_json(value))


def _parse_api_edges(root: JsonValue, mut graph: Graph):
    for i in range(len(root.obj_keys)):
        var key = root.obj_keys[i].copy()
        var node_val = root.obj_values[i].copy()
        if node_val.kind != JK_OBJECT:
            continue
        var class_val = node_val.get_object_field(String("class_type"))
        if class_val.kind != JK_STRING:
            continue
        var to_node = RetainedId(_parse_id_string(key, Int64(0)))
        if to_node == RetainedId(0):
            continue
        var inputs = node_val.get_object_field(String("inputs"))
        if inputs.kind != JK_OBJECT:
            continue
        for pi in range(len(inputs.obj_keys)):
            var port_name = inputs.obj_keys[pi].copy()
            var value = inputs.obj_values[pi].copy()
            if not _is_api_link(value):
                continue
            var from_node = RetainedId(_api_link_node_id(value))
            var from_slot = _api_link_slot(value)
            if from_node == RetainedId(0):
                continue
            var from_port = _port_name_by_slot(graph, from_node, from_slot, True)
            _ = graph.add_edge(from_node, from_port, to_node, port_name)


def _is_api_link(value: JsonValue) -> Bool:
    if value.kind != JK_ARRAY or len(value.arr_val) < 2:
        return False
    var node_ref = value.arr_val[0].copy()
    var slot_ref = value.arr_val[1].copy()
    return (node_ref.kind == JK_STRING or node_ref.kind == JK_NUMBER) and slot_ref.kind == JK_NUMBER


def _api_link_node_id(value: JsonValue) -> Int64:
    if value.kind != JK_ARRAY or len(value.arr_val) < 1:
        return Int64(0)
    var node_ref = value.arr_val[0].copy()
    if node_ref.kind == JK_NUMBER:
        return Int64(node_ref.num_val)
    if node_ref.kind == JK_STRING:
        return _parse_id_string(node_ref.str_val, Int64(0))
    return Int64(0)


def _api_link_slot(value: JsonValue) -> Int:
    if value.kind != JK_ARRAY or len(value.arr_val) < 2:
        return 0
    return Int(_json_i64(value.arr_val[1].copy(), Int64(0)))


def _parse_id_string(text: String, fallback: Int64) -> Int64:
    var n = text.byte_length()
    if n == 0:
        return fallback
    var ptr = text.unsafe_ptr()
    var i = 0
    var value = Int64(0)
    while i < n:
        var c = ptr[i]
        if c < UInt8(48) or c > UInt8(57):
            return fallback
        value = value * Int64(10) + Int64(c - UInt8(48))
        i = i + 1
    return value


def _default_api_node_size(class_type: String) -> Vec2:
    if _contains_ci(class_type, String("sampler")):
        return Vec2(360.0, 260.0)
    if _contains_ci(class_type, String("textencode")):
        return Vec2(420.0, 180.0)
    if _contains_ci(class_type, String("saveimage")):
        return Vec2(320.0, 180.0)
    return Vec2(320.0, 130.0)


def _add_api_outputs(mut node: Node, class_type: String):
    if _contains_ci(class_type, String("vhs_loadvideoffmpeg")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("mask"), NVT_IMAGE))
        node.add_output(PortRef(String("audio"), NVT_TEXT))
        node.add_output(PortRef(String("video_info"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_loadvideo")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("frame_count"), NVT_NUMBER))
        node.add_output(PortRef(String("audio"), NVT_TEXT))
        node.add_output(PortRef(String("video_info"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_loadimages")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("MASK"), NVT_IMAGE))
        node.add_output(PortRef(String("frame_count"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_loadimagepath")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("mask"), NVT_IMAGE))
    elif _contains_ci(class_type, String("vhs_videocombine")):
        node.add_output(PortRef(String("Filenames"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_batchmanager")):
        node.add_output(PortRef(String("VHS_BatchManager"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_videoinfo")):
        _add_vhs_video_info_outputs(node, class_type)
    elif _contains_ci(class_type, String("vhs_selectfilename")) or _contains_ci(class_type, String("vhs_selectlatest")):
        node.add_output(PortRef(String("Filename"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_loadaudio")):
        node.add_output(PortRef(String("audio"), NVT_TEXT))
        node.add_output(PortRef(String("duration"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_audiotovhsaudio")) or _contains_ci(class_type, String("vhs_vhsaudiotoaudio")):
        node.add_output(PortRef(String("audio"), NVT_TEXT))
    elif _contains_ci(class_type, String("vhs_vaedecodebatched")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    elif _contains_ci(class_type, String("vhs_vaeencodebatched")):
        node.add_output(PortRef(String("LATENT"), NVT_LATENT))
    elif _contains_ci(class_type, String("vhs_splitlatents")):
        _add_vhs_split_outputs(node, NVT_LATENT, String("LATENT"))
    elif _contains_ci(class_type, String("vhs_splitimages")) or _contains_ci(class_type, String("vhs_splitmasks")):
        _add_vhs_split_outputs(node, NVT_IMAGE, String("IMAGE"))
    elif _contains_ci(class_type, String("vhs_mergelatents")) or _contains_ci(class_type, String("vhs_duplicatelatents")) or _contains_ci(class_type, String("vhs_selecteverynthlatent")) or _contains_ci(class_type, String("vhs_selectlatents")):
        node.add_output(PortRef(String("LATENT"), NVT_LATENT))
        node.add_output(PortRef(String("count"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_mergeimages")) or _contains_ci(class_type, String("vhs_duplicateimages")) or _contains_ci(class_type, String("vhs_selecteverynthimage")) or _contains_ci(class_type, String("vhs_selectimages")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("count"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_mergemasks")) or _contains_ci(class_type, String("vhs_duplicatemasks")) or _contains_ci(class_type, String("vhs_selecteverynthmask")) or _contains_ci(class_type, String("vhs_selectmasks")):
        node.add_output(PortRef(String("MASK"), NVT_IMAGE))
        node.add_output(PortRef(String("count"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_getlatentcount")) or _contains_ci(class_type, String("vhs_getimagecount")) or _contains_ci(class_type, String("vhs_getmaskcount")):
        node.add_output(PortRef(String("count"), NVT_NUMBER))
    elif _contains_ci(class_type, String("vhs_unbatch")):
        node.add_output(PortRef(String("unbatched"), NVT_TEXT))
    elif _contains_ci(class_type, String("ltxvsampler")):
        node.add_output(PortRef(String("frames"), NVT_IMAGE))
        node.add_output(PortRef(String("video"), NVT_VIDEO))
        node.add_output(PortRef(String("audio"), NVT_TEXT))
    elif _contains_ci(class_type, String("ltxvloraloader")):
        node.add_output(PortRef(String("LTXV_MODEL"), NVT_MODEL))
    elif _contains_ci(class_type, String("ltxvloader")):
        node.add_output(PortRef(String("LTXV_MODEL"), NVT_MODEL))
    elif _contains_ci(class_type, String("checkpointloader")):
        node.add_output(PortRef(String("MODEL"), NVT_MODEL))
        node.add_output(PortRef(String("CLIP"), NVT_CLIP))
        node.add_output(PortRef(String("VAE"), NVT_VAE))
    elif _contains_ci(class_type, String("loraloadermodelonly")):
        node.add_output(PortRef(String("MODEL"), NVT_MODEL))
    elif _contains_ci(class_type, String("loraloader")) or _contains_ci(class_type, String("powerlora")) or _contains_ci(class_type, String("loraloaderstack")):
        node.add_output(PortRef(String("MODEL"), NVT_MODEL))
        node.add_output(PortRef(String("CLIP"), NVT_CLIP))
    elif _contains_ci(class_type, String("unetloader")) or _contains_ci(class_type, String("diffusionmodelloader")):
        node.add_output(PortRef(String("MODEL"), NVT_MODEL))
    elif _contains_ci(class_type, String("cliploader")) or _contains_ci(class_type, String("dualcliploader")) or _contains_ci(class_type, String("triplecliploader")):
        node.add_output(PortRef(String("CLIP"), NVT_CLIP))
    elif _contains_ci(class_type, String("vaeloader")):
        node.add_output(PortRef(String("VAE"), NVT_VAE))
    elif _contains_ci(class_type, String("controlnetloader")):
        node.add_output(PortRef(String("CONTROL_NET"), NVT_MODEL))
    elif _contains_ci(class_type, String("power prompt")):
        node.add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
        if not _contains_ci(class_type, String("simple")):
            node.add_output(PortRef(String("MODEL"), NVT_MODEL))
            node.add_output(PortRef(String("CLIP"), NVT_CLIP))
        node.add_output(PortRef(String("TEXT"), NVT_TEXT))
    elif _contains_ci(class_type, String("condpassthrough")):
        node.add_output(PortRef(String("positive"), NVT_CONDITIONING))
        node.add_output(PortRef(String("negative"), NVT_CONDITIONING))
    elif _contains_ci(class_type, String("modelpassthrough")):
        node.add_output(PortRef(String("MODEL"), NVT_MODEL))
    elif _contains_ci(class_type, String("conditioningcombine")) or _contains_ci(class_type, String("conditioningmulticombine")) or _contains_ci(class_type, String("conditioningsetmaskandcombine")):
        node.add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    elif _contains_ci(class_type, String("seed")):
        node.add_output(PortRef(String("SEED"), NVT_SEED))
    elif _contains_ci(class_type, String("intconstant")):
        node.add_output(PortRef(String("INT"), NVT_NUMBER))
    elif _contains_ci(class_type, String("floatconstant")):
        node.add_output(PortRef(String("FLOAT"), NVT_NUMBER))
    elif _contains_ci(class_type, String("boolconstant")):
        node.add_output(PortRef(String("BOOLEAN"), NVT_BOOL))
    elif _contains_ci(class_type, String("stringconstant")):
        node.add_output(PortRef(String("STRING"), NVT_TEXT))
    elif _contains_ci(class_type, String("joinstrings")) or _contains_ci(class_type, String("somethingtostring")) or _contains_ci(class_type, String("widgettostring")):
        node.add_output(PortRef(String("STRING"), NVT_TEXT))
    elif _contains_ci(class_type, String("any switch")) or _contains_ci(class_type, String("lazyswitch")):
        node.add_output(PortRef(String("*"), NVT_TEXT))
    elif _contains_ci(class_type, String("image or latent size")) or _contains_ci(class_type, String("getimagesize")) or _contains_ci(class_type, String("getlatentsize")):
        node.add_output(PortRef(String("WIDTH"), NVT_NUMBER))
        node.add_output(PortRef(String("HEIGHT"), NVT_NUMBER))
    elif _contains_ci(class_type, String("imageresize")) or _contains_ci(class_type, String("image resize")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
        node.add_output(PortRef(String("WIDTH"), NVT_NUMBER))
        node.add_output(PortRef(String("HEIGHT"), NVT_NUMBER))
    elif _contains_ci(class_type, String("lanpaint_samplercustom")):
        node.add_output(PortRef(String("output"), NVT_LATENT))
        node.add_output(PortRef(String("denoised_output"), NVT_LATENT))
    elif _contains_ci(class_type, String("lanpaint_ksampler")):
        node.add_output(PortRef(String("LATENT"), NVT_LATENT))
    elif _contains_ci(class_type, String("lanpaint_maskblend")):
        node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    elif _contains_ci(class_type, String("cliptextencode")) or _contains_ci(class_type, String("conditioning")):
        node.add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    elif _contains_ci(class_type, String("emptylatent")) or _contains_ci(class_type, String("latentimage")) or _contains_ci(class_type, String("repeatlatent")) or _contains_ci(class_type, String("latentupscale")) or _contains_ci(class_type, String("ksampler")) or _contains_ci(class_type, String("samplercustom")) or _contains_ci(class_type, String("vaeencode")):
        node.add_output(PortRef(String("LATENT"), NVT_LATENT))
    elif _contains_ci(class_type, String("vaedecode")) or _contains_ci(class_type, String("loadimage")) or _contains_ci(class_type, String("image")):
        if not _contains_ci(class_type, String("saveimage")):
            node.add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    elif _contains_ci(class_type, String("video")):
        node.add_output(PortRef(String("VIDEO"), NVT_VIDEO))
    elif _contains_ci(class_type, String("text")) or _contains_ci(class_type, String("string")):
        node.add_output(PortRef(String("STRING"), NVT_TEXT))


def _add_vhs_video_info_outputs(mut node: Node, class_type: String):
    if not _contains_ci(class_type, String("loaded")):
        node.add_output(PortRef(String("source_fps"), NVT_NUMBER))
        node.add_output(PortRef(String("source_frame_count"), NVT_NUMBER))
        node.add_output(PortRef(String("source_duration"), NVT_NUMBER))
        node.add_output(PortRef(String("source_width"), NVT_NUMBER))
        node.add_output(PortRef(String("source_height"), NVT_NUMBER))
    if not _contains_ci(class_type, String("source")):
        node.add_output(PortRef(String("loaded_fps"), NVT_NUMBER))
        node.add_output(PortRef(String("loaded_frame_count"), NVT_NUMBER))
        node.add_output(PortRef(String("loaded_duration"), NVT_NUMBER))
        node.add_output(PortRef(String("loaded_width"), NVT_NUMBER))
        node.add_output(PortRef(String("loaded_height"), NVT_NUMBER))


def _add_vhs_split_outputs(mut node: Node, value_type: Int32, base_name: String):
    node.add_output(PortRef(base_name + String("_A"), value_type))
    node.add_output(PortRef(String("A_count"), NVT_NUMBER))
    node.add_output(PortRef(base_name + String("_B"), value_type))
    node.add_output(PortRef(String("B_count"), NVT_NUMBER))


def _infer_port_type_from_name(name: String) -> Int32:
    if _contains_ci(name, String("mask")):
        return NVT_IMAGE
    if _contains_ci(name, String("audio")) or _contains_ci(name, String("video_info")) or _contains_ci(name, String("filenames")) or _contains_ci(name, String("meta_batch")) or _contains_ci(name, String("batched")):
        return NVT_TEXT
    if _contains_ci(name, String("opt_model")):
        return NVT_MODEL
    if _contains_ci(name, String("opt_clip")):
        return NVT_CLIP
    if _contains_ci(name, String("any_")):
        return NVT_TEXT
    if _contains_ci(name, String("model")):
        return NVT_MODEL
    if _contains_ci(name, String("clip")):
        return NVT_CLIP
    if _contains_ci(name, String("vae")):
        return NVT_VAE
    if _contains_ci(name, String("positive")) or _contains_ci(name, String("negative")) or _contains_ci(name, String("conditioning")) or _contains_ci(name, String("cond")):
        return NVT_CONDITIONING
    if _contains_ci(name, String("latent")) or _contains_ci(name, String("samples")):
        return NVT_LATENT
    if _contains_ci(name, String("image")) or _contains_ci(name, String("pixels")):
        return NVT_IMAGE
    if _contains_ci(name, String("video")):
        return NVT_VIDEO
    if _contains_ci(name, String("seed")):
        return NVT_SEED
    if _contains_ci(name, String("sampler")) or _contains_ci(name, String("guider")) or _contains_ci(name, String("noise")):
        return NVT_TEXT
    if _contains_ci(name, String("sigmas")):
        return NVT_NUMBER
    if _contains_ci(name, String("frame_count")) or _contains_ci(name, String("frame_rate")) or _contains_ci(name, String("fps")) or _contains_ci(name, String("width")) or _contains_ci(name, String("height")) or _contains_ci(name, String("steps")) or _contains_ci(name, String("cfg")) or _contains_ci(name, String("denoise")) or _contains_ci(name, String("amount")) or _contains_ci(name, String("scale")):
        return NVT_NUMBER
    if _contains_ci(name, String("enable")) or _contains_ci(name, String("enabled")) or _contains_ci(name, String("bool")):
        return NVT_BOOL
    return NVT_TEXT


def _parse_comfy_ports(mut node: Node, ports_val: JsonValue, is_input: Bool):
    if ports_val.kind != JK_ARRAY:
        return
    for i in range(len(ports_val.arr_val)):
        var p_val = ports_val.arr_val[i].copy()
        if p_val.kind != JK_OBJECT:
            continue
        var fallback = String("input_") + String(i)
        if not is_input:
            fallback = String("output_") + String(i)
        var name = _json_string(p_val.get_object_field(String("name")), fallback)
        var type_name = _json_string(p_val.get_object_field(String("type")), String("UNKNOWN"))
        var port = PortRef(name, _comfy_type_to_nvt(type_name))
        if is_input:
            node.add_input(port)
        else:
            node.add_output(port)


def _parse_comfy_widget_values(mut node: Node, widgets_val: JsonValue):
    if widgets_val.kind == JK_ARRAY:
        for i in range(len(widgets_val.arr_val)):
            var key = String("widget_") + String(i)
            var fv = _field_from_json(widgets_val.arr_val[i].copy())
            node.set_field(key, fv)
        return
    if widgets_val.kind == JK_OBJECT:
        for i in range(len(widgets_val.obj_keys)):
            var key = widgets_val.obj_keys[i].copy()
            node.set_field(key, _field_from_json(widgets_val.obj_values[i].copy()))


def _parse_comfy_properties(mut node: Node, properties_val: JsonValue):
    if properties_val.kind != JK_OBJECT:
        return
    var keys = List[String]()
    for i in range(len(properties_val.obj_keys)):
        keys.append(properties_val.obj_keys[i].copy())
    for i in range(len(keys)):
        var key = keys[i].copy()
        var field_key = String("prop_") + key
        node.set_field(field_key, _field_from_json(properties_val.get_object_field(key).copy()))


def _seed_graph_allocator(mut graph: Graph):
    var max_idx: UInt64 = 0
    for i in range(graph.node_count()):
        var idx = UInt64(graph.nodes[i].id) & UInt64(0x0000FFFFFFFFFFFF)
        if idx > max_idx:
            max_idx = idx
    if max_idx == UInt64(0):
        return
    graph.id_alloc.next_index = max_idx + UInt64(1)
    while UInt64(len(graph.id_alloc.generations)) < max_idx:
        graph.id_alloc.generations.append(UInt16(0))


def _port_name_by_slot(graph: Graph, node_id: RetainedId, slot: Int, is_output: Bool) -> String:
    var idx = graph.find_node(node_id)
    if idx < 0:
        if is_output:
            return String("output_") + String(slot)
        return String("input_") + String(slot)
    if is_output:
        if slot >= 0 and slot < len(graph.nodes[idx].outputs):
            return graph.nodes[idx].outputs[slot].name.copy()
        return String("output_") + String(slot)
    if slot >= 0 and slot < len(graph.nodes[idx].inputs):
        return graph.nodes[idx].inputs[slot].name.copy()
    return String("input_") + String(slot)


def _parse_comfy_links(links_val: JsonValue, mut graph: Graph):
    if links_val.kind != JK_ARRAY:
        return
    for i in range(len(links_val.arr_val)):
        var link = links_val.arr_val[i].copy()
        if link.kind != JK_ARRAY or len(link.arr_val) < 5:
            continue
        var from_node = RetainedId(_json_i64(link.arr_val[1].copy(), Int64(0)))
        var from_slot = Int(_json_i64(link.arr_val[2].copy(), Int64(0)))
        var to_node = RetainedId(_json_i64(link.arr_val[3].copy(), Int64(0)))
        var to_slot = Int(_json_i64(link.arr_val[4].copy(), Int64(0)))
        if from_node == RetainedId(0) or to_node == RetainedId(0):
            continue
        var from_port = _port_name_by_slot(graph, from_node, from_slot, True)
        var to_port = _port_name_by_slot(graph, to_node, to_slot, False)
        _ = graph.add_edge(from_node, from_port, to_node, to_port)


def _hex_digit(b: UInt8) -> Int:
    var n = Int(b)
    if n >= 48 and n <= 57:
        return n - 48
    if n >= 65 and n <= 70:
        return n - 55
    if n >= 97 and n <= 102:
        return n - 87
    return 0


def _color_from_comfy(value: JsonValue) -> Color:
    if value.kind != JK_STRING:
        return Color(UInt8(96), UInt8(120), UInt8(180), UInt8(255))
    var s = value.str_val
    if s.byte_length() < 4:
        return Color(UInt8(96), UInt8(120), UInt8(180), UInt8(255))
    var ptr = s.unsafe_ptr()
    var offset = 0
    if ptr[0] == UInt8(35):
        offset = 1
    if s.byte_length() == offset + 3:
        var sr = _hex_digit(ptr[offset])
        var sg = _hex_digit(ptr[offset + 1])
        var sb = _hex_digit(ptr[offset + 2])
        return Color(UInt8(sr * 17), UInt8(sg * 17), UInt8(sb * 17), UInt8(255))
    if s.byte_length() < offset + 6:
        return Color(UInt8(96), UInt8(120), UInt8(180), UInt8(255))
    var r = _hex_digit(ptr[offset]) * 16 + _hex_digit(ptr[offset + 1])
    var g = _hex_digit(ptr[offset + 2]) * 16 + _hex_digit(ptr[offset + 3])
    var b = _hex_digit(ptr[offset + 4]) * 16 + _hex_digit(ptr[offset + 5])
    return Color(UInt8(r), UInt8(g), UInt8(b), UInt8(255))


def _parse_comfy_groups(groups_val: JsonValue, mut canvas: CanvasState, graph: Graph):
    if groups_val.kind != JK_ARRAY:
        return
    var next_id = Int64(1)
    for i in range(len(groups_val.arr_val)):
        var g_val = groups_val.arr_val[i].copy()
        if g_val.kind != JK_OBJECT:
            continue
        var group_id = _json_i64(g_val.get_object_field(String("id")), next_id)
        if group_id < Int64(1):
            group_id = next_id
        var title = _json_string(
            g_val.get_object_field(String("title")),
            String("Group ") + String(group_id),
        )
        var bounds = g_val.get_object_field(String("bounding"))
        var rect = Rect(
            Float32(_array_number(bounds, 0, 0.0)),
            Float32(_array_number(bounds, 1, 0.0)),
            Float32(_array_number(bounds, 2, 1.0)),
            Float32(_array_number(bounds, 3, 1.0)),
        )
        var color = _color_from_comfy(g_val.get_object_field(String("color")))
        var group = CanvasGroup(group_id, title, rect, color)
        for ni in range(graph.node_count()):
            var nr = Rect(
                graph.nodes[ni].position.x,
                graph.nodes[ni].position.y,
                graph.nodes[ni].size.x,
                graph.nodes[ni].size.y,
            )
            if rect.intersects(nr):
                group.members.append(graph.nodes[ni].id)
        canvas.groups.append(group^)
        if group_id >= next_id:
            next_id = group_id + Int64(1)
    canvas.next_group_id = next_id


def _lower_ascii(s: String) -> String:
    var out = List[UInt8](capacity=s.byte_length())
    var ptr = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var b = ptr[i]
        if b >= UInt8(65) and b <= UInt8(90):
            b = b + UInt8(32)
        out.append(b)
    return String(unsafe_from_utf8=out)


def _contains_substr(haystack: String, needle: String) -> Bool:
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


def _contains_ci(haystack: String, needle: String) -> Bool:
    return _contains_substr(_lower_ascii(haystack), _lower_ascii(needle))
