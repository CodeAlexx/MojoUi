"""Graph-backed inference bridge for Serenity-style UI apps.

This module turns an `InferenceState` snapshot into a Comfy-shaped MojoUI
workflow, executes that workflow through the pure Mojo graph executor, then
optionally launches the existing Klein 9B Mojo sampler process. It is blocking
for now: works first, then we can move the system launch into a nonblocking
job runner.
"""

from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.builtin.type_aliases import MutExternalOrigin

from mojoui.core.id import RetainedId
from mojoui.core.types import Vec2
from mojoui.nodes.canvas_model import CanvasState
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import FieldValue, Node, PortRef
from mojoui.nodes.port import (
    NVT_CLIP,
    NVT_CONDITIONING,
    NVT_IMAGE,
    NVT_LATENT,
    NVT_MODEL,
    NVT_VAE,
)
from mojoui.app.inference_model import (
    HistoryItem,
    InferenceState,
    QueueJob,
    _color_seed_for,
)
from mojoui.app.workflow_executor import execute_workflow_with_device
from mojoui.app.workflow_types import WorkflowDeviceConfig


comptime BytePtr = UnsafePointer[UInt8, MutExternalOrigin]
comptime O_RDONLY: Int32 = 0
comptime O_WRONLY: Int32 = 1
comptime O_CREAT: Int32 = 0x40
comptime O_TRUNC: Int32 = 0x200

comptime KLEIN_ROOT = "/home/alex/mojodiffusion"
comptime KLEIN_OUT_DIR = "/home/alex/mojodiffusion/output/serenityui"
comptime KLEIN_REQ_DIR = "/home/alex/mojodiffusion/output/serenityui/requests"
comptime KLEIN_CAP_DIR = "/home/alex/mojodiffusion/output/serenityui/caps"
comptime KLEIN_BIN_DIR = "/home/alex/mojodiffusion/output/bin"


struct GraphUiRuntime(Movable):
    """Live-only graph inference runtime shared by app frontends."""

    var result_path: String
    var result_pixels: List[UInt8]
    var result_width: Int
    var result_height: Int
    var result_job_id: UInt64
    var uploaded_job_id: UInt64
    var texture_id: UInt32
    var last_status: String
    var last_error: String
    var last_command: String
    var last_prompt_json: String
    var last_log_path: String

    def __init__(out self):
        self.result_path = String("")
        self.result_pixels = List[UInt8]()
        self.result_width = 0
        self.result_height = 0
        self.result_job_id = UInt64(0)
        self.uploaded_job_id = UInt64(0)
        self.texture_id = UInt32(0)
        self.last_status = String("ready")
        self.last_error = String("")
        self.last_command = String("")
        self.last_prompt_json = String("")
        self.last_log_path = String("")


struct GraphBackendRun(Movable):
    var ok: Bool
    var output_path: String
    var prompt_json: String
    var log_path: String
    var command: String
    var width: Int
    var height: Int
    var error: String

    def __init__(
        out self,
        ok: Bool,
        output_path: String,
        prompt_json: String,
        log_path: String,
        command: String,
        width: Int,
        height: Int,
        error: String,
    ):
        self.ok = ok
        self.output_path = output_path.copy()
        self.prompt_json = prompt_json.copy()
        self.log_path = log_path.copy()
        self.command = command.copy()
        self.width = width
        self.height = height
        self.error = error.copy()

    @staticmethod
    def failure(msg: String) -> GraphBackendRun:
        return GraphBackendRun(
            False,
            String(""),
            String(""),
            String(""),
            String(""),
            0,
            0,
            msg,
        )


def _sys_open(path: String, flags: Int32, mode: Int32 = 0) -> Int:
    var n = path.byte_length()
    var buf = alloc[UInt8](n + 1)
    var src = path.as_bytes()
    for i in range(n):
        buf[i] = src[i]
    buf[n] = 0
    var cstr = BytePtr(unsafe_from_address=Int(buf))
    var fd = Int(external_call["open", Int32](cstr, flags, mode))
    buf.free()
    return fd


