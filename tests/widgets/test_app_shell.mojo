"""Tests for fixed app-shell helpers."""

from mojoui.core.context import Context
from mojoui.core.types import Vec2
from mojoui.theme.trainer_theme import apply_rust_trainer_theme
from mojoui.widgets.app_shell import (
    action_button,
    apply_shell_density,
    draw_shell_background,
    nav_row,
    trainer_shell_metrics,
)


def _row1(a: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    return r^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    return r^


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_shell_commands() raises:
    var ctx = Context()
    apply_rust_trainer_theme(ctx)
    var m = trainer_shell_metrics(1480.0, 920.0)
    apply_shell_density(ctx, m)
    ctx.begin_frame_no_input(Vec2(1480.0, 920.0), Vec2(-10.0, -10.0), False, False)
    draw_shell_background(ctx, m, 1480.0, 920.0)
    ctx.layout_row(_row1(m.nav_w - 24), m.row_h)
    _ = nav_row(ctx, String("training"), String("Training"), True)
    ctx.layout_row(_row2(120, 120), m.row_h)
    _ = action_button(ctx, String("start"), String("Start"), True)
    _ = action_button(ctx, String("stop"), String("Stop"), False)
    ctx.end_frame()
    _expect(m.main_w > 0, "main width should be positive")
    _expect(ctx.commands.byte_count() > 0, "shell helpers should emit draw commands")
    print("PASS: shell commands")


def main() raises:
    test_shell_commands()
    print("PASS: app shell helper tests")
