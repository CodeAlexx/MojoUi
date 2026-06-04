"""Smoke tests for `mojoui/theme/tokens.mojo` (M3 chunk 43).

Verifies the four token-group structs (`ColorTokens`, `SpacingTokens`,
`RadiusTokens`, `TypographyTokens`) and the composed `Theme` default-
construct cleanly, that defaults match the c43 contract, that the token
structs are Copyable + Movable + support `.copy()`, and that accessor
patterns used by future widget code work.

Run: `pixi run test-tokens`

No FFI in the call graph — pure-Mojo struct construction + field reads.
JIT-safe under `mojo run`; no runtime-False guard needed.
"""

from mojoui.core.types import Color
from mojoui.theme.tokens import (
    ColorTokens,
    SpacingTokens,
    RadiusTokens,
    TypographyTokens,
    Theme,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_theme_default_constructs() raises:
    """1) `Theme()` default-constructs without raising."""
    var t = Theme()
    if t.name != String("default"):
        _fail("Theme().name should be 'default'")
    if t.font_id != UInt32(0):
        _fail("Theme().font_id should be 0 (no font loaded)")


def test_color_defaults_non_zero() raises:
    """2) Default colors are non-zero (sanity: bg_default has alpha 255 and
    non-zero RGB; text_default opaque and bright)."""
    var c = ColorTokens()
    if c.bg_default.a != UInt8(255):
        _fail("bg_default alpha should be 255")
    var r_sum = Int(c.bg_default.r) + Int(c.bg_default.g) + Int(c.bg_default.b)
    if r_sum == 0:
        _fail("bg_default RGB should be non-zero (neutral dark, not pitch black)")
    if c.text_default.a != UInt8(255):
        _fail("text_default alpha should be 255")
    var t_sum = Int(c.text_default.r) + Int(c.text_default.g) + Int(c.text_default.b)
    if t_sum < 600:
        _fail("text_default should be bright (sum of RGB >= 600)")


def test_spacing_monotonic() raises:
    """3) Spacing scale increases monotonically: xs < sm < md < lg < xl < xxl."""
    var s = SpacingTokens()
    if not (s.xs < s.sm):
        _fail("spacing xs should be < sm")
    if not (s.sm < s.md):
        _fail("spacing sm should be < md")
    if not (s.md < s.lg):
        _fail("spacing md should be < lg")
    if not (s.lg < s.xl):
        _fail("spacing lg should be < xl")
    if not (s.xl < s.xxl):
        _fail("spacing xl should be < xxl")


def test_radius_pill_sentinel() raises:
    """4) RadiusTokens.pill = 9999 sentinel (canonical 'fully rounded' marker
    — renderers clamp to half the smaller axis at draw time)."""
    var r = RadiusTokens()
    if r.pill != Int32(9999):
        _fail("radius.pill should be 9999 (fully-rounded sentinel)")


def test_typography_weight_monotonic() raises:
    """5) Typography weight scale: normal < medium < bold (numeric per
    OpenType / CSS convention)."""
    var ty = TypographyTokens()
    if not (ty.weight_normal < ty.weight_medium):
        _fail("weight_normal should be < weight_medium")
    if not (ty.weight_medium < ty.weight_bold):
        _fail("weight_medium should be < weight_bold")


def test_theme_copyable_movable() raises:
    """6) Theme is Copyable + Movable + supports `.copy()` (the chunk's
    auto-derived copy machinery handles String + nested token structs).
    Mutating the copy does not bleed into the original."""
    var t1 = Theme()
    var t2 = t1.copy()
    if t2.name != t1.name:
        _fail("copied Theme name should equal original")
    if t2.font_id != t1.font_id:
        _fail("copied Theme font_id should equal original")
    # Mutate the copy and verify independence.
    t2.font_id = 42
    t2.name = String("modified")
    if t1.font_id != UInt32(0):
        _fail("original Theme.font_id should not change when copy is mutated")
    if t1.name != String("default"):
        _fail("original Theme.name should not change when copy is mutated")


def test_color_token_accessor() raises:
    """7) ColorTokens accessor works through nested Theme.colors — returns a
    Color whose fields match the construction-time defaults."""
    var t = Theme()
    var accent = t.colors.accent_default.copy()
    # Default accent is (110, 90, 200, 255).
    if accent.r != UInt8(110):
        _fail("colors.accent_default.r should be 110")
    if accent.g != UInt8(90):
        _fail("colors.accent_default.g should be 90")
    if accent.b != UInt8(200):
        _fail("colors.accent_default.b should be 200")
    if accent.a != UInt8(255):
        _fail("colors.accent_default.a should be 255")


def test_spacing_values_exact() raises:
    """8) SpacingTokens xs/sm/md/lg/xl/xxl values exact (2 / 4 / 8 / 16 / 24
    / 32). These are the 8px-grid rungs the c43 contract specifies."""
    var s = SpacingTokens()
    if s.xs != Int32(2):
        _fail("spacing.xs should be 2")
    if s.sm != Int32(4):
        _fail("spacing.sm should be 4")
    if s.md != Int32(8):
        _fail("spacing.md should be 8")
    if s.lg != Int32(16):
        _fail("spacing.lg should be 16")
    if s.xl != Int32(24):
        _fail("spacing.xl should be 24")
    if s.xxl != Int32(32):
        _fail("spacing.xxl should be 32")


def test_radius_values_exact() raises:
    """9) RadiusTokens values exact (0 / 2 / 6 / 12 / 9999)."""
    var r = RadiusTokens()
    if r.none != Int32(0):
        _fail("radius.none should be 0")
    if r.sm != Int32(2):
        _fail("radius.sm should be 2")
    if r.md != Int32(6):
        _fail("radius.md should be 6")
    if r.lg != Int32(12):
        _fail("radius.lg should be 12")
    if r.pill != Int32(9999):
        _fail("radius.pill should be 9999")


def test_typography_size_body_exact() raises:
    """10) TypographyTokens.size_body == 14 exact (matches DefaultTheme's
    font_size_pt and rerun's body type rung)."""
    var ty = TypographyTokens()
    if ty.size_body != Int32(14):
        _fail("typography.size_body should be 14")


def test_rerun_parity_tokens_exist_and_visible() raises:
    """11) Rerun-parity tokens added in the 2026-05-28 F4 bugfix exist
    and have non-zero alpha (so widgets that consume them render
    something visible)."""
    var c = ColorTokens()
    if c.widget_inactive_bg_fill.a == UInt8(0):
        _fail("widget_inactive_bg_fill alpha should be > 0")
    if c.widget_hovered_color.a == UInt8(0):
        _fail("widget_hovered_color alpha should be > 0")
    if c.widget_active_bg_fill.a == UInt8(0):
        _fail("widget_active_bg_fill alpha should be > 0")
    if c.text_strong.a == UInt8(0):
        _fail("text_strong alpha should be > 0")
    if c.floating_color.a == UInt8(0):
        _fail("floating_color alpha should be > 0")
    if c.faint_bg_color.a == UInt8(0):
        _fail("faint_bg_color alpha should be > 0")
    if c.extreme_bg_color.a == UInt8(0):
        _fail("extreme_bg_color alpha should be > 0")
    if c.selection_bg_fill.a == UInt8(0):
        _fail("selection_bg_fill alpha should be > 0")
    if c.selection_stroke_color.a == UInt8(0):
        _fail("selection_stroke_color alpha should be > 0")
    if c.focus_outline_stroke.a == UInt8(0):
        _fail("focus_outline_stroke alpha should be > 0")


def main() raises:
    test_theme_default_constructs()
    test_color_defaults_non_zero()
    test_spacing_monotonic()
    test_radius_pill_sentinel()
    test_typography_weight_monotonic()
    test_theme_copyable_movable()
    test_color_token_accessor()
    test_spacing_values_exact()
    test_radius_values_exact()
    test_typography_size_body_exact()
    test_rerun_parity_tokens_exist_and_visible()
    print("PASS: all 11 theme/tokens smoke tests")