def _sys_close(fd: Int) -> Int:
    return Int(external_call["close", Int32](Int32(fd)))


def _sys_pwrite(fd: Int, buf: BytePtr, count: Int, offset: Int) -> Int:
    return external_call["pwrite", Int](Int32(fd), buf, count, offset)


def _sys_system(command: String) -> Int:
    var n = command.byte_length()
    var buf = alloc[UInt8](n + 1)
    var src = command.as_bytes()
    for i in range(n):
        buf[i] = src[i]
    buf[n] = 0
    var cstr = BytePtr(unsafe_from_address=Int(buf))
    var status = Int(external_call["system", Int32](cstr))
    buf.free()
    return status


def _path_exists(path: String) -> Bool:
    if path.byte_length() == 0:
        return False
    var fd = _sys_open(path, O_RDONLY, Int32(0))
    if fd < 0:
        return False
    _ = _sys_close(fd)
    return True


def _write_text_file(path: String, text: String) raises:
    var fd = _sys_open(path, O_WRONLY | O_CREAT | O_TRUNC, Int32(0o644))
    if fd < 0:
        raise Error(String("open failed: ") + path)
    var n = text.byte_length()
    var buf = alloc[UInt8](n)
    var src = text.as_bytes()
    for i in range(n):
        buf[i] = src[i]
    var wrote = _sys_pwrite(fd, BytePtr(unsafe_from_address=Int(buf)), n, 0)
    buf.free()
    _ = _sys_close(fd)
    if wrote != n:
        raise Error(String("write failed: ") + path)


def _json_escape(text: String) -> String:
    var out = String("")
    for ch in text.codepoint_slices():
        var s = String(ch)
        if s == String("\""):
            out += String("\\\"")
        elif s == String("\\"):
            out += String("\\\\")
        elif s == String("\n"):
            out += String("\\n")
        elif s == String("\r"):
            out += String("\\r")
        elif s == String("\t"):
            out += String("\\t")
        else:
            out += s
    return out^


def _steps_from_state(state: InferenceState) -> Int32:
    var steps_i = Int32(Int(state.steps))
    if steps_i < Int32(1):
        steps_i = Int32(1)
    return steps_i


def _resolved_seed(state: InferenceState) -> Int64:
    var seed = Int64(Int(state.seed))
    if seed >= Int64(0):
        return seed
    return Int64(Int(state.next_job_id) * 9973 + 42)


def _square_klein_size(width: Int32, height: Int32) -> Int:
    if width >= Int32(900) and height >= Int32(900):
        return 1024
    return 512


def _snapshot_display_job(state: InferenceState) -> QueueJob:
    var seed_i64 = _resolved_seed(state)
    var steps_i = _steps_from_state(state)
    return QueueJob(
        state.next_job_id,
        state.prompt.copy(),
        Int32(Int(state.width)),
        Int32(Int(state.height)),
        steps_i,
        state.sampler_label(),
        seed_i64,
        _color_seed_for(state.prompt, seed_i64, state.next_job_id),
    )


def _set_string(mut node: Node, key: String, value: String):
    node.set_field(key, FieldValue.string(value))


def _set_int(mut node: Node, key: String, value: Int64):
    node.set_field(key, FieldValue.int_(value))


def _set_number(mut node: Node, key: String, value: Float64):
    node.set_field(key, FieldValue.number(value))


def _node_mut_index(graph: Graph, id: RetainedId) raises -> Int:
    var idx = graph.find_node(id)
    if idx < 0:
        raise Error("internal graph build failed")
    return idx


