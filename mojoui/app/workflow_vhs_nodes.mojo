"""Video Helper Suite compatibility executors.

The handlers here port the VHS graph contract into MojoUI's typed workflow
values. They do not depend on Python; media bytes are represented as paths and
metadata handles until a native ffmpeg/C primitive is wired underneath.
"""

from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.app.workflow_types import (
    WorkflowArtifact,
    WorkflowExecutionResult,
    WorkflowValue,
    WV_IMAGE,
    WV_LATENT,
    WV_TEXT,
)
from mojoui.app.workflow_support import (
    first_bool_field,
    first_incoming_kind,
    first_int_field,
    first_number_field,
    first_output_name,
    first_string_field,
    incoming_value,
    node_matches,
    output_name_or,
)
from mojoui.serde.json import JK_OBJECT, JK_NUMBER, parse_json


def is_vhs_node(node: Node) -> Bool:
    return node_matches(node, String("vhs_")) or node_matches(node, String("video helper suite"))


def execute_vhs_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if node_matches(node, String("vhs_loadvideo")) or node_matches(node, String("vhs_loadvideoffmpeg")):
        return execute_vhs_load_video(node, result)
    if node_matches(node, String("vhs_loadimages")):
        return execute_vhs_load_images(node, result)
    if node_matches(node, String("vhs_loadimagepath")):
        return execute_vhs_load_image_path(node, result)
    if node_matches(node, String("vhs_videocombine")):
        return execute_vhs_video_combine(graph, node, result)
    if node_matches(node, String("vhs_loadaudio")):
        return execute_vhs_load_audio(node, result)
    if node_matches(node, String("vhs_audiotovhsaudio")) or node_matches(node, String("vhs_vhsaudiotoaudio")):
        return execute_vhs_audio_passthrough(graph, node, result)
    if node_matches(node, String("vhs_batchmanager")):
        return execute_vhs_batch_manager(node, result)
    if node_matches(node, String("vhs_videoinfosource")):
        return execute_vhs_video_info(graph, node, result, 1)
    if node_matches(node, String("vhs_videoinfoloaded")):
        return execute_vhs_video_info(graph, node, result, 2)
    if node_matches(node, String("vhs_videoinfo")):
        return execute_vhs_video_info(graph, node, result, 0)
    if node_matches(node, String("vhs_selectfilename")):
        return execute_vhs_select_filename(graph, node, result)
    if node_matches(node, String("vhs_selectlatest")):
        return execute_vhs_select_latest(node, result)
    if node_matches(node, String("vhs_pruneoutputs")):
        result.add_log(String("vhs_prune_outputs"))
        return True
    if node_matches(node, String("vhs_unbatch")):
        return execute_vhs_unbatch(graph, node, result)
    if is_vhs_sequence_node(node):
        return execute_vhs_sequence_node(graph, node, result)
    return False


def execute_vhs_load_video(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var path = first_string_field(node, String("video"), String("path"), String("widget_0"), String(""))
    var width = first_int_field(node, String("custom_width"), String("width"), String("widget_2"), Int32(0))
    var height = first_int_field(node, String("custom_height"), String("height"), String("widget_3"), Int32(0))
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    var frame_count = first_int_field(node, String("frame_load_cap"), String("frame_count"), String("widget_4"), Int32(0))
    if frame_count <= 0:
        frame_count = Int32(1)
    var fps = first_number_field(node, String("force_rate"), String("fps"), String("widget_1"), 0.0)
    if fps <= 0.0:
        fps = 24.0
    var image = WorkflowValue.image_path(node.id, output_name_or(node, String("IMAGE"), String("IMAGE")), path, width, height, -1)
    image.batch_size = frame_count
    result.add_value(image^)
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("frame_count"), String("frame_count")), String(frame_count)))
    result.add_value(WorkflowValue.text_value(node.id, output_name_or(node, String("audio"), String("audio")), String("audio:") + path))
    result.add_value(WorkflowValue.text_value(node.id, output_name_or(node, String("video_info"), String("video_info")), _video_info_json(fps, frame_count, width, height)))
    result.add_artifact(WorkflowArtifact(node.id, String("video_preview"), path, String("VHS load video")))
    result.add_log(String("vhs_load_video ") + path + String(" frames=") + String(frame_count))
    return True


def execute_vhs_load_images(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var directory = first_string_field(node, String("directory"), String("path"), String("widget_0"), String(""))
    var count = first_int_field(node, String("image_load_cap"), String("frame_count"), String("widget_1"), Int32(0))
    if count <= 0:
        count = Int32(1)
    var image = WorkflowValue.image_path(node.id, output_name_or(node, String("IMAGE"), String("IMAGE")), directory, result.request.width, result.request.height, -1)
    image.batch_size = count
    result.add_value(image^)
    var mask = WorkflowValue.image_path(node.id, output_name_or(node, String("MASK"), String("MASK")), directory, result.request.width, result.request.height, -1)
    mask.batch_size = count
    result.add_value(mask^)
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("frame_count"), String("frame_count")), String(count)))
    result.add_log(String("vhs_load_images ") + directory + String(" frames=") + String(count))
    return True


