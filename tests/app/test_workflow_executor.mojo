"""Smoke tests for the pure-Mojo workflow executor backend."""

from mojoui.core.types import Vec2
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import FieldValue, PortRef
from mojoui.nodes.port import (
    NVT_CLIP,
    NVT_CONDITIONING,
    NVT_IMAGE,
    NVT_LATENT,
    NVT_MODEL,
    NVT_TEXT,
    NVT_VAE,
    NVT_VIDEO,
    NVT_BBOX,
    NVT_NUMBER,
)
from mojoui.nodes.execution import EXEC_DONE, EXEC_SKIPPED
from mojoui.nodes.canvas_model import CanvasState
from mojoui.app.workflow_executor import (
    WV_TEXT,
    WV_IMAGE,
    WV_VIDEO,
    WV_BBOX,
    WV_NUMBER,
    WV_MODEL,
    WV_CLIP,
    WV_VAE,
    WV_LATENT,
    WV_CONDITIONING,
    WLS_STAGED,
    WorkflowDeviceConfig,
    execute_workflow,
    execute_workflow_with_device,
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


def test_execute_ideogram_workflow() raises:
    var graph = Graph()
    var magic = graph.add_node(String("core/ideogram4_magic_prompt"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("caption_json"), NVT_TEXT))
    graph.nodes[0].set_field(
        String("prompt"),
        FieldValue.string(String("glossy blue robot in a neon studio")),
    )

    var generate = graph.add_node(String("core/ideogram4_generate"), Vec2(260.0, 0.0))
    graph.nodes[1].add_input(PortRef(String("caption_json"), NVT_TEXT))
    graph.nodes[1].add_output(PortRef(String("image"), NVT_IMAGE))
    graph.nodes[1].set_field(String("width"), FieldValue.int_(Int64(1024)))
    graph.nodes[1].set_field(String("height"), FieldValue.int_(Int64(1024)))
    graph.nodes[1].set_field(
        String("output_path"),
        FieldValue.string(String("/tmp/ideogram_backend.png")),
    )

    var save = graph.add_node(String("core/save_image"), Vec2(520.0, 0.0))
    graph.nodes[2].add_input(PortRef(String("image"), NVT_IMAGE))

    _ = graph.add_edge(magic, String("caption_json"), generate, String("caption_json"))
    _ = graph.add_edge(generate, String("image"), save, String("image"))

    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)

    _expect(result.success, "ideogram workflow should succeed")
    _expect(result.device.device_kind == String("gpu"), "executor should default to GPU")
    _expect(result.device.require_gpu, "executor should require GPU by default")
    _expect(not result.device.allow_cpu_fallback, "executor should not allow CPU fallback by default")
    _expect(result.plan.step_count() == 3, "ideogram workflow should have 3 steps")
    _expect(result.plan.steps[0].status == EXEC_DONE, "magic step should be done")
    _expect(result.plan.steps[1].status == EXEC_DONE, "generate step should be done")
    _expect(result.plan.steps[2].status == EXEC_DONE, "save step should be done")
    var caption = result.find_value(magic, String("caption_json"))
    _expect(caption.kind == WV_TEXT, "magic node should produce text")
    _expect(
        _contains(caption.text, String("compositional_deconstruction")),
        "magic output should be structured caption JSON",
    )
    var image = result.find_value(generate, String("image"))
    _expect(image.kind == WV_IMAGE, "generate should produce image value")
    _expect(image.path == String("/tmp/ideogram_backend.png"), "generate image path should come from node field")
    _expect(result.launch_count() == 2, "magic and generate should stage two GPU launches")
    _expect(result.launches[0].backend == String("ideogram4_magic_prompt"), "first launch should be magic prompt")
    _expect(result.launches[1].backend == String("ideogram4"), "second launch should be Ideogram4 generate")
    _expect(result.launches[1].device_kind == String("gpu"), "Ideogram launch should target GPU")
    _expect(result.launches[1].status == WLS_STAGED, "dry-run GPU launch should be staged")
    _expect(
        _contains(result.launches[1].command, String("--device gpu:0")),
        "GPU command should include device selector",
    )
    _expect(len(result.artifacts) == 2, "generate and save should each add image artifacts")
    _expect(result.artifacts[0].path == String("/tmp/ideogram_backend.png"), "first artifact should be generated image")
    _expect(result.artifacts[1].path == String("/tmp/ideogram_backend.png"), "save artifact should carry generated path")
    print("PASS: execute Ideogram workflow")


