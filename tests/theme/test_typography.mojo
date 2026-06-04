"""Smoke tests for `mojoui.theme.typography`.

The font-loading helpers (`load_default_ui_font` / `load_mono_font`) reach
the C-floor `mojoui_load_font` symbol, which the JIT does not pre-resolve
under `mojo run` (c15/c16 wall). Per the c15 pattern we gate the runtime
call behind a never-True runtime guard so the test still type-checks against
the signature without forcing the JIT to materialise the FFI symbol.

The size pickers are pure-Mojo (no FFI in their call graph) and run live.
"""

from mojoui.core.input import MOUSE_BUTTON_COUNT
from mojoui.theme.typography import (
    load_default_ui_font,
    load_mono_font,
    pick_body,
    pick_caption,
    pick_heading_lg,
    pick_heading_md,
)


def test_load_default_ui_font_signature():
    # Runtime-False guard (c15 pattern): MOUSE_BUTTON_COUNT == 3 by design, so
    # `Int(MOUSE_BUTTON_COUNT) - 3 == 0` — the branch is unreachable at runtime
    # but the type-checker still verifies the signature against the call site.
    var never = Int(MOUSE_BUTTON_COUNT) - 3
    if never != 0:
        var fid = load_default_ui_font()
        # font_id is UInt32; any non-error value is >= 0 trivially, so this
        # primarily asserts the return type at compile time.
        if fid >= 0:
            pass
    print("PASS: load_default_ui_font signature")


def test_load_mono_font_signature():
    var never = Int(MOUSE_BUTTON_COUNT) - 3
    if never != 0:
        var fid = load_mono_font()
        if fid >= 0:
            pass
    print("PASS: load_mono_font signature")


def test_pick_body() raises:
    var pair = pick_body(5, 14)
    var got_font = pair[0]
    var got_size = pair[1]
    if got_font != 5:
        raise Error("pick_body: font mismatch (want 5, got " + String(got_font) + ")")
    if got_size != 14:
        raise Error("pick_body: size mismatch (want 14, got " + String(got_size) + ")")
    print("PASS: pick_body returns (5, 14)")


def test_pick_caption() raises:
    var pair = pick_caption(5, 11)
    if pair[0] != 5:
        raise Error("pick_caption: font mismatch")
    if pair[1] != 11:
        raise Error("pick_caption: size mismatch")
    print("PASS: pick_caption returns (5, 11)")


def test_pick_heading_md() raises:
    var pair = pick_heading_md(5, 20)
    if pair[0] != 5:
        raise Error("pick_heading_md: font mismatch")
    if pair[1] != 20:
        raise Error("pick_heading_md: size mismatch")
    print("PASS: pick_heading_md returns (5, 20)")


def test_pick_heading_lg() raises:
    var pair = pick_heading_lg(5, 28)
    if pair[0] != 5:
        raise Error("pick_heading_lg: font mismatch")
    if pair[1] != 28:
        raise Error("pick_heading_lg: size mismatch")
    print("PASS: pick_heading_lg returns (5, 28)")


def test_compile_and_import():
    # Reaching this point at runtime proves the module imported, the
    # `comptime` String constants resolved, and the picker call sites
    # type-checked against the Backend.load_font signature.
    print("PASS: typography module compiles + imports")


def main() raises:
    test_load_default_ui_font_signature()
    test_load_mono_font_signature()
    test_pick_body()
    test_pick_caption()
    test_pick_heading_md()
    test_pick_heading_lg()
    test_compile_and_import()
    print("PASS: all 7 typography smoke tests")
