"""Workflow-to-render request extraction.

This is the app-facing bridge between MojoUI's reusable graph/canvas data and
Serenity-style inference runtimes. It is pure Mojo and does not launch model
code; callers can compile an execution plan, extract a `RenderRequest`, then
dispatch that request through their GPU/runtime layer.
"""

from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import (
    Node,
    FieldValue,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
)
from mojoui.nodes.canvas_model import CanvasState


struct RenderRequest(Copyable, Movable):
    """A normalized image/video render request extracted from a node graph."""

    var backend: String
    var prompt: String
    var negative: String
    var width: Int32
    var height: Int32
    var steps: Int32
    var cfg: Float64
    var seed: Int64
    var sampler: String
    var output_path: String
    var magic_prompt_enabled: Bool
    var magic_prompt_model: String
    var magic_prompt_entry: String
    var generate_entry: String
    var source_node: RetainedId
    var save_node: RetainedId
    var selected_group: Int64
    var canvas_node_count: Int32

    def __init__(out self):
        self.backend = String("zimage")
        self.prompt = String("")
        self.negative = String("")
        self.width = 1024
        self.height = 1024
        self.steps = 28
        self.cfg = 7.0
        self.seed = -1
        self.sampler = String("euler")
        self.output_path = String("/tmp/serenity_output.png")
        self.magic_prompt_enabled = False
        self.magic_prompt_model = String("")
        self.magic_prompt_entry = String("")
        self.generate_entry = String("")
        self.source_node = RET_ID_NONE
        self.save_node = RET_ID_NONE
        self.selected_group = Int64(-1)
        self.canvas_node_count = 0


def extract_render_request(graph: Graph, canvas: CanvasState) raises -> RenderRequest:
    """Extract the best render request from a graph plus canvas state.

    Comfy imports are accepted because their `widgets_values` and
    `properties` are already normalized into `Node.fields` by
    `serde.comfy_workflow`.
    """
    var request = RenderRequest()
    request.canvas_node_count = Int32(graph.node_count())
    request.selected_group = canvas.selected_group

    for i in range(graph.node_count()):
        var node = graph.nodes[i].copy()
        if _node_mentions(node, String("ideogram")):
            _set_ideogram_defaults(request)
            break

    for i in range(graph.node_count()):
        var node = graph.nodes[i].copy()
        _apply_scalar_fields(request, node)
        _apply_resolution_fields(request, node)
        _apply_output_fields(request, node)
        _apply_prompt_fields(request, node)

    if request.backend == String("ideogram4") and request.prompt.byte_length() == 0:
        request.prompt = String("A polished high quality image.")
    return request^


def apply_magic_prompt(request: RenderRequest) -> RenderRequest:
    """Return a copy with `prompt` transformed into an Ideogram JSON caption
    when magic prompting is enabled.
    """
    var out = request.copy()
    if not out.magic_prompt_enabled:
        return out^
    out.prompt = ideogram_magic_prompt_json(
        request.prompt,
        render_request_aspect_ratio(request),
    )
    return out^


def render_request_aspect_ratio(request: RenderRequest) -> String:
    if request.width == request.height:
        return String("1:1")
    if Int(request.width) * 9 == Int(request.height) * 16:
        return String("16:9")
    if Int(request.width) * 16 == Int(request.height) * 9:
        return String("9:16")
    if Int(request.width) * 3 == Int(request.height) * 4:
        return String("4:3")
    if Int(request.width) * 4 == Int(request.height) * 3:
        return String("3:4")
    return String(request.width) + String(":") + String(request.height)


def ideogram_magic_prompt_json(prompt: String, aspect_ratio: String) -> String:
    """Deterministic pure-Mojo JSON-caption fallback for Ideogram4.

    The full local magic-prompt path lives in
    `/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_magic.mojo`.
    This function gives the UI/graph layer a valid structured caption before
    that model is invoked.
    """
    var p = _json_escape(prompt)
    var ar = _json_escape(aspect_ratio)
    return (
        String("{\"high_level_description\":\"")
        + p
        + String("\",\"aspect_ratio\":\"")
        + ar
        + String("\",\"compositional_deconstruction\":{\"subject\":\"")
        + p
        + String("\",\"layout\":\"centered, readable, production-quality composition\",\"lighting\":\"clean cinematic lighting\",\"style\":\"detailed image generation prompt\"},\"negative_space\":\"avoid clutter, distortion, unreadable text, duplicate subjects\"}")
    )