def test_execute_serenity_prompt_builder_workflow() raises:
    var graph = Graph()
    var load = graph.add_node(String("core/load_image"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("image"), NVT_IMAGE))
    graph.nodes[0].set_field(String("path"), FieldValue.string(String("/tmp/input.png")))

    var builder = graph.add_node(String("core/ideogram4_prompt_builder"), Vec2(260.0, 0.0))
    graph.nodes[1].title = String("SerenityUI Ideogram Prompt Builder")
    graph.nodes[1].add_input(PortRef(String("image"), NVT_IMAGE))
    graph.nodes[1].add_input(PortRef(String("import_json"), NVT_TEXT))
    graph.nodes[1].add_input(PortRef(String("bboxes"), NVT_BBOX))
    graph.nodes[1].add_output(PortRef(String("prompt"), NVT_TEXT))
    graph.nodes[1].add_output(PortRef(String("preview"), NVT_IMAGE))
    graph.nodes[1].add_output(PortRef(String("bboxes"), NVT_BBOX))
    graph.nodes[1].add_output(PortRef(String("width"), NVT_NUMBER))
    graph.nodes[1].add_output(PortRef(String("height"), NVT_NUMBER))
    graph.nodes[1].set_field(String("width"), FieldValue.int_(Int64(1000)))
    graph.nodes[1].set_field(String("height"), FieldValue.int_(Int64(1000)))
    graph.nodes[1].set_field(String("background"), FieldValue.string(String("quiet studio")))
    graph.nodes[1].set_field(String("style"), FieldValue.string(String("art_style")))
    graph.nodes[1].set_field(String("art_style"), FieldValue.string(String("anime key art")))
    graph.nodes[1].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"x\":0.1,\"y\":0.2,\"w\":0.4,\"h\":0.3,\"type\":\"obj\",\"desc\":\"blue robot\",\"palette\":[\"#112233\"]}]")
        ),
    )

    var magic = graph.add_node(String("core/ideogram4_magic_prompt"), Vec2(780.0, 0.0))
    graph.nodes[2].add_input(PortRef(String("prompt"), NVT_TEXT))
    graph.nodes[2].add_output(PortRef(String("caption_json"), NVT_TEXT))

    _ = graph.add_edge(load, String("image"), builder, String("image"))
    _ = graph.add_edge(builder, String("prompt"), magic, String("prompt"))

    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)
    _expect(result.success, "prompt builder workflow should succeed")
    var prompt = result.find_value(builder, String("prompt"))
    _expect(prompt.kind == WV_TEXT, "prompt builder should produce prompt text")
    _expect(_contains(prompt.text, String("compositional_deconstruction")), "prompt should be Ideogram JSON")
    _expect(_contains(prompt.text, String("\"bbox\":[200,100,500,500]")), "prompt should normalize bbox to 0-1000 grid")
    _expect(_contains(prompt.text, String("blue robot")), "prompt should include element description")
    var preview = result.find_value(builder, String("preview"))
    _expect(preview.kind == WV_IMAGE, "prompt builder should produce preview image value")
    _expect(preview.path == String("/tmp/input.png"), "preview image should carry source image path")
    var boxes = result.find_value(builder, String("bboxes"))
    _expect(boxes.kind == WV_BBOX, "prompt builder should produce bbox value")
    _expect(_contains(boxes.text, String("\"x\":100")), "bbox output should include pixel x")
    _expect(_contains(boxes.text, String("\"y\":200")), "bbox output should include pixel y")
    _expect(_contains(boxes.text, String("\"width\":400")), "bbox output should include pixel width")
    _expect(_contains(boxes.text, String("\"height\":300")), "bbox output should include pixel height")
    var width = result.find_value(builder, String("width"))
    var height = result.find_value(builder, String("height"))
    _expect(width.kind == WV_NUMBER and width.text == String("1000"), "width output should be numeric text")
    _expect(height.kind == WV_NUMBER and height.text == String("1000"), "height output should be numeric text")
    _expect(result.launch_count() == 1, "magic prompt should stage one GPU launch after builder")
    print("PASS: execute SerenityUI prompt builder workflow")


