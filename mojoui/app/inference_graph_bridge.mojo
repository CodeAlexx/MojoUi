"""Graph-backed inference bridge for Serenity-style UI apps.

This module turns an `InferenceState` snapshot into a Comfy-shaped MojoUI
workflow, executes that workflow through the pure Mojo graph executor, then
optionally launches the existing Klein 9B Mojo sampler process. It is blocking
for now: works first, then we can move the system launch into a nonblocking
job runner.
"""

from std.ffi import external_call
from std.io.file import open
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
    _post,
    _opt_str,
)
from mojoui.app.prompt_syntax import _parse_float, _trim
from json.parser import loads
from json.serialize import dumps
from json.value import JSONValue
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
comptime LTX2_FAST_CONTEXT = "/home/alex/mojodiffusion/output/serenity_ui_out/conditioning_cache/ltx2/creator-refhq-v1/a1feff9785606da9.safetensors"
comptime LTX2_FAST_PROMPT = "vrtlEri2 woman in a cinematic close-up portrait, natural window light, subtle movement, realistic skin, shallow depth of field"
comptime SERENITY_LORA_DIR = "/home/alex/.serenity/models/loras"


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
    var daemon_submitted_miss: List[Int]      # F3: consecutive /v1/jobs misses
    var daemon_jobs_cache: List[DaemonJobInfo]  # last /v1/jobs (queue rail)
    var daemon_done_events: List[DaemonJobInfo] # terminal jobs, drained by screen
    var daemon_poll_tick: Int
    var daemon_health_tick: Int
    var daemon_fail_streak: Int               # consecutive failed polls
    var health_fail_streak: Int               # F5: consecutive failed probes
    var last_submit_json: String              # G2f audit: exact POSTed genparams
    var submit_width: Int                     # dims of the in-flight daemon job
    var submit_height: Int
    var route_label: String                   # "daemon" | "cli" | reason text

    # ── F4: detached CLI-fallback job (PREBUILT binary, spawned via
    # nohup+setsid+pidfile; polled per tick — the render thread NEVER blocks
    # on it and NEVER runs `mojo build`). ──
    var cli_active: Bool
    var cli_cancelled: Bool
    var cli_pid: Int
    var cli_slug: String
    var cli_out_png: String
    var cli_video_path: String
    var cli_log_path: String
    var cli_req_json: String
    var cli_width: Int
    var cli_height: Int
    var cli_tick_ct: Int
    var cli_note: String                      # F11: what the CLI path drops

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
        self.daemon_submitted_miss = List[Int]()
        self.daemon_jobs_cache = List[DaemonJobInfo]()
        self.daemon_done_events = List[DaemonJobInfo]()
        self.daemon_poll_tick = 0
        self.daemon_health_tick = 0
        self.daemon_fail_streak = 0
        self.health_fail_streak = 0
        self.last_submit_json = String("")
        self.submit_width = 0
        self.submit_height = 0
        self.route_label = String("")
        self.cli_active = False
        self.cli_cancelled = False
        self.cli_pid = 0
        self.cli_slug = String("")
        self.cli_out_png = String("")
        self.cli_video_path = String("")
        self.cli_log_path = String("")
        self.cli_req_json = String("")
        self.cli_width = 0
        self.cli_height = 0
        self.cli_tick_ct = 0
        self.cli_note = String("")


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