def _set_ideogram_defaults(mut request: RenderRequest):
    request.backend = String("ideogram4")
    request.width = 1024
    request.height = 1024
    request.steps = 48
    request.cfg = 1.0
    request.seed = 0
    request.sampler = String("ideogram4_quality")
    request.output_path = String("/home/alex/mojodiffusion/output/ideogram4_generated_1024.png")
    request.magic_prompt_enabled = True
    request.magic_prompt_model = String("qwen3-local-v1")
    request.magic_prompt_entry = String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_magic.mojo")
    request.generate_entry = String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_generate.mojo")


def _apply_prompt_fields(mut request: RenderRequest, node: Node) raises:
    var skip_widget = (
        _node_mentions(node, String("markdown"))
        or _node_mentions(node, String("resolution"))
        or _node_mentions(node, String("save"))
        or _node_mentions(node, String("preview"))
    )
    var direct = _first_named_string_field(
        node,
        String("prompt"),
        String("positive"),
        String("text"),
        String("caption"),
    )
    if direct.byte_length() > 0:
        request.prompt = direct.copy()
        request.source_node = node.id
        return
    if skip_widget:
        return
    var widget = _string_field(node, String("widget_0"), String(""))
    if _looks_like_prompt_widget(widget):
        request.prompt = widget.copy()
        request.source_node = node.id


def _apply_output_fields(mut request: RenderRequest, node: Node) raises:
    var save_like = (
        _node_mentions(node, String("saveimage"))
        or _node_mentions(node, String("save_image"))
        or (_node_mentions(node, String("save")) and _node_mentions(node, String("image")))
    )
    if not save_like:
        return
    var out = _first_named_string_field(
        node,
        String("output_path"),
        String("path"),
        String("filename_prefix"),
        String("filename"),
    )
    if out.byte_length() == 0:
        out = _string_field(node, String("widget_0"), String(""))
    if out.byte_length() > 0:
        request.output_path = out.copy()
        request.save_node = node.id


def _apply_scalar_fields(mut request: RenderRequest, node: Node) raises:
    var keys = _field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = _lower(key)
        var value = node.get_field(key)
        if lower_key == String("negative") or lower_key == String("negative_prompt"):
            request.negative = _field_to_string(value)
        elif lower_key == String("steps"):
            request.steps = _field_to_i32(value, request.steps)
            if request.steps < 1:
                request.steps = 1
        elif lower_key == String("cfg") or lower_key == String("cfg_scale"):
            request.cfg = _field_to_f64(value, request.cfg)
        elif lower_key == String("seed"):
            request.seed = _field_to_i64(value, request.seed)
        elif lower_key == String("sampler"):
            request.sampler = _field_to_string(value)
        elif lower_key == String("magic_prompt") or lower_key == String("magic_prompt_enabled"):
            request.magic_prompt_enabled = _field_to_bool(value, request.magic_prompt_enabled)
        elif lower_key == String("magic_prompt_model"):
            request.magic_prompt_model = _field_to_string(value)


def _apply_resolution_fields(mut request: RenderRequest, node: Node) raises:
    var keys = _field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = _lower(key)
        var value = node.get_field(key)
        if lower_key == String("width") or lower_key == String("w"):
            request.width = _field_to_i32(value, request.width)
        elif lower_key == String("height") or lower_key == String("h"):
            request.height = _field_to_i32(value, request.height)
        elif value.kind == FK_STRING:
            _apply_resolution_string(request, value.str_val)
    if request.width < 1:
        request.width = 1
    if request.height < 1:
        request.height = 1


def _apply_resolution_string(mut request: RenderRequest, value: String):
    var s = _lower(value)
    if _contains_substr(s, String("9:16")) or _contains_substr(s, String("portrait widescreen")):
        request.width = 576
        request.height = 1024
    elif _contains_substr(s, String("16:9")) or _contains_substr(s, String("landscape widescreen")):
        request.width = 1024
        request.height = 576
    elif _contains_substr(s, String("1:1")) or _contains_substr(s, String("square")):
        request.width = 1024
        request.height = 1024
    elif _contains_substr(s, String("3:4")):
        request.width = 768
        request.height = 1024
    elif _contains_substr(s, String("4:3")):
        request.width = 1024
        request.height = 768