def execute_vhs_load_image_path(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var path = first_string_field(node, String("image"), String("path"), String("widget_0"), String(""))
    var width = first_int_field(node, String("custom_width"), String("width"), String("widget_1"), result.request.width)
    var height = first_int_field(node, String("custom_height"), String("height"), String("widget_2"), result.request.height)
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    result.add_value(WorkflowValue.image_path(node.id, output_name_or(node, String("IMAGE"), String("IMAGE")), path, width, height, -1))
    result.add_value(WorkflowValue.image_path(node.id, output_name_or(node, String("mask"), String("mask")), path, width, height, -1))
    result.add_log(String("vhs_load_image_path ") + path)
    return True


def execute_vhs_video_combine(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("images"))
    if image.kind != WV_IMAGE:
        image = first_incoming_kind(graph, result, node.id, WV_IMAGE)
    var latent = incoming_value(graph, result, node.id, String("latents"))
    var width = image.width
    var height = image.height
    var frames = image.batch_size
    if width <= 0:
        width = latent.width
    if height <= 0:
        height = latent.height
    if frames <= 1:
        frames = latent.batch_size
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    if frames <= 0:
        frames = Int32(1)
    var fps = first_number_field(node, String("frame_rate"), String("fps"), String("widget_0"), 8.0)
    var prefix = first_string_field(node, String("filename_prefix"), String("prefix"), String("widget_2"), String("AnimateDiff"))
    var format = first_string_field(node, String("format"), String("container"), String("widget_3"), String("video/mp4"))
    var ext = _format_extension(format)
    var path = String("/tmp/") + prefix + String("_") + String(node.id) + ext
    result.add_value(WorkflowValue.text_value(node.id, output_name_or(node, String("Filenames"), String("Filenames")), String("{\"save_output\":true,\"files\":[\"") + path + String("\"]}")))
    result.add_artifact(WorkflowArtifact(node.id, String("video"), path, String("VHS video combine")))
    result.add_log(String("vhs_video_combine ") + String(width) + String("x") + String(height) + String(" frames=") + String(frames) + String(" fps=") + String(fps))
    return True


def execute_vhs_load_audio(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var path = first_string_field(node, String("audio"), String("audio_file"), String("widget_0"), String(""))
    if path.byte_length() == 0:
        path = first_string_field(node, String("path"), String("file"), String(""), String(""))
    result.add_value(WorkflowValue.text_value(node.id, output_name_or(node, String("audio"), String("audio")), String("audio:") + path))
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("duration"), String("duration")), String(0.0)))
    result.add_log(String("vhs_load_audio ") + path)
    return True


def execute_vhs_audio_passthrough(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var audio = incoming_value(graph, result, node.id, String("audio"))
    if audio.kind != WV_TEXT:
        audio = first_incoming_kind(graph, result, node.id, WV_TEXT)
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("audio")), audio.text))
    result.add_log(String("vhs_audio_passthrough"))
    return True


def execute_vhs_batch_manager(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var frames = first_int_field(node, String("frames_per_batch"), String("batch_size"), String("widget_0"), Int32(0))
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("VHS_BatchManager")), String("meta_batch:") + String(frames)))
    result.add_log(String("vhs_batch_manager ") + String(frames))
    return True


def execute_vhs_video_info(graph: Graph, node: Node, mut result: WorkflowExecutionResult, mode: Int32) raises -> Bool:
    var info = incoming_value(graph, result, node.id, String("video_info"))
    if info.kind != WV_TEXT:
        info = first_incoming_kind(graph, result, node.id, WV_TEXT)
    if mode == Int32(1) or mode == Int32(0):
        _emit_info_set(node, result, info.text, String("source_"))
    if mode == Int32(2) or mode == Int32(0):
        _emit_info_set(node, result, info.text, String("loaded_"))
    result.add_log(String("vhs_video_info"))
    return True


def execute_vhs_select_filename(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var filenames = incoming_value(graph, result, node.id, String("filenames"))
    var selected = _latest_file_from_filenames(filenames.text)
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("Filename")), selected))
    result.add_log(String("vhs_select_filename ") + selected)
    return True


