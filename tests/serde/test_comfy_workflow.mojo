"""Smoke tests for ComfyUI workflow JSON import.

Run: `pixi run test-comfy-workflow`
"""

from mojoui.core.id import RetainedId
from mojoui.nodes.node import FK_STRING
from mojoui.nodes.port import (
    NVT_IMAGE,
    NVT_VIDEO,
    NVT_BBOX,
    NVT_MODEL,
    NVT_CLIP,
    NVT_CONDITIONING,
    NVT_LATENT,
    NVT_NUMBER,
    NVT_TEXT,
)
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


def test_parse_ltxv_lora_api_prompt() raises:
    var raw = String(
        "{"
        + "\"1\":{\"class_type\":\"LTXVLoader\",\"inputs\":{\"checkpoint_path\":\"model.safetensors\",\"gemma_path\":\"gemma\"}},"
        + "\"10\":{\"class_type\":\"LTXVLoraLoader\",\"inputs\":{\"ltxv_model\":[\"1\",0],\"lora_name\":\"\",\"strength_model\":1.0}},"
        + "\"2\":{\"class_type\":\"LTXVSampler\",\"inputs\":{\"ltxv_model\":[\"10\",0],\"prompt\":\"test\"}}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 3:
        _fail("ltxv api: expected 3 nodes")
    if imported.graph.edge_count() != 2:
        _fail("ltxv api: expected loader -> lora -> sampler edges")
    if len(imported.graph.nodes[0].outputs) != 1 \
        or imported.graph.nodes[0].outputs[0].name != String("LTXV_MODEL") \
        or imported.graph.nodes[0].outputs[0].value_type != NVT_MODEL:
        _fail("ltxv api: loader should expose one LTXV model output")
    if len(imported.graph.nodes[1].outputs) != 1 \
        or imported.graph.nodes[1].outputs[0].name != String("LTXV_MODEL") \
        or imported.graph.nodes[1].outputs[0].value_type != NVT_MODEL:
        _fail("ltxv api: LoRA loader should expose one LTXV model output")
    if len(imported.graph.nodes[2].outputs) != 3 \
        or imported.graph.nodes[2].outputs[1].value_type != NVT_VIDEO:
        _fail("ltxv api: sampler should expose frames, video, and audio")
    print("PASS: test_parse_ltxv_lora_api_prompt")


def test_parse_popular_extension_api_prompt() raises:
    var raw = String(
        "{"
        + "\"1\":{\"class_type\":\"CLIPLoader\",\"inputs\":{\"clip_name\":\"qwen_clip.safetensors\",\"type\":\"stable_diffusion\"}},"
        + "\"2\":{\"class_type\":\"Power Prompt (rgthree)\",\"inputs\":{\"opt_clip\":[\"1\",0],\"prompt\":\"serenity prompt\"}},"
        + "\"3\":{\"class_type\":\"INTConstant\",\"inputs\":{\"value\":640}},"
        + "\"4\":{\"class_type\":\"Any Switch (rgthree)\",\"inputs\":{\"any_01\":[\"2\",3]}},"
        + "\"5\":{\"class_type\":\"Image Resize (rgthree)\",\"inputs\":{\"image\":[\"6\",0],\"width\":[\"3\",0],\"height\":480}},"
        + "\"6\":{\"class_type\":\"LoadImage\",\"inputs\":{\"image\":\"source.png\"}}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 6:
        _fail("popular api: expected 6 nodes")
    if imported.graph.edge_count() != 4:
        _fail("popular api: expected 4 edges, got " + String(imported.graph.edge_count()))
    if imported.graph.nodes[0].outputs[0].value_type != NVT_CLIP:
        _fail("popular api: CLIPLoader should infer CLIP")
    if imported.graph.nodes[1].outputs[0].value_type != NVT_CONDITIONING:
        _fail("popular api: Power Prompt should infer conditioning first")
    if imported.graph.nodes[1].outputs[3].value_type != NVT_TEXT:
        _fail("popular api: Power Prompt should infer TEXT output")
    if imported.graph.nodes[2].outputs[0].value_type != NVT_NUMBER:
        _fail("popular api: INTConstant should infer number output")
    if imported.graph.nodes[4].outputs[0].value_type != NVT_IMAGE:
        _fail("popular api: Image Resize should infer image output")
    if imported.graph.nodes[4].outputs[1].value_type != NVT_NUMBER:
        _fail("popular api: Image Resize should infer width output")
    if imported.graph.edges[1].from_port != String("TEXT"):
        _fail("popular api: Any Switch should link from Power Prompt TEXT slot")
    print("PASS: test_parse_popular_extension_api_prompt")


def test_parse_lanpaint_visual_workflow() raises:
    var raw = String(
        "{"
        + "\"nodes\":["
        + "{\"id\":1,\"type\":\"LanPaint_MaskBlend\",\"pos\":[10,20],\"size\":[280,135],\"inputs\":[{\"name\":\"image1\",\"type\":\"IMAGE\",\"link\":1},{\"name\":\"image2\",\"type\":\"IMAGE\",\"link\":2},{\"name\":\"mask\",\"type\":\"MASK\",\"link\":3}],\"outputs\":[{\"name\":\"IMAGE\",\"type\":\"IMAGE\",\"slot_index\":0,\"links\":[]}]},"
        + "{\"id\":2,\"type\":\"LanPaint_SamplerCustomAdvanced\",\"pos\":[320,20],\"size\":[420,420],\"inputs\":[{\"name\":\"noise\",\"type\":\"NOISE\",\"link\":4},{\"name\":\"guider\",\"type\":\"GUIDER\",\"link\":5},{\"name\":\"sampler\",\"type\":\"SAMPLER\",\"link\":6},{\"name\":\"sigmas\",\"type\":\"SIGMAS\",\"link\":7},{\"name\":\"latent_image\",\"type\":\"LATENT\",\"link\":8}],\"outputs\":[{\"name\":\"output\",\"type\":\"LATENT\",\"slot_index\":0,\"links\":[]},{\"name\":\"denoised_output\",\"type\":\"LATENT\",\"slot_index\":1,\"links\":[]}],\"widgets_values\":[5,16,0.2,1,15,\"Image First\",1,\"LanPaint\",0,1]}"
        + "],\"links\":[],\"groups\":[]"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 2:
        _fail("lanpaint visual: expected 2 nodes")
    if imported.graph.nodes[0].inputs[2].value_type != NVT_IMAGE:
        _fail("lanpaint visual: MASK socket should map to image-like value")
    if imported.graph.nodes[1].inputs[0].value_type != NVT_TEXT:
        _fail("lanpaint visual: NOISE socket should map to text handle")
    if imported.graph.nodes[1].inputs[2].value_type != NVT_TEXT:
        _fail("lanpaint visual: SAMPLER socket should map to text handle")
    if imported.graph.nodes[1].inputs[3].value_type != NVT_NUMBER:
        _fail("lanpaint visual: SIGMAS socket should map to numeric schedule handle")
    if imported.graph.nodes[1].outputs[0].name != String("output") or imported.graph.nodes[1].outputs[0].value_type != NVT_LATENT:
        _fail("lanpaint visual: custom sampler output should be LATENT")
    if imported.graph.nodes[1].outputs[1].name != String("denoised_output") or imported.graph.nodes[1].outputs[1].value_type != NVT_LATENT:
        _fail("lanpaint visual: custom sampler denoised output should be LATENT")
    print("PASS: test_parse_lanpaint_visual_workflow")


def test_parse_lanpaint_api_prompt() raises:
    var raw = String(
        "{"
        + "\"1\":{\"class_type\":\"EmptyLatentImage\",\"inputs\":{\"width\":1024,\"height\":1024}},"
        + "\"2\":{\"class_type\":\"LanPaint_SamplerCustomAdvanced\",\"inputs\":{\"latent_image\":[\"1\",0],\"LanPaint_NumSteps\":5,\"LanPaint_PromptMode\":\"Image First\"}},"
        + "\"3\":{\"class_type\":\"LanPaint_MaskBlend\",\"inputs\":{\"image1\":[\"4\",0],\"image2\":[\"4\",0],\"mask\":[\"4\",0]}},"
        + "\"4\":{\"class_type\":\"LoadImage\",\"inputs\":{\"image\":\"source.png\"}}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 4:
        _fail("lanpaint api: expected 4 nodes")
    if len(imported.graph.nodes[1].outputs) != 2:
        _fail("lanpaint api: custom sampler should infer two outputs")
    if imported.graph.nodes[1].outputs[0].name != String("output"):
        _fail("lanpaint api: first output should be output")
    if imported.graph.nodes[1].outputs[1].name != String("denoised_output"):
        _fail("lanpaint api: second output should be denoised_output")
    if imported.graph.nodes[2].outputs[0].value_type != NVT_IMAGE:
        _fail("lanpaint api: MaskBlend should infer IMAGE output")
    print("PASS: test_parse_lanpaint_api_prompt")


def test_parse_vhs_visual_workflow() raises:
    var raw = String(
        "{"
        + "\"nodes\":["
        + "{\"id\":1,\"type\":\"VHS_LoadVideo\",\"pos\":[54,89],\"size\":[235,384],\"outputs\":[{\"name\":\"IMAGE\",\"type\":\"IMAGE\",\"slot_index\":0,\"links\":[1]},{\"name\":\"frame_count\",\"type\":\"INT\",\"slot_index\":1,\"links\":null},{\"name\":\"audio\",\"type\":\"VHS_AUDIO\",\"slot_index\":2,\"links\":null},{\"name\":\"video_info\",\"type\":\"VHS_VIDEOINFO\",\"slot_index\":3,\"links\":null}],\"widgets_values\":{\"video\":\"leader.webm\",\"force_rate\":8,\"custom_width\":304,\"custom_height\":312,\"frame_load_cap\":16}},"
        + "{\"id\":2,\"type\":\"VHS_VideoCombine\",\"pos\":[629,222],\"size\":{\"0\":315,\"1\":250},\"inputs\":[{\"name\":\"images\",\"type\":\"IMAGE\",\"link\":1},{\"name\":\"audio\",\"type\":\"VHS_AUDIO\",\"link\":null}],\"outputs\":[{\"name\":\"Filenames\",\"type\":\"VHS_FILENAMES\",\"slot_index\":0,\"links\":null}],\"widgets_values\":{\"frame_rate\":8,\"filename_prefix\":\"AnimateDiff\",\"format\":\"video/webm\",\"save_output\":true}}"
        + "],\"links\":[[1,1,0,2,0,\"IMAGE\"]],\"groups\":[]"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 2:
        _fail("vhs visual: expected 2 nodes")
    if imported.graph.edge_count() != 1:
        _fail("vhs visual: expected 1 edge")
    if imported.graph.nodes[0].outputs[2].value_type != NVT_TEXT:
        _fail("vhs visual: VHS_AUDIO should map to text handle")
    if imported.graph.nodes[0].outputs[3].value_type != NVT_TEXT:
        _fail("vhs visual: VHS_VIDEOINFO should map to text handle")
    if imported.graph.nodes[1].outputs[0].value_type != NVT_TEXT:
        _fail("vhs visual: VHS_FILENAMES should map to text handle")
    var video = imported.graph.nodes[0].get_field(String("video"))
    if video.kind != FK_STRING or video.str_val != String("leader.webm"):
        _fail("vhs visual: object widgets_values should preserve named video field")
    print("PASS: test_parse_vhs_visual_workflow")


def test_parse_vhs_api_prompt() raises:
    var raw = String(
        "{"
        + "\"1\":{\"class_type\":\"VHS_LoadVideoPath\",\"inputs\":{\"video\":\"/tmp/input.mp4\",\"force_rate\":12,\"frame_load_cap\":24}},"
        + "\"2\":{\"class_type\":\"VHS_VideoInfoLoaded\",\"inputs\":{\"video_info\":[\"1\",3]}},"
        + "\"3\":{\"class_type\":\"VHS_SelectEveryNthImage\",\"inputs\":{\"images\":[\"1\",0],\"select_every_nth\":2}},"
        + "\"4\":{\"class_type\":\"VHS_VideoCombine\",\"inputs\":{\"images\":[\"3\",0],\"frame_rate\":12,\"format\":\"video/mp4\"}}"
        + "}"
    )
    var imported = parse_comfy_workflow(raw)
    if imported.graph.node_count() != 4:
        _fail("vhs api: expected 4 nodes")
    if imported.graph.nodes[0].outputs[0].value_type != NVT_IMAGE:
        _fail("vhs api: LoadVideoPath should infer IMAGE output")
    if imported.graph.nodes[0].outputs[3].value_type != NVT_TEXT:
        _fail("vhs api: LoadVideoPath should infer video_info handle")
    if len(imported.graph.nodes[1].outputs) != 5:
        _fail("vhs api: VideoInfoLoaded should infer 5 outputs")
    if imported.graph.nodes[2].outputs[0].value_type != NVT_IMAGE:
        _fail("vhs api: SelectEveryNthImage should infer image output")
    if imported.graph.nodes[3].outputs[0].name != String("Filenames"):
        _fail("vhs api: VideoCombine should infer Filenames output")
    print("PASS: test_parse_vhs_api_prompt")


def main() raises:
    test_parse_visual_workflow_nodes_links_groups()
    test_parse_swarm_workflow_wrapper()
    test_parse_comfy_api_prompt()
    test_parse_ltxv_lora_api_prompt()
    test_parse_popular_extension_api_prompt()
    test_parse_lanpaint_visual_workflow()
    test_parse_lanpaint_api_prompt()
    test_parse_vhs_visual_workflow()
    test_parse_vhs_api_prompt()
    print("PASS: all Comfy workflow import smoke tests")
