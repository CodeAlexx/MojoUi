"""Tests for mapping token themes onto Context.theme."""

from mojoui.core.context import Context
from mojoui.theme.apply import (
    STATUS_ERROR,
    STATUS_SUCCESS,
    apply_theme,
    status_fill,
    status_text,
    theme_to_default_theme,
)
from mojoui.theme.serenity_palettes import rust_trainer_theme
from mojoui.theme.themes import light_theme


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_theme_mapping_colors() raises:
    var t = light_theme()
    var runtime = theme_to_default_theme(t)
    if runtime.bg != t.colors.bg_default:
        _fail("bg should map from bg_default")
    if runtime.bg_panel != t.colors.bg_panel:
        _fail("bg_panel should map from token")
    if runtime.control_bg != t.colors.widget_inactive_bg_fill:
        _fail("control_bg should map from widget inactive token")
    if runtime.primary_hover != t.colors.accent_hover:
        _fail("primary_hover should map from accent_hover")
    if runtime.success_bg != t.colors.alert_success_fill:
        _fail("success_bg should map from alert_success_fill")
    if runtime.graph_canvas_bg != t.colors.graph_canvas_bg:
        _fail("graph_canvas_bg should map from token")


def test_apply_theme_preserves_font() raises:
    var ctx = Context()
    ctx.set_default_font(UInt32(77))
    var t = light_theme()
    apply_theme(ctx, t)
    if ctx.theme.font_id != UInt32(77):
        _fail("apply_theme should preserve existing font_id when token font is 0")


def test_apply_theme_uses_theme_font() raises:
    var ctx = Context()
    ctx.set_default_font(UInt32(77))
    var t = light_theme()
    t.font_id = UInt32(88)
    apply_theme(ctx, t)
    if ctx.theme.font_id != UInt32(88):
        _fail("apply_theme should use non-zero theme font_id")


def test_status_colors() raises:
    var runtime = theme_to_default_theme(rust_trainer_theme())
    if status_fill(runtime, STATUS_SUCCESS) != runtime.success_bg:
        _fail("success status fill")
    if status_text(runtime, STATUS_ERROR) != runtime.error_text:
        _fail("error status text")


def main() raises:
    test_theme_mapping_colors()
    test_apply_theme_preserves_font()
    test_apply_theme_uses_theme_font()
    test_status_colors()
    print("PASS: theme apply bridge")
