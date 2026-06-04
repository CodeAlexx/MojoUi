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

The build assumes Linux with OpenGL 3.3 (`-DSOKOL_GLCORE`). Other backends (Metal, D3D11, Vulkan, WebGPU) compile by changing the SOKOL define in `c_floor/Makefile` — not yet validated.

## License

MIT - see [LICENSE](LICENSE).
