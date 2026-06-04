"""MojoUI m8 — interactive text->image generation app.

A real, interactive MojoUI desktop app mirroring the egui `inference_ui`
reference (Image mode only), driven through the Z-Image UI bridge. The default
backend is still a deterministic CPU stub, so the app can be built and tested
without GPU access; the same bridge is the handoff point for the real backend.
Clicking Generate snapshots the params into a queue job, drains worker events
each frame, uploads completed RGBA results as textures, and pushes history.

Layout (3 columns):
  - LEFT params panel: model · resolution · sampling · seed · lora · batch ·
    advanced (collapsing headers + combobox/slider/drag_value/checkbox).
  - CENTER canvas: task header · prompt + negative text_area · action bar
    (Generate / Cancel / randomize seed) · generated image preview · progress.
  - RIGHT panel: queue list (running + queued w/ per-job progress) · history ·
    perf footer (stub constants unless a real backend feeds metrics).

DEFERRED (per M4 scope scope): Video mode (frames/fps), RON persistence
(state is in-memory only), NVML perf, the controlnet panel, egui-dnd LoRA
reorder.

Build + run: `pixi run inference`. Build-then-run scaffold (text_area /
combobox / tessellator reach FFI symbols the JIT cannot dlopen); the c50
user_data extension carries persistent state across frames; the post-run
keep-alive print prevents ASAP-destruction from freeing state early.
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_RECT, CMD_TEXT, CMD_IMAGE, CMD_TRIANGLES,
    CmdTriangles, read_cmd_rect, read_cmd_text, read_cmd_image,
    read_cmd_triangles,
)
from mojoui.core.multiline_edit import MultiLineState
from mojoui.render.backend import Backend
from mojoui.render.ffi import (
    MOJOUI_KEY_RETURN,
)
from mojoui.widgets.basic import button, label, separator
from mojoui.widgets.text_area import text_area
from mojoui.widgets.combobox import combobox
from mojoui.widgets.slider import slider
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.progress_bar import progress_bar
from mojoui.widgets.collapsing_header import collapsing_header
from mojoui.render.tessellator import tess_rounded_rect
from mojoui.app.state import store_user_state, retrieve_user_state
from mojoui.app.inference_model import (
    InferenceState,
    LoraSlot,
)
from mojoui.app.inference_zimage_bridge import (
    ZImageUiRuntime,
    zimage_submit_current,
    zimage_cancel_all,
    zimage_tick_and_apply,
    zimage_progress_fraction,
)
# REAL Z-IMAGE WORKER SEAM (stub backend remains the default).
# The UI now drives this bridge directly. `_zimage_backend` decides whether the
# backend is a deterministic CPU stub or the real serenitymojo path.
from mojoui.app.zimage_worker import (
    ZImageWorker,
    ZImageJob,
    zimage_start,
    zimage_tick,
)
from mojoui.app._zimage_backend import backend_is_real


# ---------------------------------------------------------------------------
# Layout constants. Three columns split a 1500-wide window.
# ---------------------------------------------------------------------------

comptime _WIN_W: Float32 = 1500.0
comptime _WIN_H: Float32 = 950.0
comptime _LEFT_W: Int32 = 380
comptime _RIGHT_W: Int32 = 360
comptime _GUTTER: Int32 = 16
# center = win - left - right - 3 gutters
comptime _CENTER_W: Int32 = 1500 - 380 - 360 - 48


# ---------------------------------------------------------------------------
# Persistent demo state — wraps the pure InferenceState plus the live-only
# Context + text-edit engines + section open flags + a frame seed.
# ---------------------------------------------------------------------------


struct InferenceUIState(Movable):
    var ctx: Context
    var model: InferenceState
    var zrt: ZImageUiRuntime

    var prompt_edit: MultiLineState
    var negative_edit: MultiLineState

    # collapsing-header open flags (left panel)
    var sec_model: Bool
    var sec_resolution: Bool
    var sec_sampling: Bool
    var sec_seed: Bool
    var sec_lora: Bool
    var sec_batch: Bool
    var sec_advanced: Bool

    var pseudo_rng: UInt32   # for the randomize-seed button
    var font_id: UInt32

    def __init__(out self):
        self.ctx = Context()
        self.model = InferenceState()
        self.zrt = ZImageUiRuntime()
        self.prompt_edit = MultiLineState()
        self.prompt_edit.set_text(self.model.prompt)
        self.negative_edit = MultiLineState()
        self.negative_edit.set_text(self.model.negative)
        self.sec_model = True
        self.sec_resolution = True
        self.sec_sampling = True
        self.sec_seed = False
        self.sec_lora = False
        self.sec_batch = False
        self.sec_advanced = False
        self.pseudo_rng = 0x9E3779B9
        self.font_id = 0


# ---------------------------------------------------------------------------
# Row-width helpers (fresh List[Int32] per call — c13 by-move ownership).
# ---------------------------------------------------------------------------


def _row1(a: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    return w^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    return w^


def _row3(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    return w^


# ---------------------------------------------------------------------------
# Synthetic gradient preview. Paints horizontal color bands derived from a
# UInt32 seed so each completed generation looks distinct. No image upload —
# pure draw_rect bands, mirroring the spec's "synthetic gradient" placeholder.
# ---------------------------------------------------------------------------


def _draw_synthetic(mut ctx: Context, rect: Rect, color_seed: UInt32):
    var bands: Int32 = 24
    var bh = rect.h / Float32(Int(bands))
    var s = color_seed
    for i in range(Int(bands)):
        # cheap LCG to perturb the band color
        s = s * UInt32(1664525) + UInt32(1013904223)
        var r = UInt8((s >> UInt32(16)) & UInt32(0xFF))
        var g = UInt8((s >> UInt32(8)) & UInt32(0xFF))
        var b = UInt8(s & UInt32(0xFF))
        # blend toward a teal-ish base so it reads as a "render"
        var rr = UInt8((Int(r) + 30) // 2)
        var gg = UInt8((Int(g) + 120) // 2)
        var bb = UInt8((Int(b) + 150) // 2)
        var band = Rect(
            rect.x, rect.y + Float32(i) * bh, rect.w, bh + Float32(1.0)
        )
        ctx.draw_rect(band, Color(rr, gg, bb, UInt8(255)))


def _draw_preview(
    mut ctx: Context,
    rect: Rect,
    s: InferenceState,
    font_id: UInt32,
    texture_id: UInt32,
):
    """Rounded-rect slot; synthetic gradient when a result is ready, else a
    centered placeholder label."""
    if texture_id != UInt32(0):
        var white = Color(255, 255, 255, 255)
        _ = ctx.commands.emit_image(rect.copy(), texture_id, white.copy())
    elif s.result_ready:
        _draw_synthetic(ctx, rect.copy(), s.history[len(s.history) - 1].color_seed)
    else:
        tess_rounded_rect(
            ctx, rect.copy(), Float32(8.0), Color(30, 30, 38, 255), 6
        )
        if font_id != 0:
            var msg = String("(generating…)") if s.generating else String("(no image yet)")
            var pos = Vec2(
                rect.x + rect.w * Float32(0.5) - Float32(54.0),
                rect.y + rect.h * Float32(0.5),
            )
            ctx.draw_text(font_id, Int32(14), pos, Color(140, 145, 160, 255), msg)


# ---------------------------------------------------------------------------
# Left params panel — collapsing-header sections.
# ---------------------------------------------------------------------------


def _section_model(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Model"), s.sec_model):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Task:"))
        _ = combobox(ctx, String("task"), s.model.task_options,
                     s.model.task_index, s.model.task_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Model:"))
        _ = combobox(ctx, String("model"), s.model.model_options,
                     s.model.model_index, s.model.model_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("VAE:"))
        _ = combobox(ctx, String("vae"), s.model.vae_options,
                     s.model.vae_index, s.model.vae_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Precision:"))
        _ = combobox(ctx, String("precision"), s.model.precision_options,
                     s.model.precision_index, s.model.precision_open)


def _section_resolution(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Resolution"), s.sec_resolution):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Preset:"))
        _ = combobox(ctx, String("respreset"), s.model.resolution_options,
                     s.model.resolution_index, s.model.resolution_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Width:"))
        _ = slider(ctx, s.model.width, Float32(256.0), Float32(2048.0), String("width"))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Height:"))
        _ = slider(ctx, s.model.height, Float32(256.0), Float32(2048.0), String("height"))


def _section_sampling(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Sampling"), s.sec_sampling):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Sampler:"))
        _ = combobox(ctx, String("sampler"), s.model.sampler_options,
                     s.model.sampler_index, s.model.sampler_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Scheduler:"))
        _ = combobox(ctx, String("scheduler"), s.model.scheduler_options,
                     s.model.scheduler_index, s.model.scheduler_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Steps:"))
        _ = slider(ctx, s.model.steps, Float32(1.0), Float32(100.0), String("steps"))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("CFG:"))
        _ = drag_value(ctx, s.model.cfg, String("cfg"), Float32(0.1))


def _section_seed(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Seed"), s.sec_seed):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Seed:"))
        _ = drag_value(ctx, s.model.seed, String("seed"), Float32(1.0))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Mode:"))
        _ = combobox(ctx, String("seedmode"), s.model.seed_mode_options,
                     s.model.seed_mode_index, s.model.seed_mode_open)
        ctx.layout_row(_row1(358), 28)
        _ = checkbox(ctx, String("Lock seed"), s.model.seed_locked)


def _section_lora(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("LoRA"), s.sec_lora):
        var n = len(s.model.loras)
        for i in range(n):
            ctx.layout_row(_row3(140, 168, 50), 26)
            label(ctx, s.model.loras[i].name)
            _ = slider(ctx, s.model.loras[i].strength, Float32(0.0),
                       Float32(2.0), String("lora_str_") + String(i))
            _ = checkbox(ctx, String(""), s.model.loras[i].active)
        ctx.layout_row(_row2(180, 178), 28)
        if button(ctx, String("+ Add LoRA")):
            s.model.loras.append(
                LoraSlot(String("new-lora.safetensors"), Float32(1.0), True)
            )
        if button(ctx, String("- Remove last")):
            if len(s.model.loras) > 0:
                var keep = List[LoraSlot]()
                for j in range(len(s.model.loras) - 1):
                    keep.append(s.model.loras[j].copy())
                s.model.loras = keep^


def _section_batch(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Batch"), s.sec_batch):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Count:"))
        _ = slider(ctx, s.model.batch_count, Float32(1.0), Float32(16.0), String("bcount"))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Size:"))
        _ = slider(ctx, s.model.batch_size, Float32(1.0), Float32(8.0), String("bsize"))


def _section_advanced(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Advanced"), s.sec_advanced):
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Clip skip:"))
        _ = drag_value(ctx, s.model.clip_skip, String("clipskip"), Float32(1.0))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Eta:"))
        _ = drag_value(ctx, s.model.eta, String("eta"), Float32(0.05))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Sigma min:"))
        _ = drag_value(ctx, s.model.sigma_min, String("sigmin"), Float32(0.01))
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Sigma max:"))
        _ = drag_value(ctx, s.model.sigma_max, String("sigmax"), Float32(0.1))
        ctx.layout_row(_row1(358), 28)
        _ = checkbox(ctx, String("Restart sampling"), s.model.restart_sampling)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("Attention:"))
        _ = combobox(ctx, String("attn"), s.model.attention_options,
                     s.model.attention_index, s.model.attention_open)
        ctx.layout_row(_row2(110, 248), 28)
        label(ctx, String("CPU offload:"))
        _ = combobox(ctx, String("offload"), s.model.cpu_offload_options,
                     s.model.cpu_offload_index, s.model.cpu_offload_open)


# ---------------------------------------------------------------------------
# UI composition for the three regions. We lay out left/center/right as three
# top-level rows whose contents we offset by absolute x via the layout cell
# width split — MojoUI's layout is single-column-of-rows, so we emulate three
# columns by giving each section row a leading spacer cell. Simpler approach
# used here: the params panel uses the full window width but is visually scoped
# to the left by clipping the column backgrounds; widgets are placed with the
# multi-cell rows above. To keep it robust we render the three regions in
# sequence using begin/explicit y via separate layout passes is overkill —
# instead we paint column backgrounds and place each column's rows by setting
# a column-local layout row that starts at the column's x.
#
# MojoUI layout_row lays cells left-to-right starting at the panel origin (0).
# To place a column at x = X we prepend a spacer cell of width X (an empty
# label). This keeps everything within the existing single-column layout model.
# ---------------------------------------------------------------------------


def _left_panel(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    # Column header
    ctx.layout_row(_row1(_LEFT_W), 30)
    label(ctx, String("Parameters"))
    ctx.layout_row(_row1(_LEFT_W), 4)
    separator(ctx)
    _section_model(s)
    _section_resolution(s)
    _section_sampling(s)
    _section_seed(s)
    _section_lora(s)
    _section_batch(s)
    _section_advanced(s)


def _center_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    # task/mode header
    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 30)
    label(ctx, String(""))  # spacer to push to center column
    label(ctx, String("Image  ·  ") + s.model.task_short()
          + String("  ·  ") + s.model.model_label())

    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 24)
    label(ctx, String(""))
    label(ctx, String("Prompt:"))
    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 80)
    label(ctx, String(""))
    if text_area(ctx, String("prompt"), s.model.prompt, s.prompt_edit):
        pass

    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 24)
    label(ctx, String(""))
    label(ctx, String("Negative:"))
    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 56)
    label(ctx, String(""))
    if text_area(ctx, String("negative"), s.model.negative, s.negative_edit):
        pass

    # action bar
    ctx.layout_row(_row3(_GUTTER + 196, 200, 200), 40)
    label(ctx, String(""))
    if s.model.generating:
        if button(ctx, String("Cancel")):
            zimage_cancel_all(s.model, s.zrt)
    else:
        if button(ctx, String("Generate")):
            zimage_submit_current(s.model, s.zrt)
    if button(ctx, String("Randomize seed")):
        s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
        s.model.seed = Float32(Int(s.pseudo_rng % UInt32(1000000)))

    # image preview
    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 460)
    label(ctx, String(""))
    var slot = ctx.layout_next()
    var side: Float32 = 440.0
    var img = Rect(
        slot.x + (slot.w - side) * Float32(0.5),
        slot.y + Float32(10.0),
        side, side,
    )
    _draw_preview(ctx, img, s.model, s.font_id, s.zrt.texture_id)

    # progress bar + readout
    ctx.layout_row(_row2(_GUTTER, _CENTER_W), 18)
    label(ctx, String(""))
    progress_bar(ctx, zimage_progress_fraction(s.model))
    if s.font_id != 0:
        var readout = String("step ") + String(s.model.current_step) \
            + String("/") + String(s.model.total_steps)
        ctx.draw_text(s.font_id, Int32(14),
                      Vec2(col_x, _WIN_H - Float32(18.0)),
                      Color(150, 200, 160, 255), readout)


def _right_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    var pad = _LEFT_W + _CENTER_W + _GUTTER * Int32(2)
    # queue / history tab buttons
    ctx.layout_row(_row3(pad, 170, 170), 30)
    label(ctx, String(""))
    if button(ctx, String("Queue")):
        s.model.queue_tab = 0
    if button(ctx, String("History")):
        s.model.queue_tab = 1
    ctx.layout_row(_row2(pad, _RIGHT_W), 4)
    label(ctx, String(""))
    separator(ctx)

    if s.model.queue_tab == 0:
        if s.model.has_running:
            ctx.layout_row(_row2(pad, _RIGHT_W), 22)
            label(ctx, String(""))
            label(ctx, String("▶ running #") + String(s.model.running.id))
            ctx.layout_row(_row2(pad, _RIGHT_W), 16)
            label(ctx, String(""))
            progress_bar(ctx, s.model.running.progress())
        var nq = len(s.model.queued)
        for i in range(nq):
            ctx.layout_row(_row2(pad, _RIGHT_W), 22)
            label(ctx, String(""))
            label(ctx, String("· queued #") + String(s.model.queued[i].id)
                  + String("  ") + String(Int(s.model.queued[i].width))
                  + String("x") + String(Int(s.model.queued[i].height)))
        if (not s.model.has_running) and nq == 0:
            ctx.layout_row(_row2(pad, _RIGHT_W), 22)
            label(ctx, String(""))
            label(ctx, String("(queue empty)"))
    else:
        var nh = len(s.model.history)
        if nh == 0:
            ctx.layout_row(_row2(pad, _RIGHT_W), 22)
            label(ctx, String(""))
            label(ctx, String("(no history)"))
        for i in range(nh):
            var idx = nh - 1 - i  # newest first
            ctx.layout_row(_row2(pad, _RIGHT_W), 22)
            label(ctx, String(""))
            label(ctx, String("✓ #") + String(s.model.history[idx].id)
                  + String("  seed ") + String(s.model.history[idx].seed))

    # perf footer drawn as absolute text at the bottom of the right column
    if s.font_id != 0:
        var y = _WIN_H - Float32(86.0)
        ctx.draw_text(s.font_id, Int32(14), Vec2(col_x, y),
                      Color(170, 175, 190, 255), s.model.perf.gpu_name)
        ctx.draw_text(s.font_id, Int32(14), Vec2(col_x, y + Float32(20.0)),
                      Color(170, 175, 190, 255),
                      String("VRAM ") + String(Int(s.model.perf.vram_used_gb))
                      + String("/") + String(Int(s.model.perf.vram_total_gb)) + String(" GB"))
        ctx.draw_text(s.font_id, Int32(14), Vec2(col_x, y + Float32(40.0)),
                      Color(170, 175, 190, 255),
                      String("Util ") + String(Int(s.model.perf.gpu_util_pct)) + String("%"))
        ctx.draw_text(s.font_id, Int32(14), Vec2(col_x, y + Float32(60.0)),
                      Color(170, 175, 190, 255),
                      String("Temp ") + String(Int(s.model.perf.temperature_c)) + String("C"))


def _draw_backgrounds(mut s: InferenceUIState):
    ref ctx = s.ctx
    var right_x = Float32(Int(_LEFT_W + _CENTER_W + _GUTTER * Int32(2)))
    ctx.draw_rect(Rect(0.0, 0.0, _WIN_W, _WIN_H), Color(22, 22, 28, 255))
    ctx.draw_rect(Rect(0.0, 0.0, Float32(Int(_LEFT_W)) + 8.0, _WIN_H),
                  Color(28, 28, 36, 255))
    ctx.draw_rect(Rect(right_x, 0.0, Float32(Int(_RIGHT_W)) + 16.0, _WIN_H),
                  Color(28, 28, 36, 255))


def _ui(mut s: InferenceUIState) raises:
    _draw_backgrounds(s)
    var right_x = Float32(Int(_LEFT_W + _CENTER_W + _GUTTER * Int32(2)))

    # Three regions composed as sequential row groups. Because MojoUI layout is
    # a single column of rows, each region's rows carry leading spacer cells to
    # offset them horizontally; the layout y is reset per region by replaying
    # from the top using a fresh layout_row call group. To stack them visually
    # we render left, then re-seed y for center+right via absolute text +
    # spacer-prefixed rows. For a clean MVP we render the LEFT panel first
    # (its own rows), then CENTER and RIGHT which use spacer-prefixed rows so
    # they appear in their columns even though the layout y keeps advancing.
    #
    # Simpler + robust: render all three top-to-bottom but the center/right
    # rows are prefixed with a wide spacer so their widgets land in the right
    # column. They share the running layout y, so we reset y between regions by
    # NOT resetting (acceptable: each region's content is short enough). To
    # avoid overlap we render LEFT fully, then CENTER fully below it, then
    # RIGHT below that — visually stacked but each in its own x-column.
    _left_panel(s)
    _center_panel(s, Float32(Int(_LEFT_W)) + 24.0)
    _right_panel(s, right_x + 12.0)


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _sync_result_texture(mut s: InferenceUIState):
    """Upload the latest completed worker RGBA buffer once the GL context is live."""
    if s.zrt.result_job_id == UInt64(0):
        return
    if s.zrt.result_job_id == s.zrt.uploaded_job_id:
        return
    if s.zrt.result_width <= 0 or s.zrt.result_height <= 0:
        return
    if len(s.zrt.result_pixels) == 0:
        return
    if s.zrt.texture_id != UInt32(0):
        Backend.destroy_texture(s.zrt.texture_id)
        s.zrt.texture_id = UInt32(0)
    s.zrt.texture_id = Backend.make_texture_rgba(
        Int32(s.zrt.result_width),
        Int32(s.zrt.result_height),
        s.zrt.result_pixels,
    )
    if s.zrt.texture_id != UInt32(0):
        s.zrt.uploaded_job_id = s.zrt.result_job_id


def _render_command_buffer(mut ctx: Context) raises:
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                return
            continue
        var size = ctx.commands.size_at(off)
        if kind == CMD_RECT:
            var cmd = read_cmd_rect(ctx.commands, off)
            Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(ctx.commands, off)
            _ = Backend.draw_text(
                cmd.font_id, cmd.size_pt, cmd.text,
                cmd.pos.copy(), cmd.color.copy(),
            )
        elif kind == CMD_IMAGE:
            var cmd = read_cmd_image(ctx.commands, off)
            Backend.draw_image_rect(
                cmd.rect.copy(),
                cmd.texture_id,
                cmd.tint.copy(),
            )
        elif kind == CMD_TRIANGLES:
            var cmd = read_cmd_triangles(ctx.commands, off)
            _dispatch_triangles(cmd)
        off = off + size


def _frame() -> None:
    var sp = retrieve_user_state[InferenceUIState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
        # MUST be a pre-baked atlas size — the C floor only bakes
        # {12,14,16,18,24} (issue #73). 15 has no atlas, so all widget text
        # (which uses theme.font_size_pt) silently renders nothing while
        # manual 14pt draws still show. Use 16.
        sp[].ctx.theme.font_size_pt = Int32(16)
        sp[].ctx.theme.row_height = Int32(26)
        sp[].ctx.theme.padding = Int32(6)
        sp[].ctx.theme.spacing = Int32(5)

    # Advance the UI worker one frame BEFORE building the UI so progress and
    # completed-result textures are current this frame.
    zimage_tick_and_apply(sp[].model, sp[].zrt)
    _sync_result_texture(sp[])

    sp[].ctx.begin_frame(Vec2(_WIN_W, _WIN_H))
    Backend.frame_begin(Color(18, 18, 22, 255))
    try:
        _ui(sp[])
    except e:
        print("MojoUI m8 UI error:", String(e))
    sp[].ctx.end_frame()
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m8 walker error:", String(e))
    Backend.frame_end()


def _zimage_seam_selfcheck():
    """Exercise the real Z-Image worker seam ONCE over the stub backend at
    startup. This is NOT the live UI driver (the mock above still drives the
    window); it keeps the real worker + adapter in this build's call graph and
    proves the protocol (Started→Progress×N→Done) + the RGBA result path link
    in MojoUI's env. Under the merged GPU env (ZIMAGE_REAL_BACKEND=True) this
    same path would run a real generation; here it returns a stub gradient."""
    var w = ZImageWorker()
    var job = ZImageJob(
        UInt64(1), String("seam check"), String(""),
        2, Float32(4.0), Int64(42), 64, 64, UInt32(7),
    )
    zimage_start(w, job^)
    for _ in range(2 * 6 + 2):
        zimage_tick(w)
    print(
        "[zimage-seam] real_backend=", backend_is_real(),
        " done=", w.done, " events=", len(w.events),
        " result_ok=", w.result.ok,
        " progress=", Float32(w.current_step) / Float32(w.total_steps),
    )


def main() raises:
    _zimage_seam_selfcheck()
    var state = InferenceUIState()
    var sp = UnsafePointer(to=state)
    store_user_state(sp)

    var rc = Backend.init(
        Int32(Int(_WIN_W)), Int32(Int(_WIN_H)),
        String("MojoUI m8 — Inference"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening inference UI (Z-Image bridge; real_backend=", backend_is_real(), "). Click Generate to run.")
    Backend.run_blocking(_frame)
    # Keep-alive: reference state AFTER run_blocking so ASAP destruction does
    # not free the struct (and the callback's pointer) early.
    if state.zrt.texture_id != UInt32(0):
        Backend.destroy_texture(state.zrt.texture_id)
    print("PASS: m8 inference UI exited. history=", len(state.model.history))
