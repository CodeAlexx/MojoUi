"""One handler, two modes — the canonical MojoUI app model (dual_mode_app).

The SAME `Calc` struct (one `on_event` method) runs as a terminal program OR a
GUI window. You pick the runner, not the logic:

  Text mode (headless, fully runnable here):
    pixi run mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
      examples/dual_mode_app.mojo -o /tmp/dual
    printf 'add 5\nadd 3\nsub 2\nshow\n' | /tmp/dual          # default: text

  GUI mode (needs a display): pass 'gui' as argv[1]:
    LD_LIBRARY_PATH=. /tmp/dual gui

`on_event(tag)` receives a command line in text mode and a widget tag in GUI
mode — same dispatch, same state (`self.total`).
"""

from std.sys import argv
from mojoui.app.app import MojoApp, run_stdin
from mojoui.dpg import DpgContext, DpgApp, app_ctx, is_gui_live


struct Calc(MojoApp):
    var total: Float32

    def __init__(out self):
        self.total = 0.0

    def on_event(mut self, tag: String) raises -> None:
        # GUI tags (no spaces) and text commands (verb + number) share one path.
        if tag == "inc":                         # GUI button
            self.total += 1.0
        elif tag == "reset" or tag == "clear":   # GUI button / text cmd
            self.total = 0.0
        elif tag == "show":                      # text cmd
            pass
        elif tag.startswith("add "):             # text cmd: "add 5"
            self.total += _num(tag, 4)
        elif tag.startswith("sub "):             # text cmd: "sub 2"
            self.total -= _num(tag, 4)
        else:
            print("? ", tag)
            return
        self._report()

    def _report(self) raises -> None:
        # ONE mode-safe sink: update GUI widgets if a window is live, else print.
        # is_gui_live guards the app_ctx deref so text mode never faults.
        if is_gui_live[Calc]():
            var c = app_ctx[Calc]()
            c[].set_value_float(String("total"), self.total)
            c[].set_value_str(String("status"), String("total=") + String(self.total))
        else:
            print("total =", self.total)


def _num(s: String, start: Int) raises -> Float32:
    # parse the trailing number after a known prefix length
    var rest = String("")
    var b = s.as_bytes()
    for i in range(start, s.byte_length()):
        rest += chr(Int(b[i]))
    return Float32(atof(rest)) if rest.byte_length() > 0 else Float32(0.0)


def _build_gui() raises:
    var ctx = DpgContext(String("Calc (GUI)"), 640, 360)
    ctx.add_text(String("title"), String("Same handler, GUI mode"))
    ctx.add_separator()
    ctx.add_button(String("inc"), String("+1"))
    ctx.add_button(String("reset"), String("Reset"))
    ctx.add_separator()
    ctx.add_text(String("total"), String("0"))
    ctx.add_text(String("status"), String("ready"))
    ctx.set_value_float(String("total"), 0.0)
    var app = DpgApp(ctx^, Calc())
    app.run()


def main() raises:
    var args = argv()
    var mode = String(args[1]) if len(args) > 1 else String("text")
    if mode == "gui":
        _build_gui()
    else:
        var calc = Calc()
        run_stdin(calc)
        print("final total =", calc.total)
