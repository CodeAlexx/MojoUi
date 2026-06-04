"""Typography helpers — font loading + `(font_id, size_pt)` size pickers.

Wires the small "load a font for the UI / load a mono font for code" helpers on
top of `Backend.load_font` (which itself wraps `mojoui_load_font` in the C
floor). The C floor already implements a fallback search across Inter /
JetBrainsMono / Roboto / DejaVu / Liberation when called with an empty path
(see `c_floor/mojoui_fonts.c::mui_find_default_font`), so this module's job is
mostly to (a) try the rerun-style "Inter first" preference explicitly so the
returned font_id is stable across distros that have Inter installed, and (b)
expose a small picker API that returns `(font_id, size_pt)` pairs convenient
for widget call sites.

The size/weight tokens themselves live in `mojoui/theme/tokens.mojo`
(`TypographyTokens` struct) — this module only loads the font_id + provides
the convenience pickers; widgets are free to read `theme.typography.size_X`
directly without going through the pickers.

NOT a font-cache (Backend already caches by slot), NOT a custom-font-registration
API (just use `Backend.load_font(path)` directly if the caller wants a specific
TTF), NOT a text-shaper (that's the C floor's job via stb_truetype + the M3
renderer adapter). Do NOT add fallback text rendering here.
"""

from mojoui.render.backend import Backend


# rerun's primary UI font choice + JetBrains Mono for code/numbers.
# `FONT_PREF_INTER` matches the FIRST entry of `mui_default_font_paths[]`
# in `c_floor/mojoui_fonts.c` for back-compat with code that imports the
# canonical "Debian-Inter" symbol. Cross-platform candidates are tried by
# `load_default_ui_font` / `load_mono_font` in order; the empty-string
# fall-through to `Backend.load_font("")` still triggers the C-floor
# default-font search.
comptime FONT_PREF_INTER: String = String(
    "/usr/share/fonts/truetype/inter/Inter-Medium.ttf"
)
comptime FONT_PREF_JETBRAINS: String = String(
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Medium.ttf"
)


def load_default_ui_font() -> UInt32:
    """Try Inter at multiple platform paths, then fall back to the C-floor search.

    Returns font_id (>= 1) on success or 0 if no font is findable anywhere.
    The empty-string call to `Backend.load_font("")` triggers
    `mui_find_default_font()` which walks Inter / JetBrainsMono / Roboto /
    DejaVu / Liberation in order on Linux.

    Candidate order: Debian, Arch/generic, Fedora, macOS user, macOS
    Homebrew, then the C-floor search.
    """
    # Linux Debian / Ubuntu
    var id = Backend.load_font(
        String("/usr/share/fonts/truetype/inter/Inter-Medium.ttf")
    )
    if id != 0:
        return id
    # Linux Arch / generic
    id = Backend.load_font(String("/usr/share/fonts/Inter/Inter-Medium.ttf"))
    if id != 0:
        return id
    # Linux Fedora (typical layout)
    id = Backend.load_font(String("/usr/share/fonts/inter/Inter-Medium.otf"))
    if id != 0:
        return id
    # macOS user-installed
    id = Backend.load_font(String("/Library/Fonts/Inter-Medium.otf"))
    if id != 0:
        return id
    # macOS Homebrew
    id = Backend.load_font(String("/opt/homebrew/share/fonts/Inter-Medium.ttf"))
    if id != 0:
        return id
    # Fall back to the C-side default-font search (returns slot 1 on first
    # successful match; subsequent calls return the cached slot).
    return Backend.load_font(String(""))


def load_mono_font() -> UInt32:
    """Load a monospaced font for code / numeric columns.

    Tries JetBrains Mono at multiple platform paths, then Fira Code,
    Cascadia Code, and finally falls back to the default UI font (which
    will almost certainly be proportional — the caller should accept
    that, or load a specific mono TTF via `Backend.load_font(path)`
    directly).
    """
    # Linux Debian / Ubuntu
    var id = Backend.load_font(
        String("/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Medium.ttf")
    )
    if id != 0:
        return id
    # Linux Arch / generic
    id = Backend.load_font(
        String("/usr/share/fonts/JetBrainsMono/JetBrainsMono-Medium.ttf")
    )
    if id != 0:
        return id
    # macOS user-installed
    id = Backend.load_font(String("/Library/Fonts/JetBrainsMono-Medium.ttf"))
    if id != 0:
        return id
    # macOS Homebrew
    id = Backend.load_font(
        String("/opt/homebrew/share/fonts/JetBrainsMono-Medium.ttf")
    )
    if id != 0:
        return id
    # Fira Code fallback (Linux Debian / Ubuntu)
    id = Backend.load_font(
        String("/usr/share/fonts/truetype/firacode/FiraCode-Medium.ttf")
    )
    if id != 0:
        return id
    # Cascadia Code fallback (Windows / cross-platform)
    id = Backend.load_font(
        String("/usr/share/fonts/cascadia-code/CascadiaCode.ttf")
    )
    if id != 0:
        return id
    return load_default_ui_font()


# --------------------------------------------------------------------------
# Size pickers
# --------------------------------------------------------------------------
# Given a font_id (typically `theme.font_id` set via `ctx.set_default_font`)
# and a size token from `TypographyTokens`, return the `(font_id, size_pt)`
# pair suitable for direct use in `ctx.draw_text(font_id, size_pt, ...)`.
#
# These are pure conveniences — widgets can also read
# `theme.typography.size_X` directly and pass `theme.font_id` + that size to
# `draw_text`. The pickers exist so that future theme variants (e.g. a
# "heading uses a different font_id than body" layout) can be slotted in
# without touching every widget call site.


def pick_body(
    theme_font: UInt32, theme_typography_size_body: Int32
) -> Tuple[UInt32, Int32]:
    """Body text size, using the theme's primary UI font."""
    return (theme_font, theme_typography_size_body)


def pick_caption(
    theme_font: UInt32, theme_typography_size_caption: Int32
) -> Tuple[UInt32, Int32]:
    """Caption / small-text size, using the theme's primary UI font."""
    return (theme_font, theme_typography_size_caption)


def pick_heading_md(
    theme_font: UInt32, theme_typography_size_heading_md: Int32
) -> Tuple[UInt32, Int32]:
    """Medium-heading size, using the theme's primary UI font."""
    return (theme_font, theme_typography_size_heading_md)


def pick_heading_lg(
    theme_font: UInt32, theme_typography_size_heading_lg: Int32
) -> Tuple[UInt32, Int32]:
    """Large-heading size, using the theme's primary UI font."""
    return (theme_font, theme_typography_size_heading_lg)
