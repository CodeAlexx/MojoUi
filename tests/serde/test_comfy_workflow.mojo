"""Smoke tests for ComfyUI workflow JSON import.

Run: `pixi run test-comfy-workflow`
"""

from mojoui.core.id import RetainedId
from mojoui.nodes.node import FK_STRING
from mojoui.nodes.port import NVT_IMAGE, NVT_VIDEO, NVT_BBOX, NVT_MODEL, NVT_CLIP
from mojoui.serde.comfy_workflow import parse_comfy_workflow


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_parse_visual_workflow_nodes_links_groups() raises:
    var raw = String(
        "{"
        + "\"nodes\":["
        + "{\"id\":1,\"type\":\"LoadImage\",\"pos\":[10,20],\"size\":[120,90],\"outputs\":[{\"name\":\"IMAGE\",\"type\":\"IMAGE\",\"slot_index\":0,\"links\":[5]}],\"properties\":{\"cnr_id\":\"comfy-core\",\"ver\":\"0.23.0\"},\"widgets_values\":[\"foo.png\",\"image\"]},"
        + "{\"id\":2,\"type\":\"PreviewImage\",\"pos\":[260,20],\"size\":[160,90],\"mode\":2,\"inputs\":[{\"name\":\"images\",\"type\":\"IMAGE\",\"link\":5}]},"
        + "{\"id\":3,\"type\":\"VHS_VideoCombine\",\"pos\":[260,180],\"size\":[180,100],\"outputs\":[{\"name\":\"VIDEO\",\"type\":\"VIDEO\",\"slot_index\":0,\"links\":null},{\"name\":\"BBOXES\",\"type\":\"BBOX\",\"slot_index\":1,\"links\":null}]}"
        + "],"
        + "\"links\":[[5,1,0,2,0,\"IMAGE\"]],"
        + "\"groups\":[{\"id\":7,\"title\":\"Images\",\"bounding\":[0,0,460,150],\"color\":\"#444\"}],"
        + "\"config\":{}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)

    if imported.graph.node_count() != 3:
        _fail("expected 3 imported nodes, got " + String(imported.graph.node_count()))
    if imported.graph.edge_count() != 1:
        _fail("expected 1 imported edge, got " + String(imported.graph.edge_count()))

    if imported.graph.nodes[0].id != RetainedId(1):
        _fail("node id should preserve Comfy id 1")
    if imported.graph.nodes[0].type_id != String("comfy/LoadImage"):
        _fail("node type_id should be namespaced comfy/LoadImage")
    if imported.graph.nodes[0].title != String("LoadImage"):
        _fail("node title should default to Comfy type")
    if imported.graph.nodes[0].position.x != 10.0 or imported.graph.nodes[0].position.y != 20.0:
        _fail("node position should preserve Comfy pos")
    if imported.graph.nodes[0].size.x != 120.0 or imported.graph.nodes[0].size.y != 90.0:
        _fail("node size should preserve Comfy size")
    if imported.graph.nodes[0].outputs[0].name != String("IMAGE"):
        _fail("output port name should come from Comfy output slot")
    if imported.graph.nodes[0].outputs[0].value_type != NVT_IMAGE:
        _fail("IMAGE socket should map to NVT_IMAGE")

    var widget = imported.graph.nodes[0].get_field(String("widget_0"))
    if widget.kind != FK_STRING or widget.str_val != String("foo.png"):
        _fail("widget_0 should preserve first widget value")
    var prop = imported.graph.nodes[0].get_field(String("prop_cnr_id"))
    if prop.kind != FK_STRING or prop.str_val != String("comfy-core"):
        _fail("Comfy properties should import under prop_* fields")
    if not imported.graph.nodes[1].muted:
        _fail("Comfy mode=2 should import as muted")
    if imported.graph.nodes[2].outputs[0].value_type != NVT_VIDEO:
        _fail("VIDEO socket should map to NVT_VIDEO")
    if imported.graph.nodes[2].outputs[1].value_type != NVT_BBOX:
        _fail("BBOX socket should map to NVT_BBOX")

    if imported.graph.edges[0].from_node != RetainedId(1):
        _fail("edge from_node should map from link source")
    if imported.graph.edges[0].from_port != String("IMAGE"):
        _fail("edge from_port should resolve source slot to output name")
    if imported.graph.edges[0].to_node != RetainedId(2):
        _fail("edge to_node should map from link target")
    if imported.graph.edges[0].to_port != String("images"):
        _fail("edge to_port should resolve target slot to input name")

    if len(imported.canvas.groups) != 1:
        _fail("expected one imported Comfy group")
    if imported.canvas.groups[0].id != Int64(7):
        _fail("group id should preserve Comfy group id")
    if imported.canvas.groups[0].title != String("Images"):
        _fail("group title should preserve Comfy group title")
    if len(imported.canvas.groups[0].members) != 2:
        _fail("group should bind two intersecting nodes")
    if (
        Int(imported.canvas.groups[0].color.r) != 68
        or Int(imported.canvas.groups[0].color.g) != 68
        or Int(imported.canvas.groups[0].color.b) != 68
    ):
        _fail("shorthand group color #444 should expand to #444444")
    if imported.canvas.next_group_id != Int64(8):
        _fail("next group id should advance beyond imported group")
    if imported.graph.id_alloc.next_index != UInt64(4):
        _fail("graph allocator should seed past highest imported node id")

    print("PASS: test_parse_visual_workflow_nodes_links_groups")


def test_parse_swarm_workflow_wrapper() raises:
    var raw = String(
        "{"
        + "\"workflow\":{"
        + "\"nodes\":["
        + "{\"id\":5,\"type\":\"EmptyLatentImage\",\"pos\":[128,256],\"size\":{\"0\":315,\"1\":106},\"outputs\":[{\"name\":\"LATENT\",\"type\":\"LATENT\",\"slot_index\":0,\"links\":[]}]}"
        + "],"
        + "\"links\":[],\"groups\":[]"
        + "}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 1:
        _fail("wrapper: expected one node")
    if imported.graph.nodes[0].position.x != 128.0 or imported.graph.nodes[0].position.y != 256.0:
        _fail("wrapper: position should parse from nested workflow")
    if imported.graph.nodes[0].size.x != 315.0 or imported.graph.nodes[0].size.y != 106.0:
        _fail("wrapper: indexed-object size should parse")
    print("PASS: test_parse_swarm_workflow_wrapper")


def test_parse_comfy_api_prompt() raises:
    var raw = String(
        "{"
        + "\"1\":{\"class_type\":\"UNETLoader\",\"inputs\":{\"unet_name\":\"flux2-klein-9b.safetensors\"},\"_meta\":{\"title\":\"Load Klein 9B\"}},"
        + "\"2\":{\"class_type\":\"CLIPLoader\",\"inputs\":{\"clip_name\":\"Qwen/Qwen3-8B\",\"type\":\"klein\"}},"
        + "\"3\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"clip\":[\"2\",0],\"text\":\"a beautiful landscape\"}},"
        + "\"4\":{\"class_type\":\"KSampler\",\"inputs\":{\"model\":[\"1\",0],\"positive\":[\"3\",0],\"negative\":[\"3\",0],\"seed\":42,\"steps\":8,\"cfg\":3.5}}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 4:
        _fail("api: expected 4 nodes")
    if imported.graph.edge_count() != 4:
        _fail("api: expected 4 inferred edges, got " + String(imported.graph.edge_count()))
    if imported.graph.nodes[0].outputs[0].value_type != NVT_MODEL:
        _fail("api: UNETLoader should infer MODEL output")
    if imported.graph.nodes[1].outputs[0].value_type != NVT_CLIP:
        _fail("api: CLIPLoader should infer CLIP output")
    if imported.graph.edges[0].from_node != RetainedId(2) or imported.graph.edges[0].to_node != RetainedId(3):
        _fail("api: clip edge endpoints should import")
    if imported.graph.edges[0].from_port != String("CLIP") or imported.graph.edges[0].to_port != String("clip"):
        _fail("api: clip edge ports should infer by slot/name")
    var text = imported.graph.nodes[2].get_field(String("text"))
    if text.kind != FK_STRING or text.str_val != String("a beautiful landscape"):
        _fail("api: constant input text should become field")
    if len(imported.canvas.groups) != 1:
        _fail("api: auto group should be created")
    print("PASS: test_parse_comfy_api_prompt")


def main() raises:
    test_parse_visual_workflow_nodes_links_groups()
    test_parse_swarm_workflow_wrapper()
    test_parse_comfy_api_prompt()
    print("PASS: all Comfy workflow import smoke tests")
