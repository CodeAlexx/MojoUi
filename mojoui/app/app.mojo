"""Canonical MojoUI app model — ONE handler, run as text OR GUI.

Mojo 1.0.0b2 can't store a bare function pointer (so no per-widget callback
fields), but it CAN store a struct and call its method. MojoUI therefore models
an app as a single handler object with one dispatch method:

    trait MojoApp:
        def on_event(mut self, tag: String) raises -> None

You write that one method, switching on the incoming `tag`, and keep app state
in the struct's fields. The SAME handler runs in two modes — you choose the
runner, not the logic:

  * Text mode (headless, fully testable):
      - `run_text(app, cmds)`  — dispatch a scripted list of commands.
      - `run_stdin(app)`       — read stdin lines, dispatch each until a stop
                                 word ("quit"/"exit") or EOF.
    Here `tag` is the typed command line; the handler prints its output.

  * GUI mode (window + widgets): `mojoui.dpg.DpgApp(ctx, app).run()` — the
    handler's `on_event` fires for each interacting widget (tag = widget tag),
    and reaches widget values via `mojoui.dpg.app_ctx[H]()`.

This file owns the trait + text runners. The GUI runner lives in `mojoui/dpg.mojo`
(it couples the handler with a retained `DpgContext`), but binds to THIS trait,
so one handler struct works in both worlds.
"""


trait MojoApp(Movable, ImplicitlyDestructible):
    """The whole app's logic in one method: route `tag` to behavior + state.

    `tag` is a widget tag (GUI mode) or a command line (text mode). Keep state
    in the conforming struct's fields; call your own helper methods freely —
    "one method" means one *dispatch entry point*, not one function total.
    """
    def on_event(mut self, tag: String) raises -> None: ...


def run_text[H: MojoApp](mut app: H, var cmds: List[String]) raises:
    """Dispatch a scripted list of commands through `app.on_event` in order.

    Headless and deterministic — the verifiable form of text mode.
    """
    for i in range(len(cmds)):
        app.on_event(cmds[i])


def run_stdin[H: MojoApp](mut app: H) raises:
    """Read all of stdin, dispatch each non-empty line through `on_event`.

    Stops at a line equal to "quit"/"exit" or at end of input. Reads the whole
    buffer at once (robust under pipes — `input()` raises on its 2nd piped read
    in this toolchain), so it's batch/REPL-style rather than char-interactive.
    """
    var data = String("")
    with open("/dev/stdin", "r") as f:
        data = f.read()
    var lines = data.split("\n")
    for i in range(len(lines)):
        var line = lines[i]
        if line == "quit" or line == "exit":
            break
        if line.byte_length() == 0:
            continue
        app.on_event(String(line))
