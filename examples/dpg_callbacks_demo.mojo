"""Real per-tag callbacks over MojoUI — dpg_callbacks_demo (compile-verified).

Mojo 1.0.0b2 can't store a bare function pointer per widget, but it CAN store a
struct and call its method. So the DearPyGui callback model is delivered as one
handler struct whose `on_event(tag)` routes interactions — dispatched by Mojo at
runtime. This is a genuine callback, not event-polling.

Build (acceptance gate — JIT can't dlopen the C floor, so build-then-run):
  pixi run mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
    examples/dpg_callbacks_demo.mojo -o /tmp/dpg_cb
  LD_LIBRARY_PATH=. /tmp/dpg_cb        # needs a live display to render
"""

from mojoui.dpg import DpgContext, DpgApp, app_ctx
from mojoui.app.app import MojoApp


struct Counter(MojoApp):
    """The whole app's callback router: one method, switch on the sender tag."""
    var clicks: Int

    def __init__(out self):
        self.clicks = 0

    def on_event(mut self, tag: String) raises -> None:
        # Reach the live value store to read/write widgets by tag.
        var c = app_ctx[Counter]()
        if tag == "inc":
            self.clicks += 1
            c[].set_value_float(String("count"), Float32(self.clicks))
            c[].set_value_str(String("status"), String("clicked +1"))
        elif tag == "reset":
            self.clicks = 0
            c[].set_value_float(String("count"), 0.0)
            c[].set_value_str(String("status"), String("reset"))
        elif tag == "gain":
            var g = c[].get_value_float(String("gain"))
            c[].set_value_str(String("status"), String("gain=") + String(g))
        elif tag == "mute":
            var m = c[].get_value_bool(String("mute"))
            c[].set_value_str(String("status"), String("muted") if m else String("unmuted"))


def main() raises:
    var ctx = DpgContext(String("MojoUI dpg callbacks"), 720, 480)
    ctx.add_text(String("title"), String("Real callbacks (handler.on_event)"))
    ctx.add_separator()
    ctx.add_button(String("inc"), String("Increment"))
    ctx.add_button(String("reset"), String("Reset"))
    ctx.add_slider_float(String("gain"), String("Gain"), 0.5, 0.0, 1.0)
    ctx.add_checkbox(String("mute"), String("Mute"), False)
    ctx.add_separator()
    ctx.add_text(String("count"), String("0"))
    ctx.add_text(String("status"), String("ready"))
    ctx.set_value_float(String("count"), 0.0)

    # Couple the retained UI with the handler and run — on_event fires per tag.
    var app = DpgApp(ctx^, Counter())
    app.run()
