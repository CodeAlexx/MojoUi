"""Smoke tests for workflow render request extraction."""

from mojoui.core.types import Vec2
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import FieldValue
from mojoui.nodes.canvas_model import CanvasState
from mojoui.app.workflow_render import (
    extract_render_request,
    apply_magic_prompt,
    render_request_aspect_ratio,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _contains(haystack: String, needle: String) -> Bool:
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


def test_extract_ideogram_request_from_graph() raises:
    var graph = Graph()
    _ = graph.add_node(String("comfy/ResolutionSelector"), Vec2.zero())
    graph.nodes[0].set_field(
        String("widget_0"),
        FieldValue.string(String("9:16 (Portrait Widescreen)")),
    )
    var prompt = graph.add_node(String("comfy/Ideogram4Prompt"), Vec2(220.0, 0.0))
    graph.nodes[1].set_field(
        String("prompt"),
        FieldValue.string(String("anime city street at sunset")),
    )
    var save = graph.add_node(String("comfy/SaveImage"), Vec2(440.0, 0.0))
    graph.nodes[2].set_field(
        String("widget_0"),
        FieldValue.string(String("Ideogram_4.0")),
    )

    var canvas = CanvasState()
    canvas.selected_group = Int64(42)
    var request = extract_render_request(graph, canvas)

    _expect(request.backend == String("ideogram4"), "Ideogram node should select ideogram4 backend")
    _expect(request.magic_prompt_enabled, "Ideogram backend should enable magic prompt")
    _expect(request.magic_prompt_entry == String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_magic.mojo"), "magic entry should point at mojodiffusion")
    _expect(request.generate_entry == String("/home/alex/mojodiffusion/serenitymojo/pipeline/ideogram4_generate.mojo"), "generate entry should point at mojodiffusion")
    _expect(request.prompt == String("anime city street at sunset"), "prompt should come from prompt field")
    _expect(request.width == 576 and request.height == 1024, "9:16 ResolutionSelector should map to portrait dimensions")
    _expect(request.steps == 48, "Ideogram default steps should be 48")
    _expect(request.seed == Int64(0), "Ideogram default seed should be 0")
    _expect(request.source_node == prompt, "source node should be the prompt node")
    _expect(request.save_node == save, "save node should be SaveImage")
    _expect(request.output_path == String("Ideogram_4.0"), "SaveImage widget_0 should feed output path/prefix")
    _expect(request.selected_group == Int64(42), "canvas selected group should be carried")
    _expect(request.canvas_node_count == 3, "node count should be carried")
    _expect(render_request_aspect_ratio(request) == String("9:16"), "request should report 9:16 aspect")

    var magic = apply_magic_prompt(request)
    _expect(_contains(magic.prompt, String("\"high_level_description\"")), "magic prompt should be JSON-caption shaped")
    _expect(_contains(magic.prompt, String("compositional_deconstruction")), "magic prompt should include composition section")
    _expect(_contains(magic.prompt, String("anime city street at sunset")), "magic prompt should include original prompt")
    print("PASS: extract Ideogram request")


def test_default_request_from_empty_graph() raises:
    var graph = Graph()
    var canvas = CanvasState()
    var request = extract_render_request(graph, canvas)
    _expect(request.backend == String("zimage"), "empty graph defaults to zimage backend")
    _expect(not request.magic_prompt_enabled, "empty graph should not enable magic prompt")
    _expect(request.width == 1024 and request.height == 1024, "default request should be square")
    _expect(request.steps == 28, "default request keeps app image steps")
    _expect(request.canvas_node_count == 0, "empty graph node count should be 0")
    print("PASS: default empty graph request")


def main() raises:
    test_extract_ideogram_request_from_graph()
    test_default_request_from_empty_graph()
    print("PASS: all 2 workflow-render tests")