def _first_named_string_field(
    node: Node,
    key_a: String,
    key_b: String,
    key_c: String,
    key_d: String,
) raises -> String:
    var keys = _field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        var lower_key = _lower(key)
        if (
            lower_key == key_a
            or lower_key == key_b
            or lower_key == key_c
            or lower_key == key_d
        ):
            var value = _field_to_string(node.get_field(key))
            if value.byte_length() > 0:
                return value^
    return String("")


def _string_field(node: Node, key: String, fallback: String) raises -> String:
    if not node.has_field(key):
        return fallback.copy()
    var value = node.get_field(key)
    if value.kind != FK_STRING:
        return fallback.copy()
    return value.str_val.copy()


def _field_keys(node: Node) -> List[String]:
    var keys = List[String]()
    for k in node.fields.keys():
        keys.append(k.copy())
    return keys^


def _node_mentions(node: Node, needle: String) raises -> Bool:
    var n = _lower(needle)
    if _contains_substr(_lower(node.type_id), n):
        return True
    if _contains_substr(_lower(node.title), n):
        return True
    var keys = _field_keys(node)
    for i in range(len(keys)):
        var key = keys[i].copy()
        if _contains_substr(_lower(key), n):
            return True
        var value = node.get_field(key)
        if value.kind == FK_STRING and _contains_substr(_lower(value.str_val), n):
            return True
    return False


def _looks_like_prompt_widget(value: String) -> Bool:
    if value.byte_length() < 8:
        return False
    var s = _lower(value)
    if _contains_substr(s, String(".png")) or _contains_substr(s, String(".jpg")):
        return False
    if _contains_substr(s, String(".mp4")) or _contains_substr(s, String(".webp")):
        return False
    if _contains_substr(s, String("resolution")):
        return False
    if _contains_substr(s, String("portrait")) or _contains_substr(s, String("landscape")):
        return False
    return True


def _field_to_string(value: FieldValue) -> String:
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


def _field_to_i32(value: FieldValue, fallback: Int32) -> Int32:
    if value.kind == FK_INT:
        return Int32(value.int_val)
    if value.kind == FK_NUMBER:
        return Int32(value.num_val)
    return fallback


def _field_to_i64(value: FieldValue, fallback: Int64) -> Int64:
    if value.kind == FK_INT:
        return value.int_val
    if value.kind == FK_NUMBER:
        return Int64(value.num_val)
    return fallback


def _field_to_f64(value: FieldValue, fallback: Float64) -> Float64:
    if value.kind == FK_NUMBER:
        return value.num_val
    if value.kind == FK_INT:
        return Float64(value.int_val)
    return fallback


def _field_to_bool(value: FieldValue, fallback: Bool) -> Bool:
    if value.kind == FK_BOOL:
        return value.bool_val
    if value.kind == FK_INT:
        return value.int_val != Int64(0)
    if value.kind == FK_NUMBER:
        return value.num_val != 0.0
    if value.kind == FK_STRING:
        var s = _lower(value.str_val)
        if s == String("true") or s == String("yes") or s == String("1"):
            return True
        if s == String("false") or s == String("no") or s == String("0"):
            return False
    return fallback


def _json_escape(s: String) -> String:
    var out = List[UInt8](capacity=s.byte_length())
    var ptr = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var b = ptr[i]
        if b == UInt8(34):
            out.append(UInt8(92))
            out.append(UInt8(34))
        elif b == UInt8(92):
            out.append(UInt8(92))
            out.append(UInt8(92))
        elif b == UInt8(10):
            out.append(UInt8(92))
            out.append(UInt8(110))
        elif b == UInt8(13):
            out.append(UInt8(92))
            out.append(UInt8(114))
        elif b == UInt8(9):
            out.append(UInt8(92))
            out.append(UInt8(116))
        elif b < UInt8(32):
            out.append(UInt8(32))
        else:
            out.append(b)
    return String(unsafe_from_utf8=out)


def _lower(s: String) -> String:
    var n = s.byte_length()
    var out = List[UInt8](capacity=n)
    var ptr = s.unsafe_ptr()
    for i in range(n):
        var b = ptr[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            b = b + UInt8(0x20)
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
