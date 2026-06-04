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
from mojoui.render.command_renderer import render_context_commands
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
    var win_w: Float32
    var win_h: Float32
    var scale: Float32

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
        self.win_w = _WIN_W
        self.win_h = _WIN_H
        self.scale = 1.0


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


def _clamp_scale(v: Float32) -> Float32:
    if v < 1.0:
        return 1.0
    if v > 1.8:
        return 1.8
    return v


def _scale_for(win_w: Float32, win_h: Float32) -> Float32:
    var sx = win_w / _WIN_W
    var sy = win_h / _WIN_H
    var s = sx
    if sy < s:
        s = sy
    return _clamp_scale(s)


def _px_scale(scale: Float32, value: Int32) -> Int32:
    return Int32(Float32(Int(value)) * scale + 0.5)


def _px(s: InferenceUIState, value: Int32) -> Int32:
    return _px_scale(s.scale, value)


def _fpx(s: InferenceUIState, value: Float32) -> Float32:
    return value * s.scale


def _font_body(s: InferenceUIState) -> Int32:
    if s.scale >= 1.45:
        return Int32(24)
    if s.scale >= 1.15:
        return Int32(18)
    return Int32(16)


def _left_w(s: InferenceUIState) -> Int32:
    return _px(s, _LEFT_W)


def _right_w(s: InferenceUIState) -> Int32:
    return _px(s, _RIGHT_W)


def _gutter(s: InferenceUIState) -> Int32:
    return _px(s, _GUTTER)


def _center_w(s: InferenceUIState) -> Int32:
    var w = Int32(s.win_w) - _left_w(s) - _right_w(s) - _gutter(s) * 3
    if w < _px(s, _CENTER_W):
        return _px(s, _CENTER_W)
    return w


def _left_label_w(s: InferenceUIState) -> Int32:
    return _px(s, 110)


def _left_field_w(s: InferenceUIState) -> Int32:
    var w = _left_w(s) - _left_label_w(s) - _px(s, 22)
    if w < _px(s, 180):
        return _px(s, 180)
    return w


def _left_full_w(s: InferenceUIState) -> Int32:
    return _left_label_w(s) + _left_field_w(s)


def _right_x(s: InferenceUIState) -> Float32:
    return Float32(Int(_left_w(s) + _center_w(s) + _gutter(s) * 2))


def _initial_window_size() -> Vec2:
    var display = Backend.display_size()
    if display.x <= 0.0 or display.y <= 0.0:
        return Vec2(_WIN_W, _WIN_H)
    var w = display.x * 0.92
    var h = display.y * 0.90
    if w < _WIN_W:
        w = _WIN_W
    if h < _WIN_H:
        h = _WIN_H
    return Vec2(w, h)


def _sync_window_metrics(mut s: InferenceUIState):
    var win = Backend.window_size()
    if win.x <= 0.0 or win.y <= 0.0:
        win = Vec2(_WIN_W, _WIN_H)
    s.win_w = win.x
    s.win_h = win.y
    s.scale = _scale_for(win.x, win.y)
    s.ctx.theme.font_size_pt = _font_body(s)
    s.ctx.theme.row_height = _px(s, 26)
    s.ctx.theme.padding = _px(s, 6)
    s.ctx.theme.spacing = _px(s, 5)


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
    ui_scale: Float32,
    font_size_pt: Int32,
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
            ctx, rect.copy(), Float32(8.0) * ui_scale, Color(30, 30, 38, 255), 6
        )
        if font_id != 0:
            var msg = String("(generating…)") if s.generating else String("(no image yet)")
            var pos = Vec2(
                rect.x + rect.w * Float32(0.5) - Float32(54.0) * ui_scale,
                rect.y + rect.h * Float32(0.5),
            )
            ctx.draw_text(font_id, font_size_pt, pos, Color(140, 145, 160, 255), msg)


# ---------------------------------------------------------------------------
# Left params panel — collapsing-header sections.
# ---------------------------------------------------------------------------


