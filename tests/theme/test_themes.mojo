"""Smoke tests for `mojoui/theme/themes.mojo` (M3 chunk 47).

Verifies the three preset constructors (`dark_theme`, `light_theme`,
`high_contrast_theme`) seed canonical color values, that the three palettes
are visually distinct, and that `theme_for_name` dispatches the right
constructor + falls back to dark on unknown names.

Run: `pixi run test-themes`

No FFI in the call graph — pure-Mojo struct construction + field reads.
JIT-safe under `mojo run`; no runtime-False guard needed.
"""

from mojoui.core.types import Color
from mojoui.theme.themes import (
    dark_theme,
    light_theme,
    high_contrast_theme,
    theme_for_name,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _colors_equal(a: Color, b: Color) -> Bool:
    return (
        a.r == b.r
        and a.g == b.g
        and a.b == b.b
        and a.a == b.a
    )


def test_dark_theme_name_and_bg() raises:
    """1) dark_theme() returns Theme with name="dark".
    2) dark_theme().colors.bg_default == Color(20, 22, 26, 255) exact."""
    var t = dark_theme()
    if t.name != String("dark"):
        _fail("dark_theme().name should be 'dark'")
    var expected = Color(20, 22, 26, 255)
    if not _colors_equal(t.colors.bg_default, expected):
        _fail("dark_theme().colors.bg_default should be Color(20, 22, 26, 255)")


def test_light_theme_bg() raises:
    """3) light_theme().colors.bg_default == Color(245, 245, 248, 255)."""
    var t = light_theme()
    if t.name != String("light"):
        _fail("light_theme().name should be 'light'")
    var expected = Color(245, 245, 248, 255)
    if not _colors_equal(t.colors.bg_default, expected):
        _fail(
            "light_theme().colors.bg_default should be Color(245, 245, 248, 255)"
        )


def test_dark_and_light_distinct() raises:
    """4) dark and light are CLEARLY DIFFERENT — bg_default differs."""
    var d = dark_theme()
    var l = light_theme()
    if _colors_equal(d.colors.bg_default, l.colors.bg_default):
        _fail("dark and light bg_default must differ")
    # Sanity: dark bg must be DARKER than light bg (sum of RGB)
    var dark_sum = (
        Int(d.colors.bg_default.r)
        + Int(d.colors.bg_default.g)
        + Int(d.colors.bg_default.b)
    )
    var light_sum = (
        Int(l.colors.bg_default.r)
        + Int(l.colors.bg_default.g)
        + Int(l.colors.bg_default.b)
    )
    if not (dark_sum < light_sum):
        _fail("dark bg should be darker than light bg")


def test_high_contrast_black_bg() raises:
    """5) high_contrast_theme().colors.bg_default == Color(0, 0, 0, 255)."""
    var t = high_contrast_theme()
    if t.name != String("high_contrast"):
        _fail("high_contrast_theme().name should be 'high_contrast'")
    var expected = Color(0, 0, 0, 255)
    if not _colors_equal(t.colors.bg_default, expected):
        _fail("high_contrast bg_default should be pure black")


def test_theme_for_name_dark() raises:
    """6) theme_for_name("dark") == dark_theme() (same bg_default)."""
    var t = theme_for_name(String("dark"))
    var d = dark_theme()
    if not _colors_equal(t.colors.bg_default, d.colors.bg_default):
        _fail("theme_for_name('dark') should match dark_theme()")
    if t.name != String("dark"):
        _fail("theme_for_name('dark').name should be 'dark'")


def test_theme_for_name_light() raises:
    """7) theme_for_name("light") returns light theme."""
    var t = theme_for_name(String("light"))
    var l = light_theme()
    if not _colors_equal(t.colors.bg_default, l.colors.bg_default):
        _fail("theme_for_name('light') should match light_theme()")
    if t.name != String("light"):
        _fail("theme_for_name('light').name should be 'light'")


def test_theme_for_name_high_contrast() raises:
    """8) theme_for_name("high_contrast") returns high-contrast."""
    var t = theme_for_name(String("high_contrast"))
    var hc = high_contrast_theme()
    if not _colors_equal(t.colors.bg_default, hc.colors.bg_default):
        _fail(
            "theme_for_name('high_contrast') should match high_contrast_theme()"
        )
    if t.name != String("high_contrast"):
        _fail(
            "theme_for_name('high_contrast').name should be 'high_contrast'"
        )


def test_theme_for_name_unknown_falls_back_to_dark() raises:
    """9) theme_for_name("unknown_xyz") falls back to dark."""
    var t = theme_for_name(String("unknown_xyz"))
    var d = dark_theme()
    if not _colors_equal(t.colors.bg_default, d.colors.bg_default):
        _fail("theme_for_name('unknown_xyz') should fall back to dark_theme()")
    if t.name != String("dark"):
        _fail("fallback theme name should be 'dark'")


def test_all_themes_text_default_opaque() raises:
    """10) All three themes have non-zero alpha on text_default (not
    transparent)."""
    var d = dark_theme()
    var l = light_theme()
    var hc = high_contrast_theme()
    if d.colors.text_default.a == UInt8(0):
        _fail("dark text_default alpha should be non-zero")
    if l.colors.text_default.a == UInt8(0):
        _fail("light text_default alpha should be non-zero")
    if hc.colors.text_default.a == UInt8(0):
        _fail("high_contrast text_default alpha should be non-zero")
    # And specifically that all three are fully opaque (a=255)
    if d.colors.text_default.a != UInt8(255):
        _fail("dark text_default should be fully opaque (a=255)")
    if l.colors.text_default.a != UInt8(255):
        _fail("light text_default should be fully opaque (a=255)")
    if hc.colors.text_default.a != UInt8(255):
        _fail("high_contrast text_default should be fully opaque (a=255)")


def main() raises:
    test_dark_theme_name_and_bg()
    test_light_theme_bg()
    test_dark_and_light_distinct()
    test_high_contrast_black_bg()
    test_theme_for_name_dark()
    test_theme_for_name_light()
    test_theme_for_name_high_contrast()
    test_theme_for_name_unknown_falls_back_to_dark()
    test_all_themes_text_default_opaque()
    print("PASS: all 10 smoke tests")