# ── Multi-model backend registry ───────────────────────────────────────────
# Maps every model the SerenityUI dropdown exposes to a PREBUILT CLI binary
# (built ahead of time by serenityUI/scripts/build_clis.sh — the UI NEVER
# builds). New image models only need (1) a `<slug>_sample_cli.mojo` adapter
# that reads a `serenity.sample_prompts.v1` JSON and writes a PNG, mirroring
# `klein_sample_cli`, and (2) one entry in `_resolve_model_spec` below.
#
# arg_style:
#   0 = sample_cli  ->  BIN <config.json> <lora|-> <req.json> <id> <out.png>
#   1 = zimage      ->  BIN <lora|base> <out.png> <req.json> <id>
#   2 = ltx2 fast   ->  BIN fast lora resident noaudio nonag <out_dir> 0

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
        if slug == String("ltx2"):
            self.bin = String(MODEL_BIN_DIR) + String("/ltx2_video_smoke_runner")
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
    if name == String("LTX2 Fast"):
        return ModelBackendSpec(
            True, String("ltx2"), 2,
            String("serenitymojo/pipeline/ltx2_t2v_av_hq.mojo"),
            String(""),
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


# ── F4: detached CLI spawn / poll / cancel (the launcher pattern) ──────────


def _sys_pid_alive(pid: Int) -> Bool:
    """kill(pid, 0) probe — True while the process exists."""
    if pid <= 0:
        return False
    return Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


def _read_pidfile(path: String) -> Int:
    try:
        with open(path, String("r")) as f:
            var text = f.read()
            var b = text.as_bytes()
            var acc = 0
            var got = False
            for i in range(text.byte_length()):
                var c = Int(b[i])
                if c < 48 or c > 57:
                    break
                acc = acc * 10 + (c - 48)
                got = True
            if got:
                return acc
    except:
        pass
    return 0


def _read_text_or_empty(path: String) -> String:
    try:
        with open(path, String("r")) as f:
            return f.read()
    except:
        return String("")


def _count_occurrences(text: String, needle: String) -> Int:
    """Count non-overlapping ASCII markers without regex/Python."""
    var tn = text.byte_length()
    var nn = needle.byte_length()
    if nn == 0 or tn < nn:
        return 0
    var tb = text.as_bytes()
    var nb = needle.as_bytes()
    var count = 0
    var i = 0
    while i <= tn - nn:
        var same = True
        for j in range(nn):
            if tb[i + j] != nb[j]:
                same = False
                break
        if same:
            count += 1
            i += nn
        else:
            i += 1
    return count


def _safe_shell_token(path: String) raises -> String:
    """Accept the path alphabet used by Serenity's model/output roots.

    The detached launcher nests this token inside a shell command, so reject
    whitespace and metacharacters instead of attempting a second quoting
    language inside the existing setsid/bash wrapper.
    """
    if path.byte_length() == 0:
        raise Error("empty shell token")
    var b = path.as_bytes()
    for i in range(path.byte_length()):
        var c = Int(b[i])
        var ok = (
            (c >= 48 and c <= 57) or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122) or c == 47 or c == 46
            or c == 95 or c == 45
        )
        if not ok:
            raise Error("LTX2 path contains unsupported shell characters: " + path)
    return path.copy()


def _resolve_ltx2_lora(name: String) raises -> String:
    if name.byte_length() == 0:
        raise Error("LTX2 Fast requires one selected LoRA")
    if _path_exists(name):
        return _safe_shell_token(name)
    if _path_exists(name + String(".safetensors")):
        return _safe_shell_token(name + String(".safetensors"))
    var under = String(SERENITY_LORA_DIR) + String("/") + name
    if _path_exists(under):
        return _safe_shell_token(under)
    if _path_exists(under + String(".safetensors")):
        return _safe_shell_token(under + String(".safetensors"))
    raise Error(
        String("LTX2 LoRA not found: ") + name
        + String(" (select a file scanned from ") + String(SERENITY_LORA_DIR)
        + String(")")
    )


def _ltx2_cli_progress(mut state: InferenceState, mut rt: GraphUiRuntime):
    var log = _read_text_or_empty(rt.cli_log_path)
    if log.byte_length() == 0:
        rt.last_status = String("LTX2 queued")
        return
    state.total_steps = Int32(8)
    var announced_steps = _count_occurrences(log, String("--- step"))
    if announced_steps > 8:
        announced_steps = 8
    state.current_step = Int32(announced_steps)
    if log.find(String("[decode] video VAE")) >= 0:
        rt.last_status = String("LTX2 decoding video")
    elif announced_steps > 0:
        rt.last_status = (
            String("LTX2 step ") + String(announced_steps) + String(" of 8")
        )
    elif log.find(String("[resident] preloading")) >= 0:
        rt.last_status = String("LTX2 loading model blocks")
    elif log.find(String("[connector]")) >= 0:
        rt.last_status = String("LTX2 loading prompt context")
    else:
        rt.last_status = String("LTX2 loading model")


