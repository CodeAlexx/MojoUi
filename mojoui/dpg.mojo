"""DearPyGui-style RETAINED façade over MojoUI's immediate core (mojoui/dpg.mojo).

DearPyGui exposes a retained API (build a tagged widget tree once, read/write
values by tag, react to interaction) over an immediate-mode core (Dear ImGui).
This brings the same ergonomics to MojoUI:

  * Build items once with **tags**: `add_button(tag, text)`,
    `add_slider_float(tag, text, default)`, `add_checkbox(...)`, `add_text(...)`.
  * Read/write widget state from anywhere by tag: `get_value_float(tag)` /
    `set_value_float(tag, x)` (+ bool/str). A live context is reachable via
    `active()` (the same `retrieve_user_state` the frame loop uses), so you can
    mutate values from inside your own frame function with no closures.

Callbacks — the honest limitation
---------------------------------
DearPyGui stores a per-widget callback (a runtime function value) in the
retained tree and dispatches it on interaction. Mojo 1.0.0b2 has **no
runtime-storable, Mojo-callable function type**: a function value can only be a
compile-time parameter (not invokable indirectly here) or handed to C (never
called back into Mojo). So per-widget callback *storage* is not possible in this
toolchain. Instead, interaction is surfaced as a per-frame **events queue**:
each frame, `render_frame` records the tags that fired, and you react by polling
`consume_event(tag)` / `take_events()` inside your own frame function. This is
the same single-top-level-frame-fn pattern MojoUI's own examples use.

Two ways to run
---------------
  * `dpg.start(ctx)` — display-only: walks the items every frame, no reactions.
  * `dpg.run(ctx, my_frame)` — interactive: you pass a top-level
    `def my_frame() -> None` that calls `active()[].render_frame()` then reacts
    to events / updates values. `my_frame` is forwarded to the C frame loop the
    same way MojoUI's `_frame` is (Mojo never calls it — sokol does).

Verification note: this COMPILES against libmojoui_floor.so (the acceptance gate
MojoUI's own examples use). Rendering the window needs a live display.
"""

from std.memory import UnsafePointer
from std.builtin.type_aliases import MutAnyOrigin

from mojoui.core.types import Color
from mojoui.core.context import Context
from mojoui.render.backend import Backend
from mojoui.render.command_renderer import render_context_commands
from mojoui.widgets.basic import button, label, separator
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.slider import slider
from mojoui.app.state import store_user_state, retrieve_user_state


comptime DPG_LABEL: Int = 0
comptime DPG_BUTTON: Int = 1
comptime DPG_SLIDER: Int = 2
comptime DPG_CHECKBOX: Int = 3
comptime DPG_SEPARATOR: Int = 4


struct DpgItem(Copyable, Movable):
    var kind: Int
    var tag: String
    var text: String      # button caption / slider label / checkbox label
    var fmin: Float32
    var fmax: Float32
    var height: Int32
    var width: Int32

    def __init__(
        out self,
        kind: Int,
        tag: String,
        text: String,
        fmin: Float32,
        fmax: Float32,
        height: Int32,
        width: Int32,
    ):
        self.kind = kind
        self.tag = tag
        self.text = text
        self.fmin = fmin
        self.fmax = fmax
        self.height = height
        self.width = width

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.tag = copy.tag
        self.text = copy.text
        self.fmin = copy.fmin
        self.fmax = copy.fmax
        self.height = copy.height
        self.width = copy.width


