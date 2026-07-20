# MojoUI

A general-purpose Mojo immediate-mode GUI library with a retained-mode node graph, vector-first rendering, and a modern native stack (sokol_gfx + stb_truetype). Designed to serve as the UI layer for serenitymojo and future Mojo applications, with a clean separation between an immediate-mode API surface, a persistent scene/node graph, and a thin C floor for windowing, GPU, and font rasterization.

## Status

Alpha v0.1.0 - currently in the **M0** (milestone zero) phase: scaffolding the project, vendoring the C floor (sokol + stb), wiring the Mojo FFI bindings, and bringing up a "hello triangle / hello text" demo.

## Quick start

The M0 "hello world" demo opens an 800×600 window with a centered "Hello, MojoUI" at 24pt over a purple accent rectangle on dark gray. The C floor (sokol_app + sokol_gfx + stb_truetype) must build first; then the Mojo example runs via `pixi`:

```bash
git clone https://github.com/CodeAlexx/MojoUi.git
cd MojoUi
pixi install       # one-time: provisions Mojo 1.0.0b2 + system OpenGL/X11 dev libs
pixi run build     # compiles c_floor/*.c -> libmojoui_floor.so in this dir
pixi run interactive  # ★ FLAGSHIP DEMO (c53) — first interactive MojoUI binary.
                   # Opens a real 800x600 window with mouse + keyboard input and
                   # persistent state across frames (the c50 user_data extension
                   # threads an `AppState{counter, theme_idx, slider}` through
                   # the no-arg sokol frame callback). 3 theme-switcher buttons
                   # (dark / light / high_contrast — c47) swap the palette live;
                   # counter button bumps an Int32; slider scrubs a Float32;
                   # Tab/Shift-Tab cycles keyboard focus (c52). Close window to
                   # exit; prints final counter / theme_idx / slider so you can
                   # confirm the in-window state round-tripped through
                   # user_data back into main()'s stack-allocated AppState.
pixi run hello     # opens the M0 window; close it with the X to exit
pixi run m1        # M1 demo: 3-frame static walk of Context + button + label
                   # (built binary, not JIT — see examples/m1_button.mojo
                   #  docstring for the JIT-vs-build divergence story)
pixi run gallery   # M2 capstone: single-frame kitchen-sink walk-through of every
                   # M2 widget (button/label/separator/checkbox/radio/slider/
                   # drag_value/progress_bar/image/text_edit/text_area/combobox/
                   # collapsing_header/scroll_area/window_panel). Prints per-CMD-
                   # kind counts + PASS line. Built (NOT JIT) — same reason as m1.
pixi run nodes     # M2.5 capstone: builds a 6-node ComfyUI workflow (LoadCheckpoint
                   # -> EncodePrompt × 2 -> KSampler -> VAEDecode -> SaveImage),
                   # topo-sorts, emits JSON via `emit_workflow`, parses back via
                   # `parse_workflow`, verifies byte-equivalent round-trip, and
                   # renders one static canvas frame at 1280×720. Composes every
                   # M2.5 chunk (Node + Port + JSON + VersionPeek + Graph +
                   # NodeRegistry + Wires + NodeCanvas + AddMenu + workflow serde).
pixi run themed    # M3 capstone: cycles dark / light / high_contrast themes (c47),
                   # one 800x600 frame per theme exercising tessellator (rounded
                   # rect + drop shadow + circle; c46), animation (ease_out_cubic
                   # + spring_step; c45), typography (load_default_ui_font; c44),
                   # and design tokens (c43). Built with `-Xlinker -lm` because
                   # the tessellator uses std.math sin/cos.
pixi run serenity_ui  # M4 PREVIEW (c54): static single-frame stub of the
                   # serenitymojo diffusion app UI — title bar + theme switcher
                   # + model picker (Z-Image / FLUX / Klein9B / SD3 / SDXL /
                   # HiDream) + positive + negative text_area prompts + sampler
                   # controls (sampler combobox + steps/width/height sliders +
                   # cfg/seed drag_value) + large Generate button + progress bar
                   # + 512x512 tess_rounded_rect image preview. Proves the
                   # MojoUI widget catalog covers every surface a diffusion app
                   # needs; the actual `zimage_pipeline` hookup + live window
                   # land in the real M4 chunk. Built with `-Xlinker -lm`.
```

Screenshot placeholder (added once `docs/m0_hello.png` is captured): the window shows `Hello, MojoUI` centered over a 320×140 muted-purple rectangle on a `RGB(24, 24, 28)` background.

Other pixi tasks:

```bash
pixi run test           # full regression — 22 PASS lines across core+widgets
pixi run test-types     # core/types.mojo smoke tests (Vec2/Rect/Color)
pixi run test-ffi       # render/ffi.mojo smoke (FFI imports + key constants)
pixi run test-backend   # render/backend.mojo smoke (color packing + tessellation + API surface)
```

## Serenity inference bridge

`mojoui/app/inference_graph_bridge.mojo` includes a nonblocking pure-Mojo LTX2
video route for SerenityUI. `LTX2 Fast` launches the already-built
`mojodiffusion/output/bin/ltx2_video_smoke_runner`, carries one selected LoRA
name and weight from `InferenceState`, and polls the runner log without blocking
the render thread. The shared status bar reports `loading model`,
`step x of 8`, `decoding video`, and the final MP4 path. Focused gates:

```bash
pixi run test-inference-model
pixi run test-inference-graph-bridge
```

