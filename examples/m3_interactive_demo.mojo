"""MojoUI c53 — FIRST INTERACTIVE DEMO.

The first MojoUI binary that opens a REAL window AND maintains MUTABLE
per-frame state across the sokol_app event loop, via the c50 user_data
extension to thread an `AppState` pointer through the no-arg frame callback.

Live in this demo: 3 theme-switcher buttons (dark / light / high_contrast,
c47), a counter button, a slider, and Tab / Shift-Tab focus cycling (c52).

Build + run: `pixi run interactive`. Build-then-run shape (NOT `mojo run`):
the JIT can't dlopen libmojoui_floor.so, so the binary links against it via
`-Xlinker -L. -Xlinker -lmojoui_floor`. Extra `-Xlinker -lm` per c49 because
the tessellator's sin/cos link against `sincosf` from libm.

Architecture (the c50 canonical pattern):
  * `AppState` lives on `main`'s stack for the lifetime of run_blocking.
  * `main` calls `store_user_state(UnsafePointer(to=state))` BEFORE
    `Backend.run_blocking(_frame)`.
  * `_frame` recovers the typed pointer via `retrieve_user_state[AppState]()`
    and writes back via `state_ptr[].field = ...` — those writes propagate
    to main()'s stack slot directly (no copy).
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_CLIP, CMD_RECT, CMD_TEXT, CMD_ICON, CMD_IMAGE,
    CMD_TRIANGLES,
    CmdTriangles,
    read_cmd_rect, read_cmd_text, read_cmd_triangles,
)
from mojoui.render.backend import Backend
from mojoui.render.command_renderer import render_context_commands
from mojoui.theme.tokens import Theme
from mojoui.theme.themes import dark_theme, light_theme, high_contrast_theme
from mojoui.theme.typography import load_default_ui_font
from mojoui.widgets.basic import button, label
from mojoui.widgets.slider import slider
from mojoui.app.state import store_user_state, retrieve_user_state


struct AppState:
    """Per-frame mutable demo state. Stack-allocated in main(); pointer
    stashed via c50 store_user_state before run_blocking. Fields:
    counter (Int32, click-button bump), current_theme_index (Int32; 0=dark,
    1=light, 2=high_contrast — theme-switcher buttons write), slider_value
    (Float32 in [0,1] from the slider widget).
    """

    var counter: Int32
    var current_theme_index: Int32
    var slider_value: Float32
    var font_id: UInt32              # 0 until first-frame lazy-load (Bug 1 fix)

    def __init__(out self):
        self.counter = 0
        self.current_theme_index = 0
        self.slider_value = 0.5
        self.font_id = 0


def _theme_for_index(idx: Int32) -> Theme:
    """Dispatch AppState.current_theme_index → c47 Theme factory; unknown
    falls back to dark (matches `theme_for_name`). Returned Theme is owned;
    downstream Color reads need `.copy()` per c15 ImplicitlyCopyable rule.
    """
    if idx == 1:
        return light_theme()
    elif idx == 2:
        return high_contrast_theme()
    return dark_theme()


def _dispatch_triangles(mut cmd: CmdTriangles):
    """Drain a CmdTriangles into Backend.draw_batch_lists.

    Uses `take_verts` / `take_indices` (CmdTriangles methods that move the
    List fields out and reset them to empty) so the struct stays in a
    consistent state for the compiler-inserted destructor — avoids the
    "partial destroy" borrow-checker wall that fires when ^-moving heap
    fields out of a Movable-only struct alongside a scalar field read.
    """
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    _ = Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    """Render through the shared live command-buffer adapter."""
    _ = render_context_commands(ctx, String("MojoUI m3"))


def _frame() -> None:
    """No-arg sokol_app frame callback. Recovers AppState via c50, builds
    one immediate-mode frame (title, theme buttons, counter, slider, help),
    renders the command buffer to GPU, presents.

    Must match `void (*)(void)` (no raises). UnsafePointer is non-nullable
    in current beta (current Mojo beta behavior) — the c50 contract guarantees
    store_user_state was called in main before run_blocking, so no NULL guard.
    """
    var state_ptr = retrieve_user_state[AppState]()

    # Bug 1 fix: lazy-load the font on first frame. Pre-fix, main() called
    # load_default_ui_font() BEFORE sapp_run started → no GL context →
    # mojoui_make_texture failed → font_id=0. The GL context is live by the
    # time _frame() fires, so the load succeeds here. Cache in AppState so
    # we only call load_font once.
    if state_ptr[].font_id == 0:
        state_ptr[].font_id = Backend.load_font(String(""))

    var theme_idx = state_ptr[].current_theme_index
    var slider_val = state_ptr[].slider_value
    var current_theme = _theme_for_index(theme_idx)
    var bg = current_theme.colors.bg_default.copy()

    Backend.frame_begin(bg^)

    var ctx = Context()
    ctx.set_default_font(state_ptr[].font_id)

    var win = Backend.window_size()
    ctx.begin_frame(win.copy())

    # Title.
    var title_widths = List[Int32]()
    title_widths.append(Int32(600))
    ctx.layout_row(title_widths^, Int32(32))
    label(ctx, String("MojoUI c53 -- Interactive Demo"))

    # Theme switcher row.
    var theme_widths = List[Int32]()
    theme_widths.append(Int32(150))
    theme_widths.append(Int32(150))
    theme_widths.append(Int32(200))
    ctx.layout_row(theme_widths^, Int32(36))
    if button(ctx, String("Dark theme")):
        state_ptr[].current_theme_index = Int32(0)
    if button(ctx, String("Light theme")):
        state_ptr[].current_theme_index = Int32(1)
    if button(ctx, String("High contrast")):
        state_ptr[].current_theme_index = Int32(2)

    # Counter row — bump THEN read so the in-frame label reflects the new
    # value (same pattern as m1_button's _simulate_frame per FRAGILE #7).
    var counter_widths = List[Int32]()
    counter_widths.append(Int32(200))
    counter_widths.append(Int32(300))
    ctx.layout_row(counter_widths^, Int32(36))
    if button(ctx, String("Click me!")):
        state_ptr[].counter = state_ptr[].counter + Int32(1)
    var counter_msg = (
        String("Clicked ") + String(state_ptr[].counter) + String(" times")
    )
    label(ctx, counter_msg^)

    # Slider row. slider() takes `mut value: Float32`; we copy out before,
    # then write back if changed=True.
    var slider_widths = List[Int32]()
    slider_widths.append(Int32(400))
    ctx.layout_row(slider_widths^, Int32(32))
    if slider(ctx, slider_val, Float32(0.0), Float32(1.0), String("demo_slider")):
        state_ptr[].slider_value = slider_val

    # Slider readout.
    var val_widths = List[Int32]()
    val_widths.append(Int32(400))
    ctx.layout_row(val_widths^, Int32(24))
    var val_msg = String("Slider value: ") + String(slider_val)
    label(ctx, val_msg^)

    # Help text — c52 Tab/Shift-Tab keyboard cycle.
    var help_widths = List[Int32]()
    help_widths.append(Int32(600))
    ctx.layout_row(help_widths^, Int32(24))
    label(ctx, String("Tab / Shift-Tab cycles focus | close window to exit"))

    ctx.end_frame()

    # _render_command_buffer raises (it calls read_cmd_triangles which
    # raises on a kind mismatch — defensively, since the walker only calls
    # it after verifying kind == CMD_TRIANGLES). _frame() must match the
    # void (*)(void) C ABI of sokol_app's frame_cb, so it cannot itself be
    # `raises`. Swallow the raise via try/except — any kind-mismatch in
    # this walker is a programmer error and we surface it via print only.
    try:
        _render_command_buffer(ctx)
    except e:
        print("MojoUI walker error:", String(e))
    Backend.frame_end()


def main() raises:
    """Open window, hand off AppState pointer, run the blocking event loop.

    AppState lives on main's stack; pointer stashed via store_user_state
    BEFORE run_blocking (lifetime contract: pointer valid till sapp_run
    returns). Backend.init fills sapp_desc; GL context comes up inside
    sapp_run via the c10 platform_init_cb -> mojoui_render_init wiring.
    Closes by user clicking the X (Backend.run_blocking returns).
    """
    var state = AppState()
    var state_ptr = UnsafePointer(to=state)
    store_user_state(state_ptr)

    var rc = Backend.init(
        Int32(800), Int32(600), String("MojoUI Interactive Demo")
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    # Bug 1 fix: do NOT eagerly load the font here — GL context isn't live
    # until sapp_run starts (inside run_blocking). The font is lazy-loaded
    # on the first frame inside _frame() via state.font_id == 0 check.
    print("Opening window — font loads lazily on first frame.")

    Backend.run_blocking(_frame)

    print(
        "PASS: c53 interactive demo exited cleanly. Final counter =",
        Int(state.counter),
        "theme_idx =",
        Int(state.current_theme_index),
        "slider =",
        state.slider_value,
    )