struct DpgContext(Movable):
    var items: List[DpgItem]
    var floats: Dict[String, Float32]
    var bools: Dict[String, Bool]
    var strs: Dict[String, String]
    var events: List[String]          # tags that fired this frame (poll/consume)
    var title: String
    var width: Int32
    var height: Int32
    var font_id: UInt32

    def __init__(out self, title: String, width: Int32 = 800, height: Int32 = 600):
        self.items = List[DpgItem]()
        self.floats = Dict[String, Float32]()
        self.bools = Dict[String, Bool]()
        self.strs = Dict[String, String]()
        self.events = List[String]()
        self.title = title
        self.width = width
        self.height = height
        self.font_id = 0

    # ---- retained builders ----
    def add_text(mut self, tag: String, text: String) raises:
        self.strs[tag] = text
        self.items.append(DpgItem(DPG_LABEL, tag, text, 0.0, 0.0, 24, 600))

    def add_button(mut self, tag: String, text: String):
        self.items.append(DpgItem(DPG_BUTTON, tag, text, 0.0, 0.0, 32, 200))

    def add_slider_float(
        mut self, tag: String, text: String, default: Float32,
        fmin: Float32 = 0.0, fmax: Float32 = 1.0,
    ) raises:
        self.floats[tag] = default
        self.items.append(DpgItem(DPG_SLIDER, tag, text, fmin, fmax, 32, 400))

    def add_checkbox(mut self, tag: String, text: String, default: Bool) raises:
        self.bools[tag] = default
        self.items.append(DpgItem(DPG_CHECKBOX, tag, text, 0.0, 0.0, 28, 300))

    def add_separator(mut self):
        self.items.append(DpgItem(DPG_SEPARATOR, String(""), String(""), 0.0, 0.0, 8, 600))

    # ---- tag-keyed value store (DearPyGui get_value / set_value) ----
    def get_value_float(self, tag: String) raises -> Float32:
        return self.floats[tag]

    def set_value_float(mut self, tag: String, v: Float32) raises:
        self.floats[tag] = v

    def get_value_bool(self, tag: String) raises -> Bool:
        return self.bools[tag]

    def set_value_bool(mut self, tag: String, v: Bool) raises:
        self.bools[tag] = v

    def get_value_str(self, tag: String) raises -> String:
        return self.strs[tag]

    def set_value_str(mut self, tag: String, v: String) raises:
        self.strs[tag] = v

    # ---- per-frame events (the callback substitute) ----
    def consume_event(mut self, tag: String) -> Bool:
        """True if `tag` fired this frame; removes it so it fires once."""
        for i in range(len(self.events)):
            if self.events[i] == tag:
                _ = self.events.pop(i)
                return True
        return False

    def take_events(mut self) -> List[String]:
        """Move out all tags that fired this frame (clears the queue)."""
        var out = self.events^
        self.events = List[String]()
        return out^

    # ---- per-frame immediate-mode walk over the retained items ----
    def render_frame(mut self) raises:
        if self.font_id == 0:
            self.font_id = Backend.load_font(String(""))

        self.events = List[String]()   # fresh event queue each frame

        var bg = Color(UInt8(31), UInt8(31), UInt8(36), UInt8(255))
        Backend.frame_begin(bg^)
        var ctx = Context()
        ctx.set_default_font(self.font_id)
        var win = Backend.window_size()
        ctx.begin_frame(win.copy())

        var n = len(self.items)
        for i in range(n):
            var it = self.items[i].copy()   # release the items borrow
            var widths = List[Int32]()
            widths.append(it.width)
            ctx.layout_row(widths^, it.height)

            if it.kind == DPG_LABEL:
                label(ctx, self.strs[it.tag])
            elif it.kind == DPG_SEPARATOR:
                separator(ctx)
            elif it.kind == DPG_BUTTON:
                if button(ctx, it.text):
                    self.events.append(it.tag)
            elif it.kind == DPG_SLIDER:
                var v = self.floats[it.tag]
                if slider(ctx, v, it.fmin, it.fmax, it.tag):
                    self.floats[it.tag] = v
                    self.events.append(it.tag)
            elif it.kind == DPG_CHECKBOX:
                var b = self.bools[it.tag]
                if checkbox(ctx, it.text, b):
                    self.bools[it.tag] = b
                    self.events.append(it.tag)

        ctx.end_frame()
        _ = render_context_commands(ctx, String("dpg"))
        Backend.frame_end()


def _dpg_frame() -> None:
    """Display-only frame callback used by `start`: render, no reactions."""
    var state_ptr = retrieve_user_state[DpgContext]()
    try:
        state_ptr[].render_frame()
    except e:
        print("mojoui.dpg frame error:", String(e))


def start(mut ctx: DpgContext) raises:
    """Run the window, walking the retained items every frame (no reactions).

    For interactive apps that react to events / update values, use `run` with
    your own top-level frame function instead.
    """
    store_user_state(UnsafePointer(to=ctx))
    _ = Backend.init(ctx.width, ctx.height, ctx.title)
    Backend.run_blocking(_dpg_frame)


def run[FrameFn: AnyType, //](mut ctx: DpgContext, frame_fn: FrameFn) raises:
    """Run the window with a user-supplied top-level `def frame_fn() -> None`.

    `frame_fn` should call `active()[].render_frame()`, then poll
    `consume_event` / `take_events` and update values via `set_value_*`.
    It is forwarded to the C frame loop exactly as MojoUI's own `_frame` is
    (Mojo never calls it — sokol does), which is why per-frame user logic is
    expressed as one top-level function rather than per-widget callbacks.
    """
    store_user_state(UnsafePointer(to=ctx))
    _ = Backend.init(ctx.width, ctx.height, ctx.title)
    Backend.run_blocking(frame_fn)


def active() raises -> UnsafePointer[DpgContext, MutAnyOrigin]:
    """Reach the live context from anywhere (e.g. inside your frame function)."""
    return retrieve_user_state[DpgContext]()