def execute_vhs_select_latest(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var prefix = first_string_field(node, String("filename_prefix"), String("widget_0"), String(""), String("output/AnimateDiff"))
    var postfix = first_string_field(node, String("filename_postfix"), String("widget_1"), String(""), String(".webm"))
    result.add_value(WorkflowValue.text_value(node.id, first_output_name(node, String("Filename")), prefix + postfix))
    result.add_log(String("vhs_select_latest ") + prefix + postfix)
    return True


def execute_vhs_unbatch(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var value = first_incoming_kind(graph, result, node.id, WV_IMAGE)
    if value.kind != WV_IMAGE:
        value = first_incoming_kind(graph, result, node.id, WV_LATENT)
    if value.kind != WV_IMAGE and value.kind != WV_LATENT:
        value = first_incoming_kind(graph, result, node.id, WV_TEXT)
    value.node_id = node.id
    value.port = first_output_name(node, String("unbatched"))
    result.add_value(value^)
    result.add_log(String("vhs_unbatch"))
    return True


def is_vhs_sequence_node(node: Node) -> Bool:
    return (
        node_matches(node, String("vhs_split"))
        or node_matches(node, String("vhs_merge"))
        or node_matches(node, String("vhs_get"))
        or node_matches(node, String("vhs_duplicate"))
        or node_matches(node, String("vhs_selecteverynth"))
        or node_matches(node, String("vhs_selectlatents"))
        or node_matches(node, String("vhs_selectimages"))
        or node_matches(node, String("vhs_selectmasks"))
        or node_matches(node, String("vhs_vaeencodebatched"))
        or node_matches(node, String("vhs_vaedecodebatched"))
    )


def execute_vhs_sequence_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var value = _primary_sequence_value(graph, node, result)
    var count = value.batch_size
    if count <= 0:
        count = Int32(1)
    if node_matches(node, String("vhs_get")):
        result.add_value(WorkflowValue.number_value(node.id, first_output_name(node, String("count")), String(count)))
        result.add_log(String("vhs_count ") + String(count))
        return True
    if node_matches(node, String("vhs_duplicate")):
        var repeats = first_int_field(node, String("multiply_by"), String("duplicates"), String("widget_0"), Int32(2))
        if repeats < Int32(1):
            repeats = Int32(1)
        count = count * repeats
    elif node_matches(node, String("vhs_selecteverynth")):
        var nth = first_int_field(node, String("select_every_nth"), String("every_nth"), String("widget_0"), Int32(1))
        if nth < Int32(1):
            nth = Int32(1)
        count = (count + nth - Int32(1)) / nth
    elif node_matches(node, String("vhs_selectlatents")) or node_matches(node, String("vhs_selectimages")) or node_matches(node, String("vhs_selectmasks")):
        count = _selection_count(first_string_field(node, String("indexes"), String("select_indexes"), String("widget_0"), String("")), count)
    elif node_matches(node, String("vhs_split")):
        var split = first_int_field(node, String("split_index"), String("widget_0"), String(""), count / Int32(2))
        if split < Int32(0):
            split = Int32(0)
        if split > count:
            split = count
        _emit_sequence_value(node, result, value, Int32(0), split)
        result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("A_count"), String("A_count")), String(split)))
        _emit_sequence_value(node, result, value, Int32(2), count - split)
        result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("B_count"), String("B_count")), String(count - split)))
        result.add_log(String("vhs_split ") + String(split) + String("/") + String(count))
        return True
    elif node_matches(node, String("vhs_merge")):
        var other = _secondary_sequence_value(graph, node, result, value.kind)
        count = count + other.batch_size
    _emit_sequence_value(node, result, value, Int32(0), count)
    result.add_value(WorkflowValue.number_value(node.id, output_name_or(node, String("count"), String("count")), String(count)))
    result.add_log(String("vhs_sequence ") + node.title + String(" count=") + String(count))
    return True


def _primary_sequence_value(graph: Graph, node: Node, result: WorkflowExecutionResult) -> WorkflowValue:
    var value = first_incoming_kind(graph, result, node.id, WV_IMAGE)
    if value.kind != WV_IMAGE:
        value = first_incoming_kind(graph, result, node.id, WV_LATENT)
    if value.kind != WV_IMAGE and value.kind != WV_LATENT:
        value = WorkflowValue.image_path(node.id, String("IMAGE"), String(""), 0, 0, -1)
    return value^


def _secondary_sequence_value(graph: Graph, node: Node, result: WorkflowExecutionResult, kind: Int32) -> WorkflowValue:
    var seen_first = False
    for i in range(graph.edge_count()):
        if graph.edges[i].to_node == node.id:
            var value = result.find_value(graph.edges[i].from_node, graph.edges[i].from_port)
            if value.kind == kind:
                if seen_first:
                    return value^
                seen_first = True
    var fallback = WorkflowValue()
    fallback.kind = kind
    fallback.batch_size = Int32(0)
    return fallback^


def _emit_sequence_value(node: Node, mut result: WorkflowExecutionResult, value: WorkflowValue, slot: Int32, count: Int32):
    var out = value.copy()
    out.node_id = node.id
    if slot >= Int32(0) and slot < Int32(len(node.outputs)):
        out.port = node.outputs[Int(slot)].name.copy()
    else:
        out.port = first_output_name(node, String("IMAGE"))
    out.batch_size = count
    result.add_value(out^)