def _add_checkpoint(mut graph: Graph, model_name: String) raises -> RetainedId:
    var id = graph.add_node(String("CheckpointLoaderSimple"), Vec2(40.0, 110.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("Load Klein 9B Checkpoint"))
    graph.nodes[idx].with_size(Vec2(270.0, 105.0))
    graph.nodes[idx].add_output(PortRef(String("MODEL"), NVT_MODEL))
    graph.nodes[idx].add_output(PortRef(String("CLIP"), NVT_CLIP))
    graph.nodes[idx].add_output(PortRef(String("VAE"), NVT_VAE))
    _set_string(graph.nodes[idx], String("ckpt_name"), model_name)
    return id


def _add_clip_encode(
    mut graph: Graph,
    title: String,
    text: String,
    pos: Vec2,
) raises -> RetainedId:
    var id = graph.add_node(String("CLIPTextEncode"), pos)
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(title)
    graph.nodes[idx].with_size(Vec2(320.0, 120.0))
    graph.nodes[idx].add_input(PortRef(String("clip"), NVT_CLIP))
    graph.nodes[idx].add_output(PortRef(String("CONDITIONING"), NVT_CONDITIONING))
    _set_string(graph.nodes[idx], String("text"), text)
    return id


def _add_empty_latent(
    mut graph: Graph,
    width: Int32,
    height: Int32,
    batch: Int32,
) raises -> RetainedId:
    var id = graph.add_node(String("EmptyLatentImage"), Vec2(420.0, 330.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("Empty Latent Image"))
    graph.nodes[idx].with_size(Vec2(250.0, 105.0))
    graph.nodes[idx].add_output(PortRef(String("LATENT"), NVT_LATENT))
    _set_int(graph.nodes[idx], String("width"), Int64(width))
    _set_int(graph.nodes[idx], String("height"), Int64(height))
    _set_int(graph.nodes[idx], String("batch_size"), Int64(batch))
    return id


def _add_sampler(
    mut graph: Graph,
    seed: Int64,
    steps: Int32,
    cfg: Float64,
    sampler: String,
    scheduler: String,
) raises -> RetainedId:
    var id = graph.add_node(String("KSampler"), Vec2(780.0, 210.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("K-Sampler"))
    graph.nodes[idx].with_size(Vec2(285.0, 170.0))
    graph.nodes[idx].add_input(PortRef(String("model"), NVT_MODEL))
    graph.nodes[idx].add_input(PortRef(String("positive"), NVT_CONDITIONING))
    graph.nodes[idx].add_input(PortRef(String("negative"), NVT_CONDITIONING))
    graph.nodes[idx].add_input(PortRef(String("latent_image"), NVT_LATENT))
    graph.nodes[idx].add_output(PortRef(String("LATENT"), NVT_LATENT))
    _set_int(graph.nodes[idx], String("seed"), seed)
    _set_int(graph.nodes[idx], String("steps"), Int64(steps))
    _set_number(graph.nodes[idx], String("cfg"), cfg)
    _set_string(graph.nodes[idx], String("sampler_name"), sampler)
    _set_string(graph.nodes[idx], String("scheduler"), scheduler)
    _set_number(graph.nodes[idx], String("denoise"), 1.0)
    return id


def _add_vae_decode(mut graph: Graph, output_path: String) raises -> RetainedId:
    var id = graph.add_node(String("VAEDecode"), Vec2(1120.0, 245.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("VAE Decode"))
    graph.nodes[idx].with_size(Vec2(245.0, 105.0))
    graph.nodes[idx].add_input(PortRef(String("samples"), NVT_LATENT))
    graph.nodes[idx].add_input(PortRef(String("vae"), NVT_VAE))
    graph.nodes[idx].add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    _set_string(graph.nodes[idx], String("output_path"), output_path)
    return id


def _add_save_image(mut graph: Graph, output_path: String) raises -> RetainedId:
    var id = graph.add_node(String("SaveImage"), Vec2(1460.0, 250.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("Save / Preview Image"))
    graph.nodes[idx].with_size(Vec2(270.0, 95.0))
    graph.nodes[idx].add_input(PortRef(String("images"), NVT_IMAGE))
    _set_string(graph.nodes[idx], String("output_path"), output_path)
    return id


def build_klein9b_inference_graph(
    state: InferenceState,
    display: QueueJob,
    output_path: String,
    width: Int32,
    height: Int32,
) raises -> Graph:
    """Build the Comfy-shaped graph used by SerenityUI Generate."""
    var graph = Graph()
    var ckpt = _add_checkpoint(graph, String("Klein 9B"))
    var pos = _add_clip_encode(
        graph,
        String("Positive Prompt"),
        display.prompt.copy(),
        Vec2(420.0, 80.0),
    )
    var neg = _add_clip_encode(
        graph,
        String("Negative Prompt"),
        state.negative.copy(),
        Vec2(420.0, 200.0),
    )
    var latent = _add_empty_latent(
        graph,
        width,
        height,
        Int32(Int(state.batch_size)),
    )
    var sampler = _add_sampler(
        graph,
        display.seed,
        display.steps,
        Float64(state.cfg),
        display.sampler.copy(),
        state.scheduler_options[Int(state.scheduler_index)].copy(),
    )
    var decode = _add_vae_decode(graph, output_path)
    var save = _add_save_image(graph, output_path)

    _ = graph.add_edge(ckpt, String("CLIP"), pos, String("clip"))
    _ = graph.add_edge(ckpt, String("CLIP"), neg, String("clip"))
    _ = graph.add_edge(ckpt, String("MODEL"), sampler, String("model"))
    _ = graph.add_edge(pos, String("CONDITIONING"), sampler, String("positive"))
    _ = graph.add_edge(neg, String("CONDITIONING"), sampler, String("negative"))
    _ = graph.add_edge(latent, String("LATENT"), sampler, String("latent_image"))
    _ = graph.add_edge(sampler, String("LATENT"), decode, String("samples"))
    _ = graph.add_edge(ckpt, String("VAE"), decode, String("vae"))
    _ = graph.add_edge(decode, String("IMAGE"), save, String("images"))
    return graph^


def _sample_prompt_json(
    prompt: String,
    negative: String,
    width: Int,
    height: Int,
    steps: Int32,
    cfg: Float32,
    seed: Int64,
    caps_pos: String,
    caps_neg: String,
) -> String:
    var p = _json_escape(prompt)
    var n = _json_escape(negative)
    return (
        String("{\n")
        + String("  \"schema\": \"serenity.sample_prompts.v1\",\n")
        + String("  \"defaults\": {\n")
        + String("    \"sample_every\": 1,\n")
        + String("    \"sample_at_start\": true,\n")
        + String("    \"save_before_sample\": false,\n")
        + String("    \"precache_required\": true,\n")
        + String("    \"enforce_min_image_size\": false,\n")
        + String("    \"width\": ") + String(width) + String(",\n")
        + String("    \"height\": ") + String(height) + String(",\n")
        + String("    \"frames\": 1,\n")
        + String("    \"fps\": 24,\n")
        + String("    \"steps\": ") + String(steps) + String(",\n")
        + String("    \"cfg\": ") + String(cfg) + String(",\n")
        + String("    \"seed\": ") + String(seed) + String(",\n")
        + String("    \"negative\": \"") + n + String("\"\n")
        + String("  },\n")
        + String("  \"prompts\": [\n")
        + String("    {\n")
        + String("      \"id\": \"serenityui\",\n")
        + String("      \"prompt\": \"") + p + String("\",\n")
        + String("      \"negative\": \"") + n + String("\",\n")
        + String("      \"width\": ") + String(width) + String(",\n")
        + String("      \"height\": ") + String(height) + String(",\n")
        + String("      \"steps\": ") + String(steps) + String(",\n")
        + String("      \"cfg\": ") + String(cfg) + String(",\n")
        + String("      \"seed\": ") + String(seed) + String(",\n")
        + String("      \"caps\": {\n")
        + String("        \"positive\": \"") + caps_pos + String("\",\n")
        + String("        \"negative\": \"") + caps_neg + String("\"\n")
        + String("      }\n")
        + String("    }\n")
        + String("  ]\n")
        + String("}\n")
    )


def _run_klein9b_system(
    display: QueueJob,
    negative: String,
    cfg: Float32,
    width: Int,
    height: Int,
) raises -> GraphBackendRun:
    _ = _sys_system(
        String("mkdir -p ")
        + String(KLEIN_OUT_DIR)
        + String(" ")
        + String(KLEIN_REQ_DIR)
        + String(" ")
        + String(KLEIN_CAP_DIR)
        + String(" ")
        + String(KLEIN_BIN_DIR)
    )
    var stem = String("serenityui_klein9b_") + String(display.id)
    var prompt_json = String(KLEIN_REQ_DIR) + String("/") + stem + String(".json")
    var caps_pos = String(KLEIN_CAP_DIR) + String("/") + stem + String("_pos.bin")
    var caps_neg = String(KLEIN_CAP_DIR) + String("/") + stem + String("_neg.bin")
    var out_png = String(KLEIN_OUT_DIR) + String("/") + stem + String(".png")
    var log_path = String(KLEIN_OUT_DIR) + String("/") + stem + String(".log")
    var json = _sample_prompt_json(
        display.prompt,
        negative,
        width,
        height,
        display.steps,
        cfg,
        display.seed,
        caps_pos,
        caps_neg,
    )
    _write_text_file(prompt_json, json)

    var pixi = String("/home/alex/.pixi/bin/pixi")
    var precache_bin = String(KLEIN_BIN_DIR) + String("/klein9b_precache_sample_prompts")
    var sampler_bin = String(KLEIN_BIN_DIR) + String("/klein_sample_cli")
    var cmd = (
        String("cd ")
        + String(KLEIN_ROOT)
        + String(" && (")
        + String("(test -x ")
        + precache_bin
        + String(" || ")
        + pixi
        + String(" run mojo build -I . -Xlinker -lm -Xlinker -lcuda serenitymojo/pipeline/klein9b_precache_sample_prompts.mojo -o ")
        + precache_bin
        + String(") && (test -x ")
        + sampler_bin
        + String(" || ")
        + pixi
        + String(" run mojo build -I . -Xlinker -lm -Xlinker -lcuda serenitymojo/sampling/klein_sample_cli.mojo -o ")
        + sampler_bin
        + String(") && ")
        + precache_bin
        + String(" ")
        + prompt_json
        + String(" && ")
        + sampler_bin
        + String(" serenitymojo/configs/klein9b.json - ")
        + prompt_json
        + String(" serenityui ")
        + out_png
        + String(") > ")
        + log_path
        + String(" 2>&1")
    )
    var rc = _sys_system(cmd)
    if rc != 0:
        return GraphBackendRun(
            False,
            out_png,
            prompt_json,
            log_path,
            cmd,
            width,
            height,
            String("Klein 9B command failed with status ")
            + String(rc)
            + String("; see ")
            + log_path,
        )
    if not _path_exists(out_png):
        return GraphBackendRun(
            False,
            out_png,
            prompt_json,
            log_path,
            cmd,
            width,
            height,
            String("Klein 9B finished but did not write ")
            + out_png
            + String("; see ")
            + log_path,
        )
    return GraphBackendRun(True, out_png, prompt_json, log_path, cmd, width, height, String(""))


def run_klein9b_graph_once(state: InferenceState, display: QueueJob) raises -> GraphBackendRun:
    var size = _square_klein_size(display.width, display.height)
    var out_png = (
        String(KLEIN_OUT_DIR)
        + String("/serenityui_klein9b_")
        + String(display.id)
        + String(".png")
    )
    var graph = build_klein9b_inference_graph(
        state,
        display,
        out_png,
        Int32(size),
        Int32(size),
    )
    var canvas = CanvasState()
    var device = WorkflowDeviceConfig()
    device.dry_run = False
    var exec_result = execute_workflow_with_device(graph, canvas, device)
    if not exec_result.success:
        return GraphBackendRun.failure(String("workflow executor failed before backend launch"))
    return _run_klein9b_system(display, state.negative, state.cfg, size, size)


def dry_run_klein9b_graph(state: InferenceState) raises -> Bool:
    """Compile and execute the Klein graph without launching the sampler."""
    var display = _snapshot_display_job(state)
    var size = _square_klein_size(display.width, display.height)
    var graph = build_klein9b_inference_graph(
        state,
        display,
        String("/tmp/serenityui_klein9b_dry.png"),
        Int32(size),
        Int32(size),
    )
    var canvas = CanvasState()
    var device = WorkflowDeviceConfig()
    device.dry_run = True
    var result = execute_workflow_with_device(graph, canvas, device)
    return result.success and result.plan.step_count() == 7 and result.launch_count() >= 1


def _start_display_job(mut state: InferenceState, display: QueueJob):
    state.running = display.copy()
    state.running.current_step = 0
    state.has_running = True
    state.generating = True
    state.current_step = 0
    state.total_steps = display.steps
    state.frame_counter = 0
    state.result_ready = False
    state.perf.gpu_util_pct = 82.0


def _finish_success(mut state: InferenceState, mut rt: GraphUiRuntime, run: GraphBackendRun):
    rt.result_path = run.output_path.copy()
    rt.result_pixels = List[UInt8]()
    rt.result_width = run.width
    rt.result_height = run.height
    rt.result_job_id = state.running.id
    rt.last_status = String("done")
    rt.last_error = String("")
    rt.last_command = run.command.copy()
    rt.last_prompt_json = run.prompt_json.copy()
    rt.last_log_path = run.log_path.copy()

    var item = HistoryItem(
        state.running.id,
        state.running.prompt.copy(),
        state.running.seed,
        state.running.color_seed,
    )
    state.history.append(item^)
    state.has_running = False
    state.generating = False
    state.current_step = state.total_steps
    state.result_ready = True
    state.perf.gpu_util_pct = 0.0


def _finish_failed(mut state: InferenceState, mut rt: GraphUiRuntime, msg: String):
    rt.last_status = String("failed")
    rt.last_error = msg.copy()
    state.has_running = False
    state.generating = False
    state.current_step = 0
    state.total_steps = 0
    state.frame_counter = 0
    state.perf.gpu_util_pct = 0.0
    print("[graph-inference] failed:", msg)


def graph_submit_current(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Run the current UI params through the graph executor and Klein 9B."""
    var display = _snapshot_display_job(state)
    state.next_job_id = state.next_job_id + 1
    _start_display_job(state, display)
    rt.last_status = String("running Klein 9B graph")
    rt.last_error = String("")
    try:
        var run = run_klein9b_graph_once(state, state.running)
        if run.ok:
            _finish_success(state, rt, run^)
        else:
            _finish_failed(state, rt, run.error)
    except e:
        _finish_failed(state, rt, String(e))


def graph_cancel_all(mut state: InferenceState, mut rt: GraphUiRuntime):
    rt.last_status = String("cancelled")
    state.queued = List[QueueJob]()
    state.has_running = False
    state.generating = False
    state.current_step = 0
    state.total_steps = 0
    state.frame_counter = 0
    state.perf.gpu_util_pct = 0.0


def graph_tick_and_apply(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Reserved for the nonblocking graph runner. Blocking mode has no tick."""
    pass


def graph_progress_fraction(state: InferenceState) -> Float32:
    if state.total_steps <= 0:
        return 0.0
    var f = Float32(Int(state.current_step)) / Float32(Int(state.total_steps))
    if f > 1.0:
        return 1.0
    return f


def graph_backend_label(rt: GraphUiRuntime) -> String:
    if rt.last_error.byte_length() > 0:
        return String("graph executor  ·  Klein 9B  ·  ") + rt.last_status + String("  ·  ") + rt.last_error
    return String("graph executor  ·  Klein 9B  ·  ") + rt.last_status