def _section_model(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Model"), s.sec_model):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Task:"))
        _ = combobox(ctx, String("task"), s.model.task_options,
                     s.model.task_index, s.model.task_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Model:"))
        _ = combobox(ctx, String("model"), s.model.model_options,
                     s.model.model_index, s.model.model_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("VAE:"))
        _ = combobox(ctx, String("vae"), s.model.vae_options,
                     s.model.vae_index, s.model.vae_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Precision:"))
        _ = combobox(ctx, String("precision"), s.model.precision_options,
                     s.model.precision_index, s.model.precision_open)


def _section_resolution(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Resolution"), s.sec_resolution):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Preset:"))
        _ = combobox(ctx, String("respreset"), s.model.resolution_options,
                     s.model.resolution_index, s.model.resolution_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Width:"))
        _ = slider(ctx, s.model.width, Float32(256.0), Float32(2048.0), String("width"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Height:"))
        _ = slider(ctx, s.model.height, Float32(256.0), Float32(2048.0), String("height"))


def _section_sampling(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Sampling"), s.sec_sampling):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sampler:"))
        _ = combobox(ctx, String("sampler"), s.model.sampler_options,
                     s.model.sampler_index, s.model.sampler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Scheduler:"))
        _ = combobox(ctx, String("scheduler"), s.model.scheduler_options,
                     s.model.scheduler_index, s.model.scheduler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Steps:"))
        _ = slider(ctx, s.model.steps, Float32(1.0), Float32(100.0), String("steps"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CFG:"))
        _ = drag_value(ctx, s.model.cfg, String("cfg"), Float32(0.1))


def _section_seed(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Seed"), s.sec_seed):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Seed:"))
        _ = drag_value(ctx, s.model.seed, String("seed"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Mode:"))
        _ = combobox(ctx, String("seedmode"), s.model.seed_mode_options,
                     s.model.seed_mode_index, s.model.seed_mode_open)
        ctx.layout_row(_row1(_left_full_w(s)), _px(s, 28))
        _ = checkbox(ctx, String("Lock seed"), s.model.seed_locked)


def _section_lora(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("LoRA"), s.sec_lora):
        var n = len(s.model.loras)
        for i in range(n):
            ctx.layout_row(_row3(_px(s, 140), _px(s, 168), _px(s, 50)), _px(s, 26))
            label(ctx, s.model.loras[i].name)
            _ = slider(ctx, s.model.loras[i].strength, Float32(0.0),
                       Float32(2.0), String("lora_str_") + String(i))
            _ = checkbox(ctx, String(""), s.model.loras[i].active)
        ctx.layout_row(_row2(_px(s, 180), _left_full_w(s) - _px(s, 180)), _px(s, 28))
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
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Count:"))
        _ = slider(ctx, s.model.batch_count, Float32(1.0), Float32(16.0), String("bcount"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Size:"))
        _ = slider(ctx, s.model.batch_size, Float32(1.0), Float32(8.0), String("bsize"))


def _section_advanced(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Advanced"), s.sec_advanced):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Clip skip:"))
        _ = drag_value(ctx, s.model.clip_skip, String("clipskip"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Eta:"))
        _ = drag_value(ctx, s.model.eta, String("eta"), Float32(0.05))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sigma min:"))
        _ = drag_value(ctx, s.model.sigma_min, String("sigmin"), Float32(0.01))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sigma max:"))
        _ = drag_value(ctx, s.model.sigma_max, String("sigmax"), Float32(0.1))
        ctx.layout_row(_row1(_left_full_w(s)), _px(s, 28))
        _ = checkbox(ctx, String("Restart sampling"), s.model.restart_sampling)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Attention:"))
        _ = combobox(ctx, String("attn"), s.model.attention_options,
                     s.model.attention_index, s.model.attention_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CPU offload:"))
        _ = combobox(ctx, String("offload"), s.model.cpu_offload_options,
                     s.model.cpu_offload_index, s.model.cpu_offload_open)


# ---------------------------------------------------------------------------
# UI composition for the three regions. Each pane gets an explicit layout panel
# so its rows start at the pane's own origin instead of being offset with dummy
# spacer cells inside a single root flow.
# ---------------------------------------------------------------------------


def _left_panel(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    # Column header
    ctx.layout_row(_row1(_left_w(s)), _px(s, 30))
    label(ctx, String("Parameters"))
    ctx.layout_row(_row1(_left_w(s)), _px(s, 4))
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
    ctx.layout_row(_row1(_center_w(s)), _px(s, 30))
    label(ctx, String("Image  ·  ") + s.model.task_short()
          + String("  ·  ") + s.model.model_label())

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Prompt:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 80))
    if text_area(ctx, String("prompt"), s.model.prompt, s.prompt_edit):
        pass

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Negative:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 56))
    if text_area(ctx, String("negative"), s.model.negative, s.negative_edit):
        pass

    # action bar
    ctx.layout_row(_row3(_px(s, 196), _px(s, 200), _px(s, 200)), _px(s, 40))
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
    ctx.layout_row(_row1(_center_w(s)), _px(s, 460))
    var slot = ctx.layout_next()
    var side: Float32 = _fpx(s, 440.0)
    if side > slot.w - _fpx(s, 20.0):
        side = slot.w - _fpx(s, 20.0)
    if side > slot.h - _fpx(s, 20.0):
        side = slot.h - _fpx(s, 20.0)
    var img = Rect(
        slot.x + (slot.w - side) * Float32(0.5),
        slot.y + _fpx(s, 10.0),
        side, side,
    )
    _draw_preview(ctx, img, s.model, s.font_id, s.zrt.texture_id, s.scale, _font_body(s))

    # progress bar + readout
    ctx.layout_row(_row1(_center_w(s)), _px(s, 18))
    progress_bar(ctx, zimage_progress_fraction(s.model))
    if s.font_id != 0:
        var readout = String("step ") + String(s.model.current_step) \
            + String("/") + String(s.model.total_steps)
        ctx.draw_text(s.font_id, _font_body(s),
                      Vec2(col_x, s.win_h - _fpx(s, 18.0)),
                      Color(150, 200, 160, 255), readout)


def _right_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    # queue / history tab buttons
    ctx.layout_row(_row2(_px(s, 170), _px(s, 170)), _px(s, 30))
    if button(ctx, String("Queue")):
        s.model.queue_tab = 0
    if button(ctx, String("History")):
        s.model.queue_tab = 1
    ctx.layout_row(_row1(_right_w(s)), _px(s, 4))
    separator(ctx)

    if s.model.queue_tab == 0:
        if s.model.has_running:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("▶ running #") + String(s.model.running.id))
            ctx.layout_row(_row1(_right_w(s)), _px(s, 16))
            progress_bar(ctx, s.model.running.progress())
        var nq = len(s.model.queued)
        for i in range(nq):
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("· queued #") + String(s.model.queued[i].id)
                  + String("  ") + String(Int(s.model.queued[i].width))
                  + String("x") + String(Int(s.model.queued[i].height)))
        if (not s.model.has_running) and nq == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(queue empty)"))
    else:
        var nh = len(s.model.history)
        if nh == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(no history)"))
        for i in range(nh):
            var idx = nh - 1 - i  # newest first
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("✓ #") + String(s.model.history[idx].id)
                  + String("  seed ") + String(s.model.history[idx].seed))

    # perf footer drawn as absolute text at the bottom of the right column
    if s.font_id != 0:
        var y = s.win_h - _fpx(s, 86.0)
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y),
                      Color(170, 175, 190, 255), s.model.perf.gpu_name)
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 20.0)),
                      Color(170, 175, 190, 255),
                      String("VRAM ") + String(Int(s.model.perf.vram_used_gb))
                      + String("/") + String(Int(s.model.perf.vram_total_gb)) + String(" GB"))
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 40.0)),
                      Color(170, 175, 190, 255),
                      String("Util ") + String(Int(s.model.perf.gpu_util_pct)) + String("%"))
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 60.0)),
                      Color(170, 175, 190, 255),
                      String("Temp ") + String(Int(s.model.perf.temperature_c)) + String("C"))