def test_execute_video_workflow() raises:
    var graph = Graph()
    var load = graph.add_node(String("core/load_video"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("video"), NVT_VIDEO))
    graph.nodes[0].set_field(String("path"), FieldValue.string(String("/tmp/input.mp4")))

    var preview = graph.add_node(String("core/preview_video"), Vec2(240.0, 0.0))
    graph.nodes[1].add_input(PortRef(String("video"), NVT_VIDEO))
    var save = graph.add_node(String("core/save_video"), Vec2(480.0, 0.0))
    graph.nodes[2].add_input(PortRef(String("video"), NVT_VIDEO))
    graph.nodes[2].set_field(String("path"), FieldValue.string(String("/tmp/out.mp4")))

    _ = graph.add_edge(load, String("video"), preview, String("video"))
    _ = graph.add_edge(load, String("video"), save, String("video"))

    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)

    _expect(result.success, "video workflow should succeed")
    var value = result.find_value(load, String("video"))
    _expect(value.kind == WV_VIDEO, "load_video should produce video value")
    _expect(value.path == String("/tmp/input.mp4"), "load_video path should propagate")
    _expect(len(result.artifacts) == 2, "preview and save should add two video artifacts")
    _expect(result.artifacts[0].kind == String("video_preview"), "preview artifact should be video_preview")
    _expect(result.artifacts[1].kind == String("video"), "save artifact should be video")
    print("PASS: execute video workflow")


def test_execute_comfy_sampler_workflow() raises:
    var graph = Graph()
    var ckpt = graph.add_node(String("comfy/CheckpointLoaderSimple"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("MODEL"), NVT_MODEL))
    graph.nodes[0].add_output(PortRef(String("CLIP"), NVT_CLIP))
    graph.nodes[0].add_output(PortRef(String("VAE"), NVT_VAE))
    graph.nodes[0].set_field(String("ckpt_name"), FieldValue.string(String("serenity.safetensors")))

    var positive = graph.add_node(String("comfy/CLIPTextEncode"), Vec2(260.0, -120.0))
    graph.nodes[1].add_input(PortRef(String("clip"), NVT_CLIP))
    graph.nodes[1].add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    graph.nodes[1].set_field(String("text"), FieldValue.string(String("polished cinematic robot")))

    var negative = graph.add_node(String("comfy/CLIPTextEncode"), Vec2(260.0, 120.0))
    graph.nodes[2].add_input(PortRef(String("clip"), NVT_CLIP))
    graph.nodes[2].add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    graph.nodes[2].set_field(String("text"), FieldValue.string(String("blur low detail")))

    var latent = graph.add_node(String("comfy/EmptyLatentImage"), Vec2(260.0, 300.0))
    graph.nodes[3].add_output(PortRef(String("LATENT"), NVT_LATENT))
    graph.nodes[3].set_field(String("width"), FieldValue.int_(Int64(768)))
    graph.nodes[3].set_field(String("height"), FieldValue.int_(Int64(512)))
    graph.nodes[3].set_field(String("batch_size"), FieldValue.int_(Int64(1)))

    var sampler = graph.add_node(String("comfy/KSampler"), Vec2(560.0, 0.0))
    graph.nodes[4].add_input(PortRef(String("model"), NVT_MODEL))
    graph.nodes[4].add_input(PortRef(String("positive"), NVT_CONDITIONING))
    graph.nodes[4].add_input(PortRef(String("negative"), NVT_CONDITIONING))
    graph.nodes[4].add_input(PortRef(String("latent_image"), NVT_LATENT))
    graph.nodes[4].add_output(PortRef(String("LATENT"), NVT_LATENT))
    graph.nodes[4].set_field(String("seed"), FieldValue.int_(Int64(42)))
    graph.nodes[4].set_field(String("steps"), FieldValue.int_(Int64(8)))
    graph.nodes[4].set_field(String("cfg"), FieldValue.number(7.0))
    graph.nodes[4].set_field(String("sampler_name"), FieldValue.string(String("euler")))
    graph.nodes[4].set_field(String("scheduler"), FieldValue.string(String("normal")))
    graph.nodes[4].set_field(String("denoise"), FieldValue.number(1.0))

    var decode = graph.add_node(String("comfy/VAEDecode"), Vec2(860.0, 0.0))
    graph.nodes[5].add_input(PortRef(String("samples"), NVT_LATENT))
    graph.nodes[5].add_input(PortRef(String("vae"), NVT_VAE))
    graph.nodes[5].add_output(PortRef(String("IMAGE"), NVT_IMAGE))

    var save = graph.add_node(String("comfy/SaveImage"), Vec2(1100.0, 0.0))
    graph.nodes[6].add_input(PortRef(String("images"), NVT_IMAGE))
    graph.nodes[6].set_field(String("filename_prefix"), FieldValue.string(String("SerenityUI")))

    _ = graph.add_edge(ckpt, String("MODEL"), sampler, String("model"))
    _ = graph.add_edge(ckpt, String("CLIP"), positive, String("clip"))
    _ = graph.add_edge(ckpt, String("CLIP"), negative, String("clip"))
    _ = graph.add_edge(ckpt, String("VAE"), decode, String("vae"))
    _ = graph.add_edge(positive, String("CONDITIONING"), sampler, String("positive"))
    _ = graph.add_edge(negative, String("CONDITIONING"), sampler, String("negative"))
    _ = graph.add_edge(latent, String("LATENT"), sampler, String("latent_image"))
    _ = graph.add_edge(sampler, String("LATENT"), decode, String("samples"))
    _ = graph.add_edge(decode, String("IMAGE"), save, String("images"))

    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)
    _expect(result.success, "Comfy sampler workflow should succeed")
    _expect(result.plan.step_count() == 7, "Comfy sampler workflow should have 7 steps")
    _expect(result.find_value(ckpt, String("MODEL")).kind == WV_MODEL, "checkpoint should produce model")
    _expect(result.find_value(ckpt, String("CLIP")).kind == WV_CLIP, "checkpoint should produce clip")
    _expect(result.find_value(ckpt, String("VAE")).kind == WV_VAE, "checkpoint should produce vae")
    _expect(result.find_value(positive, String("CONDITIONING")).kind == WV_CONDITIONING, "positive encode should produce conditioning")
    var sampled = result.find_value(sampler, String("LATENT"))
    _expect(sampled.kind == WV_LATENT, "KSampler should produce latent")
    _expect(sampled.width == Int32(768) and sampled.height == Int32(512), "sampled latent should preserve dimensions")
    _expect(sampled.seed == Int64(42), "sampled latent should carry seed")
    _expect(result.find_value(decode, String("IMAGE")).kind == WV_IMAGE, "VAE decode should produce image")
    _expect(result.launch_count() == 1, "sampler should stage one GPU launch")
    _expect(result.launches[0].backend == String("sampler"), "launch backend should be sampler")
    _expect(_contains(result.launches[0].command, String("--sampler euler")), "sampler command should include euler")
    _expect(_contains(result.launches[0].command, String("--scheduler normal")), "sampler command should include scheduler")
    _expect(len(result.artifacts) == 1, "SaveImage should add one artifact")
    _expect(result.artifacts[0].kind == String("image"), "SaveImage artifact should be image")
    print("PASS: execute Comfy sampler workflow")