The build assumes Linux with OpenGL 3.3 (`-DSOKOL_GLCORE`). Other backends (Metal, D3D11, Vulkan, WebGPU) compile by changing the SOKOL define in `c_floor/Makefile` — not yet validated.

## App model — one handler, text **or** GUI

MojoUI apps are written as **one handler struct with a single dispatch method**,
and the same handler runs either as a terminal program or a GUI window — you pick
the runner, not the logic. This is also the DearPyGui-style façade (`mojoui/dpg.mojo`):
build a tagged widget tree once, read/write widget state by tag, and react to
interaction through the handler.

```mojo
from mojoui.app.app import MojoApp, run_text, run_stdin
from mojoui.dpg import DpgContext, DpgApp, app_ctx, is_gui_live

struct Calc(MojoApp):
    var total: Float32
    def __init__(out self): self.total = 0.0

    # The whole app's logic — switch on the tag (a widget tag in GUI mode,
    # a command line in text mode). Call your own helper methods freely;
    # "one method" means one *dispatch entry point*, not one function total.
    def on_event(mut self, tag: String) raises -> None:
        if tag == "inc": self.total += 1.0
        elif tag == "reset" or tag == "clear": self.total = 0.0
        elif tag.startswith("add "): self.total += atof(tag[4:])
        self._report()

    def _report(self) raises -> None:
        if is_gui_live[Calc]():                 # GUI live? update widgets
            var c = app_ctx[Calc]()
            c[].set_value_float(String("total"), self.total)
        else:                                   # text mode: just print
            print("total =", self.total)

def main() raises:
    # TEXT mode (headless, fully runnable):
    var calc = Calc(); run_stdin(calc)          # or run_text(calc, [..cmds..])

    # GUI mode (needs a display):
    # var ctx = DpgContext(String("Calc"), 640, 360)
    # ctx.add_button(String("inc"), String("+1"))
    # ctx.add_text(String("total"), String("0"))
    # DpgApp(ctx^, Calc()).run()
```

### Why one method (the language constraint)
Mojo 1.0.0b2 cannot store a bare function value (no per-widget function-pointer
callbacks): a `def`/`fn` value is only a compile-time parameter or a value handed
to C — never a Mojo-callable struct field. It **can** store a struct and call its
method. So MojoUI dispatches through one handler object (`trait MojoApp`) instead
of N free callbacks — same capability, organized as one `on_event` switch.

### Text-mode runners (`mojoui/app/app.mojo`)
- `run_text(app, cmds)` — dispatch a scripted `List[String]` of commands (deterministic, headless).
- `run_stdin(app)` — read stdin, dispatch each non-empty line until `quit`/`exit`/EOF.
  (Reads the whole buffer at once: `input()` raises on its 2nd piped read in this toolchain.)

### GUI runner (`mojoui/dpg.mojo`)
- `DpgApp(ctx, handler).run()` — walks the retained items each frame and dispatches
  every fired widget tag to `handler.on_event` (true runtime callbacks).
- Retained builders: `add_button` / `add_slider_float` / `add_checkbox` / `add_text` / `add_separator`.
- Value store by tag: `get_value_float`/`bool`/`str` + `set_value_*`.

### Mode-safety contract (no segfaults)
GUI-only accessors must not be dereferenced in text mode, where no GUI app is
stored (`retrieve_user_state` returns a NULL slot — dereferencing it would
segfault). Two guards make this safe:
- `is_gui_live[H]()` — `True` only when a `DpgApp[H]` is running; check it before `app_ctx`.
- `app_ctx[H]()` — null-checks the slot and **raises** (does not fault) when no GUI
  app is live, so an unguarded call in text mode is catchable, not a crash.

### Examples
```bash
# build-then-run (the JIT can't dlopen the C floor)
pixi run mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
  examples/dual_mode_app.mojo -o /tmp/dual
printf 'add 5\nadd 3\nsub 2\nshow\nquit\n' | /tmp/dual   # text mode (runs headless)
LD_LIBRARY_PATH=. /tmp/dual gui                          # GUI mode (needs a display)
```
- `examples/dual_mode_app.mojo` — one `Calc` handler, text **and** GUI.
- `examples/dpg_callbacks_demo.mojo` — handler callbacks per widget tag.
- `examples/dpg_demo.mojo` — the events-poll variant (`consume_event`/`take_events`).

## Audio playback

The C floor includes a small **ALSA** backend (`c_floor/mojoui_audio.c`, linked
`-lasound`) exposed via `mojoui.audio.playback`: open the default device, write
interleaved **float32** samples, drain, shutdown. Pairs with MOJO-libs
[`audio`](https://github.com/CodeAlexx/MOJO-libs) (`read_wav` / generated
samples) to play model-generated or reference audio (e.g. LTX2 / NAVA output).

```mojo
from mojoui.audio.playback import play_samples
from audio.wav import read_wav            # MOJO-libs (build with -I /path/to/MOJO-libs)

var buf = read_wav(String("clip.wav"))
var rc = play_samples(buf.samples, buf.rate, buf.channels)   # blocking; 0 = ok, <0 = ALSA error
```

`audio_write` is **blocking** (returns once samples are queued), so `play_samples`
plays a whole buffer synchronously; chunked UI-thread / A-V-synced playback is a
later refinement. See `examples/audio_play_demo.mojo` (no arg = 440 Hz tone; a
path = play a WAV). **Verified**: builds + links + runs with `rc=0` (init/write/
drain/shutdown, no crash) on a box with an ALSA device — audible output is
confirmed on your speakers, not headlessly.

## License

MIT - see [LICENSE](LICENSE).
