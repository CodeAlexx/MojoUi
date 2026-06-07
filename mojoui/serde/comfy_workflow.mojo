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
      - top-level `links`: array of `[id, from_node, from_slot, to_node,
        to_slot, type]`;
      - top-level `groups`: array with `bounding: [x, y, w, h]`.

    The importer preserves node arrangement and creates explicit MojoUI group
    membership by intersecting node rectangles with each Comfy group bound.
    """
    var root = parse_json(raw)
    if root.kind != JK_OBJECT:
        raise Error("Comfy workflow root must be an object")
    var nodes_val = root.get_object_field(String("nodes"))
    if nodes_val.kind != JK_ARRAY:
        raise Error("Comfy workflow must contain a visual nodes array")

    var graph = Graph()
    var canvas = CanvasState()
    _parse_comfy_nodes(nodes_val, graph)
    _seed_graph_allocator(graph)
    _parse_comfy_links(root.get_object_field(String("links")), graph)
    _parse_comfy_groups(root.get_object_field(String("groups")), canvas, graph)
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
    if value.kind != JK_ARRAY:
        return fallback
    if index < 0 or index >= len(value.arr_val):
        return fallback
    return _json_number(value.arr_val[index].copy(), fallback)


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
    if type_name == String("SEED") or type_name == String("seed"):
        return NVT_SEED
    if type_name == String("BOOLEAN") or type_name == String("BOOL") or type_name == String("boolean") or type_name == String("bool"):
        return NVT_BOOL
    if type_name == String("VIDEO") or type_name == String("video"):
        return NVT_VIDEO
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
        if size.kind == JK_ARRAY:
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
    if widgets_val.kind != JK_ARRAY:
        return
    for i in range(len(widgets_val.arr_val)):
        var key = String("widget_") + String(i)
        var fv = _field_from_json(widgets_val.arr_val[i].copy())
        node.set_field(key, fv)


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