def test_execute_comfy_utility_nodes() raises:
    var graph = Graph()
    var load = graph.add_node(String("comfy/LoadImage"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    graph.nodes[0].set_field(String("image"), FieldValue.string(String("/tmp/control.png")))

    var scale = graph.add_node(String("comfy/ImageScale"), Vec2(260.0, 0.0))
    graph.nodes[1].add_input(PortRef(String("image"), NVT_IMAGE))
    graph.nodes[1].add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    graph.nodes[1].set_field(String("width"), FieldValue.int_(Int64(640)))
    graph.nodes[1].set_field(String("height"), FieldValue.int_(Int64(480)))

    var encode = graph.add_node(String("comfy/CLIPTextEncode"), Vec2(260.0, 180.0))
    graph.nodes[2].add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    graph.nodes[2].set_field(String("text"), FieldValue.string(String("sharp studio lighting")))

    var control = graph.add_node(String("comfy/ControlNetLoader"), Vec2(520.0, 0.0))
    graph.nodes[3].add_output(PortRef(String("CONTROL_NET"), NVT_MODEL))
    graph.nodes[3].set_field(String("control_net_name"), FieldValue.string(String("canny.safetensors")))

    var apply = graph.add_node(String("comfy/ControlNetApply"), Vec2(780.0, 0.0))
    graph.nodes[4].add_input(PortRef(String("conditioning"), NVT_CONDITIONING))
    graph.nodes[4].add_input(PortRef(String("control_net"), NVT_MODEL))
    graph.nodes[4].add_input(PortRef(String("image"), NVT_IMAGE))
    graph.nodes[4].add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    graph.nodes[4].set_field(String("strength"), FieldValue.number(0.75))

    var resolution = graph.add_node(String("comfy/ResolutionSelector"), Vec2(0.0, 260.0))
    graph.nodes[5].add_output(PortRef(String("width"), NVT_NUMBER))
    graph.nodes[5].add_output(PortRef(String("height"), NVT_NUMBER))
    graph.nodes[5].set_field(String("aspect_ratio"), FieldValue.string(String("16:9")))
    graph.nodes[5].set_field(String("megapixels"), FieldValue.number(1.0))

    var config = graph.add_node(String("rgthree/KSamplerConfig"), Vec2(300.0, 300.0))
    graph.nodes[6].add_output(PortRef(String("STEPS"), NVT_NUMBER))
    graph.nodes[6].add_output(PortRef(String("REFINER_STEP"), NVT_NUMBER))
    graph.nodes[6].add_output(PortRef(String("CFG"), NVT_NUMBER))
    graph.nodes[6].add_output(PortRef(String("SAMPLER"), NVT_TEXT))
    graph.nodes[6].add_output(PortRef(String("SCHEDULER"), NVT_TEXT))
    graph.nodes[6].set_field(String("steps_total"), FieldValue.int_(Int64(24)))
    graph.nodes[6].set_field(String("cfg"), FieldValue.number(6.5))
    graph.nodes[6].set_field(String("sampler_name"), FieldValue.string(String("ddim")))

    var preview = graph.add_node(String("comfy/PreviewAny"), Vec2(620.0, 300.0))
    graph.nodes[7].add_input(PortRef(String("source"), NVT_TEXT))
    graph.nodes[7].add_output(PortRef(String("STRING"), NVT_TEXT))

    _ = graph.add_edge(load, String("IMAGE"), scale, String("image"))
    _ = graph.add_edge(scale, String("IMAGE"), apply, String("image"))
    _ = graph.add_edge(encode, String("CONDITIONING"), apply, String("conditioning"))
    _ = graph.add_edge(control, String("CONTROL_NET"), apply, String("control_net"))
    _ = graph.add_edge(config, String("SAMPLER"), preview, String("source"))

    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)
    _expect(result.success, "Comfy utility workflow should succeed")
    var scaled = result.find_value(scale, String("IMAGE"))
    _expect(scaled.kind == WV_IMAGE, "ImageScale should produce image")
    _expect(scaled.width == Int32(640) and scaled.height == Int32(480), "ImageScale should set dimensions")
    _expect(result.find_value(control, String("CONTROL_NET")).kind == WV_MODEL, "ControlNetLoader should produce model handle")
    _expect(result.find_value(apply, String("CONDITIONING")).kind == WV_CONDITIONING, "ControlNetApply should produce conditioning")
    _expect(result.find_value(resolution, String("width")).kind == WV_NUMBER, "ResolutionSelector should produce width")
    _expect(result.find_value(config, String("CFG")).text == String("6.5"), "KSamplerConfig should produce CFG")
    _expect(result.find_value(preview, String("STRING")).text == String("ddim"), "PreviewAny should pass text through")
    print("PASS: execute Comfy utility nodes")


def test_skipped_node_stays_in_plan() raises:
    var graph = Graph()
    _ = graph.add_node(String("core/load_image"), Vec2.zero())
    graph.nodes[0].muted = True
    var canvas = CanvasState()
    var result = execute_workflow(graph, canvas)
    _expect(result.success, "muted-only workflow should not fail")
    _expect(result.plan.step_count() == 1, "muted node should stay in plan")
    _expect(result.plan.steps[0].status == EXEC_SKIPPED, "muted node should be skipped")
    _expect(len(result.values) == 0, "muted node should not produce values")
    print("PASS: skipped node stays in plan")


def test_rejects_cpu_device_when_gpu_required() raises:
    var graph = Graph()
    _ = graph.add_node(String("core/ideogram4_generate"), Vec2.zero())
    graph.nodes[0].add_output(PortRef(String("image"), NVT_IMAGE))
    var canvas = CanvasState()
    var device = WorkflowDeviceConfig()
    device.device_kind = String("cpu")
    var result = execute_workflow_with_device(graph, canvas, device)
    _expect(not result.success, "GPU-required executor should reject CPU config")
    _expect(result.launch_count() == 0, "CPU-rejected workflow should not stage launches")
    print("PASS: rejects CPU device")


def test_cycle_raises() raises:
    var graph = Graph()
    var a = graph.add_node(String("a"), Vec2.zero())
    var b = graph.add_node(String("b"), Vec2.zero())
    _ = graph.add_edge(a, String("out"), b, String("in"))
    _ = graph.add_edge(b, String("out"), a, String("in"))
    var canvas = CanvasState()

    var raised = False
    try:
        var result = execute_workflow(graph, canvas)
        if result.success:
            raised = False
    except e:
        raised = True
    _expect(raised, "cycle should raise through executor")
    print("PASS: cycle raises")


def main() raises:
    test_execute_ideogram_workflow()
    test_execute_serenity_prompt_builder_workflow()
    test_execute_video_workflow()
    test_execute_comfy_sampler_workflow()
    test_execute_comfy_utility_nodes()
    test_skipped_node_stays_in_plan()
    test_rejects_cpu_device_when_gpu_required()
    test_cycle_raises()
    print("PASS: all 8 workflow-executor tests")
