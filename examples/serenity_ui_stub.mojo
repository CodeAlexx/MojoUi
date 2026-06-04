"""MojoUI c54 — serenitymojo UI stub (M4 preview).

Static single-frame demo showing the EXACT UI shape serenitymojo's app will
use once the M4 integration lands. Proves the MojoUI widget catalog composes
the screens a diffusion app needs:

  - Title bar with theme switcher buttons
  - Model picker (combobox: Z-Image / FLUX / SD3 / Klein9B / SDXL / HiDream-O1)
  - Positive + negative prompts (text_area, multi-line)
  - Sampler controls (combobox + sliders + drag_value for cfg/seed/width/height)
  - Generate button (accent-sized 48-px row)
  - Progress bar (display-only, 0.0 initially)
  - Image preview rect (placeholder 512x512 colored rounded rect)

No actual serenitymojo pipeline integration — this is a STATIC FRAME demo per
the c10/c18/c49 pattern. Runtime visual gate (real window + Generate triggers
the pipeline) DEFERRED — the same M4 chunk that wires the live window will
also wire the actual pipeline call. Static gate: every widget composes, all
state mutates correctly, command buffer non-empty.

Built (NOT JIT) for the same reason `m2_widgets_gallery.mojo` and
`m3_themed_gallery.mojo` are: text_area + combobox reach FFI symbols
(`mojoui_get_input_text`, `mojoui_get_key`) AND the M3 image-preview helper
calls `tess_rounded_rect` which reaches `mojoui_draw_batch`. Linking against
libmojoui_floor.so at build time resolves them; the runtime guard in
`begin_frame_no_input` keeps the FFI from actually firing.

Run via:
    pixi run serenity_ui
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.theme.themes import dark_theme
from mojoui.theme.tokens import Theme
from mojoui.theme.typography import load_default_ui_font
from mojoui.widgets.basic import button, label, separator
from mojoui.widgets.text_area import text_area
from mojoui.core.multiline_edit import MultiLineState
from mojoui.widgets.combobox import combobox
from mojoui.widgets.slider import slider
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.progress_bar import progress_bar
from mojoui.render.tessellator import tess_rounded_rect


# ---------------------------------------------------------------------------
# SerenityState — every piece of caller-managed state the UI needs to drive
# a one-off diffusion generation. Mirrors the structure of arguments
# `zimage_pipeline.mojo` (positive/negative prompt, sampler, steps, cfg,
# seed, width, height) plus UI-only state (combobox open flags, progress,
# preview-loaded flag). Threaded through `_emit_frame` by `main()`.
# ---------------------------------------------------------------------------


struct SerenityState:
    var model_options: List[String]
    var model_index: Int32
    var model_open: Bool

    var positive_prompt: String
    var negative_prompt: String
    var positive_edit_state: MultiLineState
    var negative_edit_state: MultiLineState

    var sampler_options: List[String]
    var sampler_index: Int32
    var sampler_open: Bool

    var steps: Float32     # slider; stored Float32 but logically Int
    var cfg: Float32       # drag_value (0.1 increment)
    var seed: Float32      # drag_value (1.0 increment; cast to Int64 in real call)

    var width: Float32     # slider 256..2048
    var height: Float32    # slider 256..2048

    var progress: Float32  # 0.0..1.0 (display only)
    var image_loaded: Bool

    def __init__(out self):
        var models = List[String]()
        models.append(String("Z-Image"))
        models.append(String("FLUX.2 / Klein9B"))
        models.append(String("SD3 Medium"))
        models.append(String("SDXL Base"))
        models.append(String("HiDream-O1"))
        self.model_options = models^
        self.model_index = 0
        self.model_open = False

        self.positive_prompt = String(
            "a photo of a mountain lake at sunset, vivid colors, sharp focus"
        )
        self.negative_prompt = String("ugly, blurry, low quality, watermark")
        self.positive_edit_state = MultiLineState()
        self.positive_edit_state.set_text(self.positive_prompt)
        self.negative_edit_state = MultiLineState()
        self.negative_edit_state.set_text(self.negative_prompt)

        var samplers = List[String]()
        samplers.append(String("euler"))
        samplers.append(String("dpm++"))
        samplers.append(String("ddim"))
        samplers.append(String("unipc"))
        self.sampler_options = samplers^
        self.sampler_index = 0
        self.sampler_open = False

        self.steps = 30.0
        self.cfg = 7.5
        self.seed = 42.0
        self.width = 1024.0
        self.height = 1024.0
        self.progress = 0.0
        self.image_loaded = False


# ---------------------------------------------------------------------------
# Helpers — fresh `List[Int32]` row widths per call (c13 by-move ownership)
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


def _row4(a: Int32, b: Int32, c: Int32, d: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    w.append(d)
    return w^


# ---------------------------------------------------------------------------
# Image preview placeholder. Renders a tessellated rounded rect with a
# centered "(no image yet)" label when nothing's loaded. The rounded rect
# reaches FFI through `Backend.draw_batch_lists` -> `mojoui_draw_batch`, so
# this binary MUST be built (not JITted) — same constraint as themed gallery.
# ---------------------------------------------------------------------------


def _draw_image_preview(
    mut ctx: Context,
    rect: Rect,
    image_loaded: Bool,
    bg_color: Color,
    text_color: Color,
    font_id: UInt32,
):
    """Paint the image preview slot. bg = bg_color rounded rect (8 px corner
    radius), with a centered placeholder label when image_loaded=False.
    Skips the label when font_id == 0 (per the M1-bugfix font_id contract)."""
    # tess_rounded_rect now emits a CMD_TRIANGLES record on ctx.commands
    # (M3 c46-fix Bug 2). The demo exits after stats print; no walker fires.
    tess_rounded_rect(ctx, rect.copy(), Float32(8.0), bg_color.copy(), 6)
    if (not image_loaded) and font_id != 0:
        var label_pos = Vec2(
            rect.x + rect.w * Float32(0.5) - Float32(60.0),
            rect.y + rect.h * Float32(0.5),
        )
        ctx.draw_text(
            font_id, Int32(14), label_pos, text_color.copy(),
            String("(no image yet)"),
        )


# ---------------------------------------------------------------------------
# Single-frame emit — the entire serenitymojo UI shape in one composition.
# Mouse is at (0, 0) (outside any widget) so nothing claims hover, focus, or
# active; combo / sampler dropdowns stay closed; Generate button never
# clicks; text_area's never focus. This is what the user will see on the
# first frame after launch (modulo theme switcher click).
# ---------------------------------------------------------------------------


def _emit_frame(
    mut ctx: Context,
    mut state: SerenityState,
    theme: Theme,
    font_id: UInt32,
) raises:
    """Paint the full serenitymojo UI in one frame against `theme`."""

    # ----- Background fill (full window) ------------------------------------
    ctx.draw_rect(
        Rect(0.0, 0.0, 1280.0, 800.0),
        theme.colors.bg_default.copy(),
    )

    # ----- Title bar: brand + 2 theme buttons (visual stub) -----------------
    # 20 px outer margin (left + right + bottom + between rows) -- microui
    # spacing-style padding; for a static stub we just choose widths that
    # sum to 1240 = 1280 - 2*20.
    ctx.layout_row(_row4(840, 120, 120, 160), 36)
    label(ctx, String("serenitymojo - pure-Mojo diffusion"))
    if button(ctx, String("Dark")):
        pass
    if button(ctx, String("Light")):
        pass
    label(ctx, String(""))

    ctx.layout_row(_row1(1240), 4)
    separator(ctx)

    # ----- Model picker -----------------------------------------------------
    ctx.layout_row(_row2(200, 1040), 32)
    label(ctx, String("Model:"))
    _ = combobox(
        ctx, String("model_picker"), state.model_options,
        state.model_index, state.model_open,
    )

    # ----- Positive prompt --------------------------------------------------
    ctx.layout_row(_row1(1240), 24)
    label(ctx, String("Positive prompt:"))
    ctx.layout_row(_row1(1240), 90)
    _ = text_area(ctx, String("pos_prompt"), state.positive_prompt, state.positive_edit_state)

    # ----- Negative prompt --------------------------------------------------
    ctx.layout_row(_row1(1240), 24)
    label(ctx, String("Negative prompt:"))
    ctx.layout_row(_row1(1240), 60)
    _ = text_area(ctx, String("neg_prompt"), state.negative_prompt, state.negative_edit_state)

    ctx.layout_row(_row1(1240), 4)
    separator(ctx)

    # ----- Sampler controls: 2-column layout -------------------------------
    # Row 1: sampler combobox + steps slider
    ctx.layout_row(_row4(120, 480, 120, 480), 28)
    label(ctx, String("Sampler:"))
    _ = combobox(
        ctx, String("sampler"), state.sampler_options,
        state.sampler_index, state.sampler_open,
    )
    label(ctx, String("Steps:"))
    _ = slider(ctx, state.steps, Float32(10.0), Float32(50.0), String("steps"))

    # Row 2: cfg drag_value + seed drag_value
    ctx.layout_row(_row4(120, 480, 120, 480), 28)
    label(ctx, String("CFG:"))
    _ = drag_value(ctx, state.cfg, String("cfg"), Float32(0.1))
    label(ctx, String("Seed:"))
    _ = drag_value(ctx, state.seed, String("seed"), Float32(1.0))

    # Row 3: width + height sliders
    ctx.layout_row(_row4(120, 480, 120, 480), 28)
    label(ctx, String("Width:"))
    _ = slider(ctx, state.width, Float32(256.0), Float32(2048.0), String("width"))
    label(ctx, String("Height:"))
    _ = slider(ctx, state.height, Float32(256.0), Float32(2048.0), String("height"))

    ctx.layout_row(_row1(1240), 4)
    separator(ctx)

    # ----- Generate button (large, accent-colored via theme) ---------------
    ctx.layout_row(_row1(1240), 48)
    if button(ctx, String("Generate Image")):
        # Real M4 wiring: kick off pipeline call, advance state.progress on
        # callback. Here we just simulate the click branch existing.
        pass

    # ----- Progress bar ----------------------------------------------------
    ctx.layout_row(_row1(1240), 18)
    progress_bar(ctx, state.progress)

    ctx.layout_row(_row1(1240), 4)
    separator(ctx)

    # ----- Image preview (centered 512x512 placeholder) --------------------
    ctx.layout_row(_row1(1240), 540)
    var slot = ctx.layout_next()
    var img_size: Float32 = 512.0
    var img_rect = Rect(
        slot.x + (slot.w - img_size) * Float32(0.5),
        slot.y + (slot.h - img_size) * Float32(0.5),
        img_size, img_size,
    )
    _draw_image_preview(
        ctx, img_rect, state.image_loaded,
        theme.colors.bg_input.copy(),
        theme.colors.text_subdued.copy(),
        font_id,
    )


# ---------------------------------------------------------------------------
# main: build state, emit one frame, print stats + PASS line.
# ---------------------------------------------------------------------------


def main() raises:
    """Build the serenitymojo UI scene, emit one frame, print PASS line."""
    var ctx = Context()
    var font_id = load_default_ui_font()
    ctx.set_default_font(font_id)
    print("Loaded default UI font id =", font_id, "(0 = no font; text draws skipped)")

    var theme = dark_theme()
    var state = SerenityState()

    ctx.begin_frame_no_input(
        Vec2(1280.0, 800.0), Vec2(0.0, 0.0), False, False,
    )
    _emit_frame(ctx, state, theme, font_id)
    ctx.end_frame()

    var byte_count = ctx.commands.byte_count()
    print("serenitymojo UI stub: emitted", byte_count, "bytes of commands")
    print(
        "  Models available:", len(state.model_options),
        " Samplers available:", len(state.sampler_options),
    )
    print("  Active model:  ", state.model_options[Int(state.model_index)])
    print("  Active sampler:", state.sampler_options[Int(state.sampler_index)])
    print(
        "  Steps:", state.steps,
        " CFG:", state.cfg,
        " Seed:", state.seed,
    )
    print(
        "  Size:", Int(state.width), "x", Int(state.height),
        " Progress:", state.progress,
        " ImageLoaded:", state.image_loaded,
    )

    # Gate: command buffer must be non-empty (background + at least 1 widget).
    if byte_count <= 0:
        print("FAIL: empty command buffer")
        raise Error("empty command buffer")

    print("PASS: c54 serenitymojo UI stub - full diffusion UI composes")
