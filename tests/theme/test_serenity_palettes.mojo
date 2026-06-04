"""Tests for Serenity/DearPyGui-inspired MojoUI palettes.

Run: pixi run test-serenity-palettes
"""

from mojoui.theme.serenity_palettes import (
    SERENITY_PALETTE_COUNT,
    serenity_palette_name,
    serenity_palette_index,
    serenity_theme_for_name,
    serenity_theme_at,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_palette_names() raises:
    _expect(SERENITY_PALETTE_COUNT == 8, "eight Serenity palettes")
    _expect(serenity_palette_name(0) == String("Rust Trainer"), "first palette")
    _expect(serenity_palette_name(7) == String("Cyberpunk"), "last palette")
    _expect(serenity_palette_index(String("Blender")) == 6, "index lookup")
    _expect(serenity_palette_index(String("missing")) == 0, "unknown index fallback")
    print("PASS: palette names")


def test_theme_mapping() raises:
    var s = serenity_theme_for_name(String("Serenity"))
    var r = serenity_theme_for_name(String("Rust Trainer"))
    var m = serenity_theme_for_name(String("Moonlight"))
    var c = serenity_theme_for_name(String("Cyberpunk"))
    _expect(r.name == String("Rust Trainer"), "rust trainer theme name")
    _expect(s.name == String("Serenity"), "serenity theme name")
    _expect(m.name == String("Moonlight"), "moonlight theme name")
    _expect(c.name == String("Cyberpunk"), "cyberpunk theme name")
    _expect(r.colors.bg_default.r == UInt8(20), "rust trainer warm bg")
    _expect(r.colors.accent_default.r == UInt8(230), "rust trainer accent")
    _expect(s.colors.bg_default.r == UInt8(26), "serenity window bg from DPG")
    _expect(m.colors.accent_default.r == UInt8(248), "moonlight slider accent")
    _expect(c.colors.border_default.r > UInt8(150), "cyberpunk border maps")
    print("PASS: theme mapping")


def test_theme_at_and_unknown() raises:
    var b = serenity_theme_at(6)
    var fallback = serenity_theme_for_name(String("unknown"))
    _expect(b.name == String("Blender"), "theme_at blender")
    _expect(fallback.name == String("Rust Trainer"), "unknown theme fallback")
    _expect(b.radius.md == Int32(3), "blender rounding")
    print("PASS: theme_at and fallback")


def main() raises:
    test_palette_names()
    test_theme_mapping()
    test_theme_at_and_unknown()
    print("PASS: serenity palette tests (3 tests)")