def cli_spawn_model(
    mut state: InferenceState, mut rt: GraphUiRuntime,
    spec: ModelBackendSpec, display: QueueJob, size: Int,
) raises:
    """Spawn the PREBUILT model CLI detached (nohup + setsid + pidfile +
    output log) and arm the per-tick poll. The render thread returns
    immediately; cli_tick() finalizes. NEVER builds anything."""
    _ = _sys_system(
        String("mkdir -p ")
        + String(MODEL_OUT_DIR) + String(" ")
        + String(MODEL_REQ_DIR) + String(" ")
        + String(MODEL_CAP_DIR)
    )
    var stem = String("serenityui_") + spec.slug + String("_") + String(display.id)
    var req_json = String(MODEL_REQ_DIR) + String("/") + stem + String(".json")
    var caps_pos = String(MODEL_CAP_DIR) + String("/") + stem + String("_pos.bin")
    var caps_neg = String(MODEL_CAP_DIR) + String("/") + stem + String("_neg.bin")
    var out_png = String(MODEL_OUT_DIR) + String("/") + stem + String(".png")
    var video_path = String("")
    var ltx2_out_dir = String("")
    var request_width = size
    var request_height = size
    var request_steps = Int(display.steps)
    if spec.arg_style == 2:
        ltx2_out_dir = String(MODEL_OUT_DIR) + String("/") + stem
        out_png = ltx2_out_dir + String("/hq_frame04.png")
        video_path = ltx2_out_dir + String("/ltx2_t2v_hq.mp4")
        request_width = 384
        request_height = 256
        request_steps = 8
    var log_path = String(MODEL_OUT_DIR) + String("/") + stem + String(".log")
    var pid_path = String(MODEL_OUT_DIR) + String("/") + stem + String(".pid")
    var json = _sample_prompt_json(
        display.prompt, state.negative, request_width, request_height,
        Int32(request_steps), state.cfg, display.seed, caps_pos, caps_neg,
        spec.needs_precache,
    )
    _write_text_file(req_json, json)

    # Per-model invocation contract.
    var invoke: String
    if spec.arg_style == 2:
        if display.prompt != String(LTX2_FAST_PROMPT):
            raise Error(
                String("LTX2 Fast is currently pinned to its cached prompt; use: ")
                + String(LTX2_FAST_PROMPT)
            )
        if state.cli_lora_count != 1:
            raise Error(
                String("LTX2 Fast requires exactly one selected trained LoRA; got ")
                + String(state.cli_lora_count)
            )
        if not _path_exists(String(LTX2_FAST_CONTEXT)):
            raise Error(String("LTX2 cached prompt context missing: ") + String(LTX2_FAST_CONTEXT))
        var ltx2_lora = _resolve_ltx2_lora(state.cli_lora_name)
        var ltx2_context = _safe_shell_token(String(LTX2_FAST_CONTEXT))
        var ltx2_out = _safe_shell_token(ltx2_out_dir)
        invoke = (
            String("env LTX2_TRAINED_LORA=") + ltx2_lora
            + String(" LTX2_TRAINED_LORA_MULT=") + String(state.cli_lora_weight)
            + String(" LTX2_CTX_DUMP=") + ltx2_context + String(" ")
            + spec.bin + String(" fast lora resident noaudio nonag ")
            + ltx2_out + String(" 0")
        )
    elif spec.arg_style == 1:
        # zimage_generate <lora|base> <out.png> <req.json> <id>
        invoke = spec.bin + String(" base ") + out_png + String(" ") + req_json + String(" serenityui")
    else:
        # sample_cli <config.json> <lora|-> <req.json> <id> <out.png>
        invoke = (
            spec.bin + String(" ") + spec.config + String(" - ")
            + req_json + String(" serenityui ") + out_png
        )
    var chain = String("")
    if spec.needs_precache:
        chain += spec.precache_bin + String(" ") + req_json + String(" && ")
    chain += invoke

    # setsid: the spawned bash leads a NEW process group (pgid == pid), so
    # cancel can kill the whole tree with one negative-pid kill.
    var cmd = (
        String("cd ") + String(SERENITY_ROOT)
        + String(" && nohup setsid bash -c '") + chain + String("' > ")
        + log_path + String(" 2>&1 & echo $! > ") + pid_path
    )
    _ = _sys_system(cmd)
    rt.cli_pid = _read_pidfile(pid_path)
    rt.cli_active = True
    rt.cli_cancelled = False
    rt.cli_slug = spec.slug.copy()
    rt.cli_out_png = out_png.copy()
    rt.cli_video_path = video_path.copy()
    rt.cli_log_path = log_path.copy()
    rt.cli_req_json = req_json.copy()
    rt.cli_width = request_width
    rt.cli_height = request_height
    rt.cli_tick_ct = 0
    # F11: honest about what the CLI request JSON does NOT carry.
    if spec.arg_style == 2:
        rt.cli_note = (
            String("LTX2 Fast · selected LoRA @ ")
            + String(state.cli_lora_weight)
            + String(" · cached Eri2 prompt · 384x256 · 8 steps")
        )
        state.total_steps = Int32(8)
    else:
        rt.cli_note = (
            String("CLI: loras/variation/images ignored; size forced ")
            + String(size)
        )
    rt.route_label = String("cli")
    rt.last_command = cmd^
    rt.last_prompt_json = req_json.copy()
    rt.last_log_path = log_path.copy()
    rt.last_status = String("CLI ") + spec.slug + String(" running (pid ") \
        + String(rt.cli_pid) + String(")")
    rt.last_error = String("")
    print("[cli-fallback] spawned", spec.slug, "pid", rt.cli_pid, "log", log_path)


