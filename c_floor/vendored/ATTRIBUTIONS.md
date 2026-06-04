# Vendored Third-Party Dependencies

This directory contains third-party C headers vendored into MojoUI. All deps
are header-only (STB-style) so no separate build is needed — they get included
directly by `c_floor/src/*.c` with the appropriate `*_IMPL` define in exactly
one translation unit.

Vendored on **2026-05-27**.

---

## sokol (sokol_app, sokol_gfx, sokol_glue, sokol_log)

- **Version:** master @ 2026-05-26 (commit `1dd48f8`)
- **License:** zlib/libpng (see `sokol/LICENSE`)
- **Upstream:** https://github.com/floooh/sokol
- **Files:**
  - `sokol/sokol_app.h` — cross-platform window + input + event loop
  - `sokol/sokol_gfx.h` — cross-platform 3D graphics API (GL/D3D11/Metal/WebGPU)
  - `sokol/sokol_glue.h` — small helpers binding sokol_app to sokol_gfx
  - `sokol/sokol_log.h` — default logging callback used by sokol_app/gfx
- **Why:** Single dependency that provides the window + GPU layer for MojoUI's
  `c_floor`. Chosen over GLFW+bgfx/Dawn for header-only simplicity, MIT-friendly
  zlib license, and unified app/gfx model. See `mojoui-audit/AUDIT_sokol_gfx.md`.

## stb_truetype

- **Version:** v1.26, master @ 2026-04-15 (commit `31c1ad3`)
- **License:** Dual-licensed: MIT OR public domain (Unlicense) — see `stb/LICENSE.txt`
- **Upstream:** https://github.com/nothings/stb
- **Files:**
  - `stb/stb_truetype.h` — TrueType font parsing + glyph rasterization
- **Why:** Atlas-baking backend for MojoUI's text rendering. Public-domain
  single-header, no dependencies, used by every roguelike/game UI ever shipped.
  See `mojoui-audit/AUDIT_mojogui_c.md` (font section).

---

## NOT vendored (intentionally deferred)

- **sokol-shdc** — for M0 we inline GLSL/MSL shader source directly in
  `mojoui_render.c` rather than pre-compiling with sokol-shdc. The
  `sokol_shdc_out/` directory is kept as an empty placeholder for later
  multi-backend shader compilation.
