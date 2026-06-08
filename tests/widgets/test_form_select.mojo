"""Smoke tests for form select rows backed by a shared open-id string."""

from mojoui.core.context import Context
from mojoui.core.types import Vec2
from mojoui.widgets.form import select_string_row


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _make_options() -> List[String]:
    var opts = List[String]()
    opts.append(String("FlowMatch Euler"))
    opts.append(String("Euler"))
    opts.append(String("DDIM"))
    return opts^


def _begin(mut ctx: Context, mouse_pos: Vec2, pressed: Bool, released: Bool):
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)


def _row(
    mut ctx: Context,
    mut value: String,
    mut open_id: String,
) -> Bool:
    return select_string_row(
        ctx,
        100,
        200,
        String("Sampler"),
        String("sample_sampler"),
        _make_options(),
        value,
        open_id,
    )


def main() raises:
    var ctx = Context()
    var value = String("FlowMatch Euler")
    var open_id = String("")

    _begin(ctx, Vec2(120.0, 10.0), True, False)
    _ = _row(ctx, value, open_id)
    ctx.end_frame()

    _begin(ctx, Vec2(120.0, 10.0), False, True)
    var changed_open = _row(ctx, value, open_id)
    if changed_open:
        _fail("header click should open without changing value")
    if open_id != String("sample_sampler"):
        _fail("header click should set shared open id")
    if value != String("FlowMatch Euler"):
        _fail("header click should preserve current value")
    ctx.end_frame()

    _begin(ctx, Vec2(120.0, 60.0), True, False)
    _ = _row(ctx, value, open_id)
    ctx.end_frame()

    _begin(ctx, Vec2(120.0, 60.0), False, True)
    var changed_select = _row(ctx, value, open_id)
    if not changed_select:
        _fail("option click should report a value change")
    if value != String("Euler"):
        _fail("option click should update the bound string")
    if open_id.byte_length() != 0:
        _fail("option click should close the shared open id")
    ctx.end_frame()

    print("PASS: form select row shared open-id smoke")
