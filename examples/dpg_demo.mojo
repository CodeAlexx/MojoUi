"""DearPyGui-style retained API over MojoUI — dpg_demo (compile-verified).

Builds a tagged item tree once, then runs an interactive frame loop that reacts
to events and updates values by tag — the DearPyGui ergonomic, adapted to Mojo
1.0.0b2 (per-widget runtime callbacks aren't storable here, so interaction is an
events queue polled inside one top-level frame fn; see mojoui/dpg.mojo).

Build (acceptance gate — JIT can't dlopen the C floor, so build-then-run):
  pixi run mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
    examples/dpg_demo.mojo -o /tmp/dpg_demo
  LD_LIBRARY_PATH=. /tmp/dpg_demo        # needs a live display to render
"""

from mojoui import dpg
from mojoui.dpg import DpgContext


def _frame() -> None:
    """Top-level frame fn: render the retained items, then react to events.

    This is the DearPyGui callback substitute — one place that runs every frame,
    reaching the live context via `dpg.active()` (no closures needed).
    """
    try:
        var p = dpg.active()
        p[].render_frame()

        # React to button clicks by tag (the events queue replaces callbacks).
        if p[].consume_event(String("inc")):
            var c = p[].get_value_float(String("count"))
            p[].set_value_float(String("count"), c + 1.0)
            p[].set_value_str(String("status"), String("clicked +1"))

        if p[].consume_event(String("reset")):
            p[].set_value_float(String("count"), 0.0)
            p[].set_value_str(String("status"), String("reset"))

        # Slider / checkbox changes also arrive as events (same polling path).
        if p[].consume_event(String("gain")):
            var g = p[].get_value_float(String("gain"))
            p[].set_value_str(String("status"), String("gain=") + String(g))

        if p[].consume_event(String("mute")):
            var m = p[].get_value_bool(String("mute"))
            var msg = String("muted") if m else String("unmuted")
            p[].set_value_str(String("status"), msg^)
    except e:
        print("dpg_demo frame error:", String(e))


def main() raises:
    var ctx = DpgContext(String("MojoUI dpg demo"), 720, 480)

    # Build the retained tree once, addressing widgets by tag.
    ctx.add_text(String("title"), String("DearPyGui-style demo (MojoUI)"))
    ctx.add_separator()
    ctx.add_button(String("inc"), String("Increment"))
    ctx.add_button(String("reset"), String("Reset"))
    ctx.add_slider_float(String("gain"), String("Gain"), 0.5, 0.0, 1.0)
    ctx.add_checkbox(String("mute"), String("Mute"), False)
    ctx.add_separator()
    ctx.add_text(String("count"), String("0"))   # display tag for the counter
    ctx.add_text(String("status"), String("ready"))

    # Pre-frame values readable/writable by tag from anywhere.
    ctx.set_value_float(String("count"), 0.0)

    # Interactive run: our top-level _frame reacts each frame.
    dpg.run(ctx, _frame)