def _emit_info_set(node: Node, mut result: WorkflowExecutionResult, info: String, prefix: String) raises:
    var fps = _json_number_field(info, prefix + String("fps"), 0.0)
    var frame_count = Int32(_json_number_field(info, prefix + String("frame_count"), 0.0))
    var duration = _json_number_field(info, prefix + String("duration"), 0.0)
    var width = Int32(_json_number_field(info, prefix + String("width"), 0.0))
    var height = Int32(_json_number_field(info, prefix + String("height"), 0.0))
    var offset = Int32(0)
    if prefix == String("loaded_") and len(node.outputs) > 5:
        offset = Int32(5)
    _add_number_at(node, result, offset + Int32(0), String("fps"), String(fps))
    _add_number_at(node, result, offset + Int32(1), String("frame_count"), String(frame_count))
    _add_number_at(node, result, offset + Int32(2), String("duration"), String(duration))
    _add_number_at(node, result, offset + Int32(3), String("width"), String(width))
    _add_number_at(node, result, offset + Int32(4), String("height"), String(height))


def _add_number_at(node: Node, mut result: WorkflowExecutionResult, index: Int32, fallback: String, text: String):
    var port = fallback.copy()
    if index >= Int32(0) and index < Int32(len(node.outputs)):
        port = node.outputs[Int(index)].name.copy()
    result.add_value(WorkflowValue.number_value(node.id, port, text))


def _video_info_json(fps: Float64, frame_count: Int32, width: Int32, height: Int32) -> String:
    var duration = 0.0
    if fps > 0.0:
        duration = Float64(frame_count) / fps
    return (
        String("{\"source_fps\":")
        + String(fps)
        + String(",\"source_frame_count\":")
        + String(frame_count)
        + String(",\"source_duration\":")
        + String(duration)
        + String(",\"source_width\":")
        + String(width)
        + String(",\"source_height\":")
        + String(height)
        + String(",\"loaded_fps\":")
        + String(fps)
        + String(",\"loaded_frame_count\":")
        + String(frame_count)
        + String(",\"loaded_duration\":")
        + String(duration)
        + String(",\"loaded_width\":")
        + String(width)
        + String(",\"loaded_height\":")
        + String(height)
        + String("}")
    )


def _json_number_field(text: String, key: String, fallback: Float64) raises -> Float64:
    if text.byte_length() == 0:
        return fallback
    var parsed = parse_json(text)
    if parsed.kind != JK_OBJECT:
        return fallback
    var value = parsed.get_object_field(key)
    if value.kind != JK_NUMBER:
        return fallback
    return value.num_val


def _latest_file_from_filenames(text: String) -> String:
    var marker = String("\"files\":[\"")
    var start = _find_substr(text, marker)
    if start < 0:
        return text.copy()
    start = start + marker.byte_length()
    var end = start
    var ptr = text.unsafe_ptr()
    while end < text.byte_length():
        if ptr[end] == UInt8(34):
            break
        end = end + 1
    var bytes = List[UInt8]()
    for i in range(start, end):
        bytes.append(ptr[i])
    return String(unsafe_from_utf8=bytes^)


def _format_extension(format: String) -> String:
    if _find_substr(format, String("webm")) >= 0:
        return String(".webm")
    if _find_substr(format, String("gif")) >= 0:
        return String(".gif")
    if _find_substr(format, String("png")) >= 0:
        return String(".png")
    if _find_substr(format, String("webp")) >= 0:
        return String(".webp")
    if _find_substr(format, String("mkv")) >= 0:
        return String(".mkv")
    return String(".mp4")


def _selection_count(indexes: String, fallback: Int32) -> Int32:
    if indexes.byte_length() == 0:
        return fallback
    var ptr = indexes.unsafe_ptr()
    var count = Int32(0)
    var in_number = False
    for i in range(indexes.byte_length()):
        var c = ptr[i]
        if c >= UInt8(48) and c <= UInt8(57):
            if not in_number:
                count = count + Int32(1)
            in_number = True
        else:
            in_number = False
    if count <= Int32(0):
        return fallback
    return count


def _find_substr(haystack: String, needle: String) -> Int:
    var hn = haystack.byte_length()
    var nn = needle.byte_length()
    if nn == 0:
        return 0
    if nn > hn:
        return -1
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            var a = hp[i + j]
            var b = np[j]
            if a >= UInt8(65) and a <= UInt8(90):
                a = a + UInt8(32)
            if b >= UInt8(65) and b <= UInt8(90):
                b = b + UInt8(32)
            if a != b:
                matched = False
                break
        if matched:
            return i
    return -1
