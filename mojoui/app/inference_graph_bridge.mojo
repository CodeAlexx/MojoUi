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
from mojoui.app.daemon_client import (
    DaemonJobInfo,
    daemon_cancel,
    daemon_generate,
    daemon_health,
    daemon_jobs,
)
from mojoui.app.gen_history import absolutize_output_path
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

    # ── daemon bridge state (DAEMON_BRIDGE_SPEC.md / P11+P12) ──
    var daemon_ok: Bool                       # last health verdict
    var daemon_backend: String                # "stub" | "zimage" | ...
    var daemon_resident: String               # resident checkpoint ("" = none)
    var daemon_submitted: List[String]        # this UI's in-flight job ids
    var daemon_jobs_cache: List[DaemonJobInfo]  # last /v1/jobs (queue rail)
    var daemon_done_events: List[DaemonJobInfo] # terminal jobs, drained by screen
    var daemon_poll_tick: Int
    var daemon_health_tick: Int
    var daemon_fail_streak: Int               # consecutive failed polls
    var last_submit_json: String              # G2f audit: exact POSTed genparams
    var submit_width: Int                     # dims of the in-flight daemon job
    var submit_height: Int
    var route_label: String                   # "daemon" | "cli" | reason text

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
        self.daemon_ok = False
        self.daemon_backend = String("")
        self.daemon_resident = String("")
        self.daemon_submitted = List[String]()
        self.daemon_jobs_cache = List[DaemonJobInfo]()
        self.daemon_done_events = List[DaemonJobInfo]()
        self.daemon_poll_tick = 0
        self.daemon_health_tick = 0
        self.daemon_fail_streak = 0
        self.last_submit_json = String("")
        self.submit_width = 0
        self.submit_height = 0
        self.route_label = String("")


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
    graph.nodes[idx].with_size(Vec2(380.0, 150.0))
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
    graph.nodes[idx].with_size(Vec2(460.0, 170.0))
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
    var id = graph.add_node(String("EmptyLatentImage"), Vec2(520.0, 465.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("Empty Latent Image"))
    graph.nodes[idx].with_size(Vec2(360.0, 145.0))
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
    var id = graph.add_node(String("KSampler"), Vec2(1080.0, 220.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("K-Sampler"))
    graph.nodes[idx].with_size(Vec2(430.0, 260.0))
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
    var id = graph.add_node(String("VAEDecode"), Vec2(1585.0, 515.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("VAE Decode"))
    graph.nodes[idx].with_size(Vec2(360.0, 145.0))
    graph.nodes[idx].add_input(PortRef(String("samples"), NVT_LATENT))
    graph.nodes[idx].add_input(PortRef(String("vae"), NVT_VAE))
    graph.nodes[idx].add_output(PortRef(String("IMAGE"), NVT_IMAGE))
    _set_string(graph.nodes[idx], String("output_path"), output_path)
    return id


def _add_save_image(mut graph: Graph, output_path: String) raises -> RetainedId:
    var id = graph.add_node(String("SaveImage"), Vec2(2045.0, 515.0))
    var idx = _node_mut_index(graph, id)
    graph.nodes[idx].with_title(String("Save / Preview Image"))
    graph.nodes[idx].with_size(Vec2(400.0, 185.0))
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
        Vec2(520.0, 70.0),
    )
    var neg = _add_clip_encode(
        graph,
        String("Negative Prompt"),
        state.negative.copy(),
        Vec2(520.0, 265.0),
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


def graph_has_port_metadata(graph: Graph) -> Bool:
    """True when a loaded workflow carries node socket metadata.

    Older native workflow JSON persisted edges but not node inputs/outputs,
    which made reloads look disconnected because the canvas had no socket
    positions to draw wires from.
    """
    for i in range(graph.node_count()):
        if len(graph.nodes[i].inputs) > 0 or len(graph.nodes[i].outputs) > 0:
            return True
    return False


def merge_saved_node_layout(mut graph: Graph, saved: Graph) -> Int:
    """Merge visual node state from `saved` onto an already-built graph.

    This keeps the fresh graph's ports/edges/executor shape while preserving
    user edits from old portless cache files: position, size, title, and
    fields such as node color overrides.
    """
    var matched = 0
    for si in range(saved.node_count()):
        var idx = graph.find_node(saved.nodes[si].id)
        if idx < 0:
            continue
        graph.nodes[idx].position = saved.nodes[si].position.copy()
        graph.nodes[idx].size = saved.nodes[si].size.copy()
        graph.nodes[idx].title = saved.nodes[si].title.copy()
        graph.nodes[idx].fields = saved.nodes[si].fields.copy()
        graph.nodes[idx].muted = saved.nodes[si].muted
        graph.nodes[idx].bypassed = saved.nodes[si].bypassed
        graph.nodes[idx].collapsed = saved.nodes[si].collapsed
        graph.nodes[idx].pinned = saved.nodes[si].pinned
        matched = matched + 1
    return matched


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
    precache: Bool = True,
) -> String:
    var p = _json_escape(prompt)
    var n = _json_escape(negative)
    var precache_str = String("true")
    if not precache:
        precache_str = String("false")
    return (
        String("{\n")
        + String("  \"schema\": \"serenity.sample_prompts.v1\",\n")
        + String("  \"defaults\": {\n")
        + String("    \"sample_every\": 1,\n")
        + String("    \"sample_at_start\": true,\n")
        + String("    \"save_before_sample\": false,\n")
        + String("    \"precache_required\": ") + precache_str + String(",\n")
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


# ── Multi-model backend registry ───────────────────────────────────────────
# Generalises the Klein-9B shell-out to every model the SerenityUI dropdown
# exposes. Each entry names the Mojo CLI source to build + the invocation
# contract. New image models only need (1) a `<slug>_sample_cli.mojo` adapter
# that reads a `serenity.sample_prompts.v1` JSON and writes a PNG, mirroring
# `klein_sample_cli`, and (2) one entry in `_resolve_model_spec` below.
#
# arg_style:
#   0 = sample_cli  ->  BIN <config.json> <lora|-> <req.json> <id> <out.png>
#   1 = zimage      ->  BIN <lora|base> <out.png> <req.json> <id>

comptime MODEL_OUT_DIR = KLEIN_OUT_DIR
comptime MODEL_REQ_DIR = KLEIN_REQ_DIR
comptime MODEL_CAP_DIR = KLEIN_CAP_DIR
comptime MODEL_BIN_DIR = KLEIN_BIN_DIR
comptime SERENITY_ROOT = KLEIN_ROOT
comptime PIXI_BIN = "/home/alex/.pixi/bin/pixi"


struct ModelBackendSpec(Movable):
    var supported: Bool
    var slug: String
    var arg_style: Int
    var src: String
    var bin: String
    var config: String
    var needs_precache: Bool
    var precache_src: String
    var precache_bin: String
    var unsupported_msg: String

    def __init__(
        out self,
        supported: Bool,
        slug: String,
        arg_style: Int,
        src: String,
        config: String,
        needs_precache: Bool = False,
        precache_src: String = String(""),
        unsupported_msg: String = String(""),
    ):
        self.supported = supported
        self.slug = slug.copy()
        self.arg_style = arg_style
        self.src = src.copy()
        self.bin = String(MODEL_BIN_DIR) + String("/") + slug + String("_serenity_cli")
        self.config = config.copy()
        self.needs_precache = needs_precache
        self.precache_src = precache_src.copy()
        self.precache_bin = String(MODEL_BIN_DIR) + String("/") + slug + String("_precache")
        self.unsupported_msg = unsupported_msg.copy()

    @staticmethod
    def unsupported(slug: String, msg: String) -> ModelBackendSpec:
        return ModelBackendSpec(False, slug, 0, String(""), String(""), False, String(""), msg)


def _resolve_model_spec(name: String) raises -> ModelBackendSpec:
    """Map a SerenityUI dropdown model name to its Mojo inference backend."""
    if name == String("Klein 9B"):
        return ModelBackendSpec(
            True, String("klein9b"), 0,
            String("serenitymojo/sampling/klein_sample_cli.mojo"),
            String("serenitymojo/configs/klein9b.json"),
            True, String("serenitymojo/pipeline/klein9b_precache_sample_prompts.mojo"),
        )
    if name == String("Klein 4B"):
        return ModelBackendSpec(
            True, String("klein4b"), 0,
            String("serenitymojo/sampling/klein_sample_cli.mojo"),
            String("serenitymojo/configs/klein4b.json"),
            True, String("serenitymojo/pipeline/klein9b_precache_sample_prompts.mojo"),
        )
    if name == String("Z-Image (base)"):
        return ModelBackendSpec(
            True, String("zimage_base"), 1,
            String("serenitymojo/pipeline/zimage_generate.mojo"),
            String("serenitymojo/configs/zimage.json"),
        )
    if name == String("Z-Image (turbo)"):
        return ModelBackendSpec(
            True, String("zimage_turbo"), 1,
            String("serenitymojo/pipeline/zimage_generate.mojo"),
            String("serenitymojo/configs/zimage.json"),
        )
    if name == String("Qwen-Image"):
        return ModelBackendSpec(
            True, String("qwenimage"), 0,
            String("serenitymojo/pipeline/qwenimage_sample_cli.mojo"),
            String("serenitymojo/configs/qwenimage.json"),
        )
    if name == String("Chroma"):
        return ModelBackendSpec(
            True, String("chroma"), 0,
            String("serenitymojo/pipeline/chroma_sample_cli.mojo"),
            String("serenitymojo/configs/chroma.json"),
        )
    if name == String("SD 3.5"):
        return ModelBackendSpec(
            True, String("sd35"), 0,
            String("serenitymojo/pipeline/sd3_sample_cli.mojo"),
            String("serenitymojo/configs/sd35.json"),
        )
    if name == String("SDXL"):
        return ModelBackendSpec(
            True, String("sdxl"), 0,
            String("serenitymojo/pipeline/sdxl_sample_cli.mojo"),
            String("serenitymojo/configs/sdxl.json"),
        )
    if name == String("ERNIE"):
        return ModelBackendSpec(
            True, String("ernie"), 0,
            String("serenitymojo/pipeline/ernie_sample_cli.mojo"),
            String("serenitymojo/configs/ernie_image.json"),
            True, String("serenitymojo/pipeline/ernie_precache_sample_prompts.mojo"),
        )
    if name == String("FLUX Dev"):
        return ModelBackendSpec(
            True, String("flux"), 0,
            String("serenitymojo/pipeline/flux_sample_cli.mojo"),
            String("serenitymojo/configs/flux.json"),
        )
    if name == String("Anima"):
        return ModelBackendSpec(
            True, String("anima"), 0,
            String("serenitymojo/pipeline/anima_serenity_cli.mojo"),
            String("serenitymojo/configs/anima.json"),
        )
    if name == String("SD 1.5"):
        return ModelBackendSpec.unsupported(
            String("sd15"),
            String("SD 1.5 has no Mojo generate pipeline in serenitymojo yet"
                   " (only VAE/contract smokes); not wired for inference."),
        )
    return ModelBackendSpec.unsupported(
        String("unknown"),
        String("No serenitymojo backend registered for model '") + name + String("'"),
    )


def _build_clause(bin: String, src: String) -> String:
    """Shell clause: build `bin` from `src` if not already present."""
    return (
        String("(test -x ")
        + bin
        + String(" || ")
        + String(PIXI_BIN)
        + String(" run mojo build -I . -Xlinker -lm -Xlinker -lcuda ")
        + src
        + String(" -o ")
        + bin
        + String(")")
    )


def _run_model_system(
    spec: ModelBackendSpec,
    display: QueueJob,
    negative: String,
    cfg: Float32,
    width: Int,
    height: Int,
) raises -> GraphBackendRun:
    """Generic model runner: write the request JSON, build the model CLI on
    demand, run it, and confirm it produced a PNG. Mirrors the proven
    Klein-9B flow for every registered model."""
    _ = _sys_system(
        String("mkdir -p ")
        + String(MODEL_OUT_DIR) + String(" ")
        + String(MODEL_REQ_DIR) + String(" ")
        + String(MODEL_CAP_DIR) + String(" ")
        + String(MODEL_BIN_DIR)
    )
    var stem = String("serenityui_") + spec.slug + String("_") + String(display.id)
    var req_json = String(MODEL_REQ_DIR) + String("/") + stem + String(".json")
    var caps_pos = String(MODEL_CAP_DIR) + String("/") + stem + String("_pos.bin")
    var caps_neg = String(MODEL_CAP_DIR) + String("/") + stem + String("_neg.bin")
    var out_png = String(MODEL_OUT_DIR) + String("/") + stem + String(".png")
    var log_path = String(MODEL_OUT_DIR) + String("/") + stem + String(".log")
    var json = _sample_prompt_json(
        display.prompt, negative, width, height,
        display.steps, cfg, display.seed, caps_pos, caps_neg,
        spec.needs_precache,
    )
    _write_text_file(req_json, json)

    # Per-model invocation contract.
    var invoke: String
    if spec.arg_style == 1:
        # zimage_generate <lora|base> <out.png> <req.json> <id>
        invoke = spec.bin + String(" base ") + out_png + String(" ") + req_json + String(" serenityui")
    else:
        # sample_cli <config.json> <lora|-> <req.json> <id> <out.png>
        invoke = (
            spec.bin + String(" ") + spec.config + String(" - ")
            + req_json + String(" serenityui ") + out_png
        )

    var build_steps = String("")
    var run_steps = String("")
    if spec.needs_precache:
        build_steps += _build_clause(spec.precache_bin, spec.precache_src) + String(" && ")
        run_steps += spec.precache_bin + String(" ") + req_json + String(" && ")
    build_steps += _build_clause(spec.bin, spec.src)

    var cmd = (
        String("cd ") + String(SERENITY_ROOT) + String(" && (")
        + build_steps + String(" && ") + run_steps + invoke
        + String(") > ") + log_path + String(" 2>&1")
    )
    var rc = _sys_system(cmd)
    if rc != 0:
        return GraphBackendRun(
            False, out_png, req_json, log_path, cmd, width, height,
            spec.slug + String(" command failed with status ") + String(rc)
            + String("; see ") + log_path,
        )
    if not _path_exists(out_png):
        return GraphBackendRun(
            False, out_png, req_json, log_path, cmd, width, height,
            spec.slug + String(" finished but did not write ") + out_png
            + String("; see ") + log_path,
        )
    return GraphBackendRun(True, out_png, req_json, log_path, cmd, width, height, String(""))


def run_klein9b_graph_once(state: InferenceState, display: QueueJob) raises -> GraphBackendRun:
    """Dispatch the current UI model selection to its serenitymojo backend.

    Name kept for source compatibility with existing callers; it now routes by
    the selected model rather than always running Klein 9B."""
    var model_name = String("Klein 9B")
    if state.cli_model_override.byte_length() > 0:
        # the gen screen mapped the daemon-scanned selection to a CLI backend
        model_name = state.cli_model_override.copy()
    else:
        var mi = Int(state.model_index)
        if mi >= 0 and mi < len(state.model_options):
            model_name = state.model_options[mi].copy()
    var spec = _resolve_model_spec(model_name)
    if not spec.supported:
        return GraphBackendRun.failure(spec.unsupported_msg)

    var size = _square_klein_size(display.width, display.height)
    var out_png = (
        String(MODEL_OUT_DIR) + String("/serenityui_") + spec.slug
        + String("_") + String(display.id) + String(".png")
    )
    # Build + dry-validate the Comfy-shaped graph (executor sanity) before the
    # backend launch. Cosmetic for non-Klein models but keeps the UI contract.
    var graph = build_klein9b_inference_graph(state, display, out_png, Int32(size), Int32(size))
    var canvas = CanvasState()
    var device = WorkflowDeviceConfig()
    device.dry_run = False
    var exec_result = execute_workflow_with_device(graph, canvas, device)
    if not exec_result.success:
        return GraphBackendRun.failure(String("workflow executor failed before backend launch"))

    # Klein keeps its proven dedicated runner; everything else uses the generic.
    if spec.slug == String("klein9b"):
        return _run_klein9b_system(display, state.negative, state.cfg, size, size)
    return _run_model_system(spec, display, state.negative, state.cfg, size, size)


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


# ── daemon bridge (DAEMON_BRIDGE_SPEC.md): submit / poll / cancel ───────────
comptime DAEMON_POLL_ACTIVE_FRAMES = 6    # ~10 Hz progress poll while a job runs
comptime DAEMON_POLL_IDLE_FRAMES = 60     # queue-rail freshness when idle
comptime DAEMON_HEALTH_FRAMES = 240       # health re-probe cadence when down


def daemon_refresh_health(mut rt: GraphUiRuntime):
    """GET /v1/health -> rt.daemon_ok/backend/resident. Never raises."""
    var h = daemon_health()
    rt.daemon_ok = h.ok
    rt.daemon_backend = h.backend.copy()
    rt.daemon_resident = h.resident.copy()


def daemon_submit_params(
    mut state: InferenceState, mut rt: GraphUiRuntime,
    genparams_json: String, width: Int, height: Int, steps: Int,
) -> Bool:
    """POST one canonical genparams body to /v1/generate. On success arms the
    nonblocking progress poll; on failure flags the daemon unhealthy so the
    caller falls back to the CLI path."""
    try:
        var job_id = daemon_generate(genparams_json)
        rt.daemon_submitted.append(job_id.copy())
        rt.last_submit_json = genparams_json.copy()
        rt.submit_width = width
        rt.submit_height = height
        rt.route_label = String("daemon")
        rt.last_status = String("daemon ") + job_id
        rt.last_error = String("")
        state.generating = True
        state.has_running = True
        state.current_step = 0
        state.total_steps = Int32(steps)
        state.result_ready = False
        print("[daemon-bridge] submitted", job_id, "->", genparams_json)
        return True
    except e:
        rt.daemon_ok = False
        rt.last_error = String("daemon submit failed: ") + String(e)
        print("[daemon-bridge]", rt.last_error)
        return False


def daemon_cancel_submitted(mut state: InferenceState, mut rt: GraphUiRuntime):
    """POST /v1/cancel/<id> for every in-flight job this UI submitted. The
    poll tick finalizes states (cancelled jobs surface as done_events)."""
    for i in range(len(rt.daemon_submitted)):
        try:
            _ = daemon_cancel(rt.daemon_submitted[i])
            print("[daemon-bridge] cancel requested:", rt.daemon_submitted[i])
        except e:
            print("[daemon-bridge] cancel failed:", String(e))
    rt.last_status = String("cancel requested")


def _daemon_find_job(jobs: List[DaemonJobInfo], id: String) -> Int:
    for i in range(len(jobs)):
        if jobs[i].id == id:
            return i
    return -1


def _daemon_apply_poll(
    mut state: InferenceState, mut rt: GraphUiRuntime, jobs: List[DaemonJobInfo]
):
    """Fold one /v1/jobs snapshot into UI state: progress for the tracked
    jobs, terminal jobs -> done_events (+ preview result on done)."""
    rt.daemon_jobs_cache = jobs.copy()
    var still = List[String]()
    var finished_any = False
    for i in range(len(rt.daemon_submitted)):
        var idx = _daemon_find_job(jobs, rt.daemon_submitted[i])
        if idx < 0:
            still.append(rt.daemon_submitted[i].copy())  # submit/poll race
            continue
        if jobs[idx].is_terminal():
            finished_any = True
            rt.daemon_done_events.append(jobs[idx].copy())
            if jobs[idx].state == "done":
                rt.result_path = absolutize_output_path(jobs[idx].output_path)
                rt.result_pixels = List[UInt8]()
                rt.result_width = rt.submit_width
                rt.result_height = rt.submit_height
                rt.result_job_id += 1
                rt.last_status = jobs[idx].id + String(" done")
                state.result_ready = True
            elif jobs[idx].state == "failed":
                rt.last_status = jobs[idx].id + String(" failed")
                rt.last_error = jobs[idx].error.copy()
            else:
                rt.last_status = jobs[idx].id + String(" ") + jobs[idx].state
        else:
            still.append(rt.daemon_submitted[i].copy())
            if jobs[idx].state == "running":
                state.current_step = Int32(jobs[idx].step)
                if jobs[idx].total > 0:
                    state.total_steps = Int32(jobs[idx].total)
    rt.daemon_submitted = still^
    if len(rt.daemon_submitted) == 0 and finished_any:
        state.generating = False
        state.has_running = False
        state.current_step = state.total_steps
        state.perf.gpu_util_pct = 0.0


comptime DAEMON_FAIL_STREAK_MAX = 20      # tolerated consecutive poll failures
comptime DAEMON_FAIL_BACKOFF_FRAMES = 90  # extra wait after a failed poll


def graph_tick_and_apply(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Per-frame daemon tick: throttled /v1/jobs polling for progress (P11),
    the queue rail (P12), and result application; periodic health re-probe
    when the daemon is down (daemon appears/disappears mid-session).

    Poll failures are TOLERATED up to DAEMON_FAIL_STREAK_MAX in a row: a real
    backend's long single ticks (the zimage ENCODE/DECODE phases run tens of
    seconds inside one event-loop tick) stall HTTP past any sane timeout, and
    one slow tick must not orphan a running GPU job."""
    var active = len(rt.daemon_submitted) > 0
    if not rt.daemon_ok:
        rt.daemon_health_tick += 1
        if rt.daemon_health_tick >= DAEMON_HEALTH_FRAMES:
            rt.daemon_health_tick = 0
            daemon_refresh_health(rt)
        if not rt.daemon_ok:
            if active:
                # daemon vanished mid-job (persistent): report, stop tracking
                rt.last_error = String("daemon lost mid-job")
                rt.daemon_submitted = List[String]()
                state.generating = False
                state.has_running = False
            return
    rt.daemon_poll_tick += 1
    var interval = DAEMON_POLL_ACTIVE_FRAMES if active else DAEMON_POLL_IDLE_FRAMES
    if rt.daemon_poll_tick < interval:
        return
    rt.daemon_poll_tick = 0
    try:
        var jobs = daemon_jobs(timeout_ms=4000)
        _daemon_apply_poll(state, rt, jobs)
        rt.daemon_fail_streak = 0
    except e:
        rt.daemon_fail_streak += 1
        rt.daemon_poll_tick = -DAEMON_FAIL_BACKOFF_FRAMES  # back off
        print("[daemon-bridge] poll failed (", rt.daemon_fail_streak, "/",
              DAEMON_FAIL_STREAK_MAX, "):", String(e))
        if rt.daemon_fail_streak >= DAEMON_FAIL_STREAK_MAX:
            rt.daemon_ok = False
            rt.daemon_fail_streak = 0
            rt.last_error = String("daemon poll failed: ") + String(e)


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