def _draw_backgrounds(mut s: InferenceUIState):
    ref ctx = s.ctx
    var right_x = _right_x(s)
    ctx.draw_rect(Rect(0.0, 0.0, s.win_w, s.win_h), Color(22, 22, 28, 255))
    ctx.draw_rect(Rect(0.0, 0.0, Float32(Int(_left_w(s))) + _fpx(s, 8.0), s.win_h),
                  Color(28, 28, 36, 255))
    ctx.draw_rect(Rect(right_x, 0.0, Float32(Int(_right_w(s))) + _fpx(s, 16.0), s.win_h),
                  Color(28, 28, 36, 255))


def _ui(mut s: InferenceUIState) raises:
    _draw_backgrounds(s)
    var left_w = Float32(Int(_left_w(s)))
    var center_x = left_w + _fpx(s, 16.0)
    var center_w = Float32(Int(_center_w(s)))
    var right_x = _right_x(s)

    s.ctx.begin_panel(Rect(0.0, 0.0, left_w, s.win_h))
    _left_panel(s)
    s.ctx.end_panel()

    s.ctx.begin_panel(Rect(center_x, 0.0, center_w, s.win_h))
    _center_panel(s, center_x + _fpx(s, 8.0))
    s.ctx.end_panel()

    s.ctx.begin_panel(Rect(right_x, 0.0, Float32(Int(_right_w(s))), s.win_h))
    _right_panel(s, right_x + _fpx(s, 12.0))
    s.ctx.end_panel()


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    _ = Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


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
    """Render through the shared live command-buffer adapter."""
    _ = render_context_commands(ctx, String("MojoUI m8"))


def _frame() -> None:
    var sp = retrieve_user_state[InferenceUIState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
    _sync_window_metrics(sp[])

    # Advance the UI worker one frame BEFORE building the UI so progress and
    # completed-result textures are current this frame.
    zimage_tick_and_apply(sp[].model, sp[].zrt)
    _sync_result_texture(sp[])

    sp[].ctx.begin_frame(Vec2(sp[].win_w, sp[].win_h))
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

    var initial_size = _initial_window_size()
    state.win_w = initial_size.x
    state.win_h = initial_size.y
    state.scale = _scale_for(initial_size.x, initial_size.y)

    var rc = Backend.init(
        Int32(Int(initial_size.x)), Int32(Int(initial_size.y)),
        String("MojoUI m8 — Inference"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print(
        "Opening inference UI (Z-Image bridge; real_backend=", backend_is_real(),
        ", scale=", state.scale,
        ", window=", Int(state.win_w), "x", Int(state.win_h),
        "). Click Generate to run."
    )
    Backend.run_blocking(_frame)
    # Keep-alive: reference state AFTER run_blocking so ASAP destruction does
    # not free the struct (and the callback's pointer) early.
    if state.zrt.texture_id != UInt32(0):
        Backend.destroy_texture(state.zrt.texture_id)
    print("PASS: m8 inference UI exited. history=", len(state.model.history))