comptime CLI_POLL_FRAMES = 15   # ~4 Hz process/output poll


def cli_tick(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Per-frame nonblocking poll of the detached CLI job (F4)."""
    if not rt.cli_active:
        return
    rt.cli_tick_ct += 1
    if rt.cli_tick_ct < CLI_POLL_FRAMES:
        return
    rt.cli_tick_ct = 0
    if _sys_pid_alive(rt.cli_pid):
        if rt.cli_slug == String("ltx2"):
            _ltx2_cli_progress(state, rt)
        return  # still working; log/PNG polled again next interval
    rt.cli_active = False
    if rt.cli_cancelled:
        rt.last_status = String("CLI cancelled")
        state.has_running = False
        state.generating = False
        state.perf.gpu_util_pct = 0.0
        return
    if _path_exists(rt.cli_out_png):
        var run = GraphBackendRun(
            True, rt.cli_out_png, rt.cli_req_json, rt.cli_log_path,
            rt.last_command, rt.cli_width, rt.cli_height, String(""),
        )
        _finish_success(state, rt, run^)
        if rt.cli_slug == String("ltx2") and _path_exists(rt.cli_video_path):
            rt.last_status = String("LTX2 done -> ") + rt.cli_video_path
    else:
        _finish_failed(
            state, rt,
            String("CLI ") + rt.cli_slug
            + String(" exited without writing ") + rt.cli_out_png
            + String("; see ") + rt.cli_log_path,
        )


def cli_cancel(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Kill the detached CLI's whole process group (F4 cancel)."""
    if not rt.cli_active:
        return
    rt.cli_cancelled = True
    # /usr/bin/kill: dash's `kill` builtin rejects `-- -PGID` (rc=2)
    _ = _sys_system(
        String("/usr/bin/kill -TERM -- -") + String(rt.cli_pid)
        + String(" 2>/dev/null; sleep 0.2; /usr/bin/kill -KILL -- -")
        + String(rt.cli_pid) + String(" 2>/dev/null")
    )
    rt.cli_active = False
    rt.last_status = String("CLI cancelled (pid ") + String(rt.cli_pid) + String(")")
    state.has_running = False
    state.generating = False
    state.perf.gpu_util_pct = 0.0
    print("[cli-fallback] cancelled pid group", rt.cli_pid)


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
    """Generate via the CLI fallback: resolve the model's PREBUILT binary,
    sanity-run the Comfy-shaped graph, then SPAWN the CLI detached (F4).
    Missing binary -> instant clear error, no build, no block."""
    var display = _snapshot_display_job(state)
    state.next_job_id = state.next_job_id + 1

    var model_name = String("Klein 9B")
    if state.cli_model_override.byte_length() > 0:
        # the gen screen mapped the daemon-scanned selection to a CLI backend
        model_name = state.cli_model_override.copy()
    else:
        var mi = Int(state.model_index)
        if mi >= 0 and mi < len(state.model_options):
            model_name = state.model_options[mi].copy()
    var spec: ModelBackendSpec
    try:
        spec = _resolve_model_spec(model_name)
    except e:
        _finish_failed(state, rt, String(e))
        return
    if not spec.supported:
        _finish_failed(state, rt, spec.unsupported_msg)
        return
    # F4: the binary must be PREBUILT — instant error path when missing.
    if not _path_exists(spec.bin):
        _finish_failed(
            state, rt,
            String("CLI backend not built: ") + spec.bin
            + String(" (run scripts/build_clis.sh)"),
        )
        return
    if spec.needs_precache and not _path_exists(spec.precache_bin):
        _finish_failed(
            state, rt,
            String("CLI backend not built: ") + spec.precache_bin
            + String(" (run scripts/build_clis.sh)"),
        )
        return

    var size = _square_klein_size(display.width, display.height)
    var out_png = (
        String(MODEL_OUT_DIR) + String("/serenityui_") + spec.slug
        + String("_") + String(display.id) + String(".png")
    )
    try:
        # Image CLIs retain the Comfy-shaped graph sanity pass. LTX2 is a
        # video artifact backend, so it launches its already-built Mojo runner
        # directly instead of pretending its output is an image workflow.
        if spec.arg_style != 2:
            var graph = build_klein9b_inference_graph(
                state, display, out_png, Int32(size), Int32(size)
            )
            var canvas = CanvasState()
            var device = WorkflowDeviceConfig()
            device.dry_run = False
            var exec_result = execute_workflow_with_device(graph, canvas, device)
            if not exec_result.success:
                _finish_failed(
                    state, rt, String("workflow executor failed before backend launch")
                )
                return
        _start_display_job(state, display)
        cli_spawn_model(state, rt, spec, display, size)
    except e:
        _finish_failed(state, rt, String(e))


def graph_cancel_all(mut state: InferenceState, mut rt: GraphUiRuntime):
    if rt.cli_active:
        cli_cancel(state, rt)
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
        rt.daemon_submitted_miss.append(0)
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


def daemon_submit_workflow(
    mut state: InferenceState, mut rt: GraphUiRuntime,
    workflow_json: String, width: Int, height: Int, steps: Int,
) -> Bool:
    """POST one authored workflow graph to /v1/generate. The daemon executes
    the graph module and returns the same job/progress contract as flat params."""
    var body = String("{\"workflow\":") + workflow_json + String("}")
    try:
        var job_id = daemon_generate(body)
        rt.daemon_submitted.append(job_id.copy())
        rt.daemon_submitted_miss.append(0)
        rt.last_submit_json = body.copy()
        rt.submit_width = width
        rt.submit_height = height
        rt.route_label = String("daemon-workflow")
        rt.last_status = String("daemon workflow ") + job_id
        rt.last_error = String("")
        state.generating = True
        state.has_running = True
        state.current_step = 0
        state.total_steps = Int32(steps)
        state.result_ready = False
        print("[daemon-bridge] submitted workflow", job_id, "->", body)
        return True
    except e:
        rt.daemon_ok = False
        rt.last_error = String("daemon workflow submit failed: ") + String(e)
        print("[daemon-bridge]", rt.last_error)
        return False


def _grid_axis_is_numeric(axis: String) -> Bool:
    """seed/cfg/steps sweep over numbers; sampler/scheduler over strings."""
    return axis == String("seed") or axis == String("cfg") or axis == String("steps")


def _grid_values_array(axis: String, values_csv: String) raises -> JSONValue:
    """Parse a comma-separated sweep list into a JSON array. Numeric axes
    (seed/cfg/steps) yield JSON numbers; string axes (sampler/scheduler)
    yield quoted strings. Blank entries (e.g. trailing comma) are skipped.
    A token that should be numeric but won't parse is silently skipped (the
    empty-array guard in the caller then reports a clear error)."""
    var arr = JSONValue.new_array()
    var numeric = _grid_axis_is_numeric(axis)
    var token = String("")
    var n = values_csv.byte_length()
    var src = values_csv.as_bytes()
    for i in range(n + 1):
        # split on ',' — flush the accumulated token at each comma and at end
        var at_sep = i == n or src[i] == 44  # ','
        if at_sep:
            var t = _trim(token)
            if t.byte_length() > 0:
                if numeric:
                    var ok = False
                    var v = _parse_float(t, ok)
                    if ok:
                        arr.append(JSONValue.from_float(v))
                else:
                    arr.append(JSONValue.from_string(t))
            token = String("")
        else:
            token += chr(Int(src[i]))
    return arr^


def daemon_submit_grid(
    mut rt: GraphUiRuntime, axis: String, values_csv: String,
    base_genparams_json: String,
) raises -> String:
    """POST /v1/grid: sweep `axis` over the comma-separated `values_csv`,
    reusing the canonical genparams body (`base_genparams_json`, the same
    `GenParams.to_json()` the Generate path uses) for every fixed field.

    Builds the flat grid body the server expects — axis, values[], plus the
    generation fields (model/prompt/negative/width/height/steps/seed/sampler/
    scheduler/cfg) lifted from the base genparams, dropping the field that the
    axis sweeps. Returns the absolute grid-PNG `path` on success, or "" on
    error (with rt.last_error set to the server detail / failure reason)."""
    try:
        var base = loads(base_genparams_json)
        if not base.is_object():
            rt.last_error = String("grid: base genparams not a JSON object")
            return String("")
        var values = _grid_values_array(axis, values_csv)
        if values.length() == 0:
            rt.last_error = String("grid: no values parsed from '") + values_csv + String("'")
            return String("")

        var body = JSONValue.new_object()
        body.set("axis", JSONValue.from_string(axis))
        body.set("values", values^)
        # Lift the fixed generation fields from the base genparams, skipping
        # the one the axis sweeps (the server's per-cell value overrides it).
        _grid_copy_str(base, body, String("model"), axis)
        _grid_copy_str(base, body, String("prompt"), axis)
        _grid_copy_str(base, body, String("negative"), axis)
        _grid_copy_int(base, body, String("width"), axis)
        _grid_copy_int(base, body, String("height"), axis)
        _grid_copy_int(base, body, String("steps"), axis)
        _grid_copy_int(base, body, String("seed"), axis)
        _grid_copy_num(base, body, String("cfg"), axis)
        _grid_copy_str(base, body, String("sampler"), axis)
        _grid_copy_str(base, body, String("scheduler"), axis)
        # Advanced-sampling knobs ride through to every cell (none of these is a
        # sweep axis, so they're never the swept field). The server's grid
        # base_params lifts them onto each cell; the worker honors-or-warns.
        _grid_copy_int(base, body, String("clip_skip"), axis)
        _grid_copy_num(base, body, String("eta"), axis)
        _grid_copy_num(base, body, String("sigma_min"), axis)
        _grid_copy_num(base, body, String("sigma_max"), axis)
        _grid_copy_bool(base, body, String("restart_sampling"), axis)
        _grid_copy_str(base, body, String("vae"), axis)

        var req = dumps(body)
        rt.last_submit_json = req.copy()
        var resp = _post(String("/v1/grid"), req, 600000)
        var obj = loads(resp.text())
        if resp.status != 200:
            var detail = String("")
            if obj.is_object():
                detail = _opt_str(obj, String("detail"))
            rt.last_error = (
                String("daemon /v1/grid -> HTTP ") + String(resp.status)
                + String(": ") + detail
            )
            print("[daemon-bridge]", rt.last_error)
            return String("")
        if not obj.is_object():
            rt.last_error = String("daemon /v1/grid: malformed response")
            return String("")
        var path = _opt_str(obj, String("path"))
        rt.last_error = String("")
        rt.last_status = String("grid ") + _opt_str(obj, String("grid_id"))
        print("[daemon-bridge] grid done ->", path)
        return path^
    except e:
        rt.daemon_ok = False
        rt.last_error = String("daemon grid submit failed: ") + String(e)
        print("[daemon-bridge]", rt.last_error)
        return String("")


def _grid_copy_str(
    base: JSONValue, mut out: JSONValue, key: String, axis: String
) raises:
    if key == axis:
        return
    if base.contains(key) and base[key].is_string():
        out.set(key, JSONValue.from_string(base[key].as_string()))


def _grid_copy_int(
    base: JSONValue, mut out: JSONValue, key: String, axis: String
) raises:
    if key == axis:
        return
    if base.contains(key) and base[key].is_int():
        out.set(key, JSONValue.from_int(base[key].as_int()))


def _grid_copy_num(
    base: JSONValue, mut out: JSONValue, key: String, axis: String
) raises:
    if key == axis:
        return
    if base.contains(key) and base[key].is_number():
        out.set(key, JSONValue.from_float(base[key].as_float()))


def _grid_copy_bool(
    base: JSONValue, mut out: JSONValue, key: String, axis: String
) raises:
    if key == axis:
        return
    if base.contains(key) and base[key].is_bool():
        out.set(key, JSONValue.from_bool(base[key].as_bool()))


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


comptime DAEMON_LOST_MISS_MAX = 3  # F3: consecutive vanished-from-/v1/jobs polls


def _daemon_apply_poll(
    mut state: InferenceState, mut rt: GraphUiRuntime, jobs: List[DaemonJobInfo]
):
    """Fold one /v1/jobs snapshot into UI state: progress for the tracked
    jobs, terminal jobs -> done_events (+ preview result on done).

    F3: a tracked job missing from /v1/jobs DAEMON_LOST_MISS_MAX polls in a
    row is declared "lost (daemon restarted)" — a restarted daemon serves a
    fresh job list, so the old id never comes back. One/two misses are
    tolerated (submit/poll race)."""
    rt.daemon_jobs_cache = jobs.copy()
    var still = List[String]()
    var still_miss = List[Int]()
    var finished_any = False
    for i in range(len(rt.daemon_submitted)):
        var idx = _daemon_find_job(jobs, rt.daemon_submitted[i])
        if idx < 0:
            var miss = rt.daemon_submitted_miss[i] + 1
            if miss >= DAEMON_LOST_MISS_MAX:
                finished_any = True
                rt.last_status = (
                    rt.daemon_submitted[i] + String(" lost (daemon restarted)")
                )
                rt.last_error = rt.last_status.copy()
                print("[daemon-bridge]", rt.last_status)
                continue  # drop the phantom job
            still.append(rt.daemon_submitted[i].copy())  # submit/poll race
            still_miss.append(miss)
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
            still_miss.append(0)
            if jobs[idx].state == "running":
                state.current_step = Int32(jobs[idx].step)
                if jobs[idx].total > 0:
                    state.total_steps = Int32(jobs[idx].total)
    rt.daemon_submitted = still^
    rt.daemon_submitted_miss = still_miss^
    if len(rt.daemon_submitted) == 0 and finished_any:
        state.generating = False
        state.has_running = False
        state.current_step = state.total_steps
        state.perf.gpu_util_pct = 0.0


comptime DAEMON_FAIL_STREAK_MAX = 20      # tolerated consecutive poll failures
comptime DAEMON_FAIL_BACKOFF_FRAMES = 90  # extra wait after a failed poll
comptime DAEMON_HEALTH_PROBE_FRAMES = 120 # F5: dedicated probe ~every 2 s @60fps
comptime DAEMON_HEALTH_FAILS_DOWN = 2     # F5: red after ~4 s unreachable
comptime DAEMON_HEALTH_FAILS_LOST = 3     # F3/F5: drop tracked jobs after ~6 s


def graph_tick_and_apply(mut state: InferenceState, mut rt: GraphUiRuntime):
    """Per-frame tick: detached-CLI poll (F4), a DEDICATED lightweight
    health probe every ~2 s with a 500 ms timeout (F5 — separate from job
    polls, runs whether the daemon looked up or down), then throttled
    /v1/jobs polling for progress (P11), the queue rail (P12), and result
    application.

    Poll failures are TOLERATED up to DAEMON_FAIL_STREAK_MAX in a row: a real
    backend's long single ticks (the zimage ENCODE/DECODE phases run tens of
    seconds inside one event-loop tick) stall HTTP past any sane timeout, and
    one slow tick must not orphan a running GPU job. (The health probe is
    subject to the same caveat on a busy single-thread GPU daemon; the
    DOWN verdict therefore needs DAEMON_HEALTH_FAILS_DOWN consecutive
    failures, and tracked jobs are only dropped after
    DAEMON_HEALTH_FAILS_LOST.)"""
    cli_tick(state, rt)
    var active = len(rt.daemon_submitted) > 0

    # ── F5: dedicated health probe (status dot honesty + down detection) ──
    rt.daemon_health_tick += 1
    if rt.daemon_health_tick >= DAEMON_HEALTH_PROBE_FRAMES:
        rt.daemon_health_tick = 0
        var h = daemon_health()  # 500 ms timeout; refused connect fails fast
        if h.ok:
            if not rt.daemon_ok:
                print("[daemon-bridge] health recovered (backend:", h.backend, ")")
            rt.daemon_ok = True
            rt.daemon_backend = h.backend.copy()
            rt.daemon_resident = h.resident.copy()
            rt.health_fail_streak = 0
        else:
            rt.health_fail_streak += 1
            if rt.health_fail_streak >= DAEMON_HEALTH_FAILS_DOWN and rt.daemon_ok:
                rt.daemon_ok = False
                print("[daemon-bridge] health probe failed x",
                      rt.health_fail_streak, "-> daemon DOWN")
            if active and rt.health_fail_streak >= DAEMON_HEALTH_FAILS_LOST:
                # daemon stayed unreachable: stop tracking, free Generate
                for i in range(len(rt.daemon_submitted)):
                    print("[daemon-bridge]", rt.daemon_submitted[i],
                          "lost (daemon down)")
                rt.last_status = rt.daemon_submitted[0] + String(" lost (daemon down)")
                rt.last_error = rt.last_status.copy()
                rt.daemon_submitted = List[String]()
                rt.daemon_submitted_miss = List[Int]()
                state.generating = False
                state.has_running = False
                state.perf.gpu_util_pct = 0.0
    if not rt.daemon_ok:
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
    var prefix = String("graph executor  ·  Klein 9B  ·  ")
    if rt.cli_slug == String("ltx2"):
        prefix = String("Mojo CLI  ·  LTX2 Fast  ·  ")
    if rt.last_error.byte_length() > 0:
        return prefix + rt.last_status + String("  ·  ") + rt.last_error
    return prefix + rt.last_status
