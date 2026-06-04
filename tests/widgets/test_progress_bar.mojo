"""Smoke tests for `mojoui/widgets/progress_bar.mojo`.

Run: `pixi run test-progress-bar`

The progress bar is display-only — these tests verify (a) it emits the
expected number of rect commands per fraction, (b) the fill width matches
clamp(fraction, 0, 1) * rect.w, (c) negative fractions (indeterminate)
draw the empty track without a fill, (d) fractions >1.0 are clamped so
they never overflow, and (e) the widget never claims hover even with the
cursor directly over it.

JIT note: same constraint as `tests/widgets/test_basic.mojo` — we use
`Context.begin_frame_no_input(window_size, mouse_pos, pressed, released)`
to bypass the FFI poll (the JIT does not auto-dlopen `libmojoui_floor.so`
unless a symbol is materialised at runtime). Production widget calls go
through the full `begin_frame` polling path.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import IMM_ID_NONE
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_RECT,
    CMD_RECT_SIZE,
    read_cmd_rect,
)
from mojoui.widgets.progress_bar import progress_bar


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — set up a 1-column row of width 200, height 24 in an 800×600 window.
# After `_make_ctx`, the next `layout_next()` returns Rect(0, 0, 200, 24).
# ----------------------------------------------------------------------------


def _make_ctx(mut ctx: Context, mouse_pos: Vec2) raises:
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), False, False)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def _count_rects(ctx: Context) -> Int:
    """Walk the command buffer and count CMD_RECT commands.

    progress_bar emits ONLY rects (no text, no clip), so this should equal
    the total command count for tests that begin with a fresh frame.
    """
    var n = 0
    var off: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    while off < total:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_RECT):
            n += 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break  # defensive: malformed buffer
        off += step
    return n


def _find_fill_rect_width(ctx: Context) -> Float32:
    """Walk the command buffer and return the width of the fill rect, or
    -1.0 if no fill is present.

    The fill is identified as a CMD_RECT whose colour matches theme.primary
    (the only rect painted with primary in `progress_bar` — bg uses
    theme.bg, border uses theme.border). Width is read from the rect's w
    field, which is what the test wants to compare against rect.w * fraction.
    """
    var primary = ctx.theme.primary.copy()
    var off: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    while off < total:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_RECT):
            var rc = read_cmd_rect(ctx.commands, off)
            # Color comparison via channel-by-channel (Color is Copyable
            # not ImplicitlyCopyable; UInt8 fields are trivially compared).
            if (
                rc.color.r == primary.r
                and rc.color.g == primary.g
                and rc.color.b == primary.b
                and rc.color.a == primary.a
            ):
                return rc.rect.w
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off += step
    return Float32(-1.0)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_progress_half_emits_bg_fill_and_border() raises:
    """Test 1: fraction=0.5 emits 1 bg + 1 fill + 4 border = 6 rects, fill
    width is rect.w * 0.5 = 100.0."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    progress_bar(ctx, Float32(0.5))
    var n = _count_rects(ctx)
    if n != 6:
        print("got rect count:", n)
        _fail("fraction=0.5 should emit 6 rects (1 bg + 1 fill + 4 border)")
    var fill_w = _find_fill_rect_width(ctx)
    # rect.w is 200, fraction is 0.5 → fill_w should be 100.
    if fill_w < 99.5 or fill_w > 100.5:
        print("got fill_w:", fill_w)
        _fail("fraction=0.5 fill width should be ~100.0 (rect.w 200 * 0.5)")


def test_progress_zero_emits_no_fill() raises:
    """Test 2: fraction=0.0 emits 1 bg + 4 border = 5 rects, no fill rect."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    progress_bar(ctx, Float32(0.0))
    var n = _count_rects(ctx)
    if n != 5:
        print("got rect count:", n)
        _fail("fraction=0.0 should emit 5 rects (1 bg + 4 border, no fill)")
    var fill_w = _find_fill_rect_width(ctx)
    if fill_w >= 0.0:
        print("got fill_w:", fill_w)
        _fail("fraction=0.0 should not emit a fill rect")


def test_progress_full_emits_full_width_fill() raises:
    """Test 3: fraction=1.0 emits 1 bg + 1 fill + 4 border = 6 rects, fill
    width is rect.w * 1.0 = 200.0."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    progress_bar(ctx, Float32(1.0))
    var n = _count_rects(ctx)
    if n != 6:
        print("got rect count:", n)
        _fail("fraction=1.0 should emit 6 rects (1 bg + 1 fill + 4 border)")
    var fill_w = _find_fill_rect_width(ctx)
    if fill_w < 199.5 or fill_w > 200.5:
        print("got fill_w:", fill_w)
        _fail("fraction=1.0 fill width should be ~200.0 (full rect.w)")


def test_progress_indeterminate_emits_no_fill() raises:
    """Test 4: fraction=-1.0 (indeterminate) emits 1 bg + 4 border = 5
    rects, no fill rect. M2 indeterminate stub — M3 will add animated
    stripes overlay."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    progress_bar(ctx, Float32(-1.0))
    var n = _count_rects(ctx)
    if n != 5:
        print("got rect count:", n)
        _fail("fraction=-1.0 should emit 5 rects (1 bg + 4 border, no fill)")
    var fill_w = _find_fill_rect_width(ctx)
    if fill_w >= 0.0:
        print("got fill_w:", fill_w)
        _fail("fraction=-1.0 (indeterminate) should not emit a fill rect")


def test_progress_overflow_clamps_to_one() raises:
    """Test 5: fraction=1.5 clamps to 1.0 — fill width equals rect.w, not
    rect.w * 1.5 (which would overflow past the right edge)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    progress_bar(ctx, Float32(1.5))
    var n = _count_rects(ctx)
    if n != 6:
        print("got rect count:", n)
        _fail("fraction=1.5 should emit 6 rects (1 bg + 1 fill clamped + 4 border)")
    var fill_w = _find_fill_rect_width(ctx)
    # Clamped to 1.0 → fill_w == rect.w == 200, NOT 300 (would be 1.5 * 200).
    if fill_w < 199.5 or fill_w > 200.5:
        print("got fill_w:", fill_w)
        _fail("fraction=1.5 should clamp to 1.0 (fill width ~200.0, not 300.0)")


def test_progress_bar_never_claims_hover() raises:
    """Test 6: cursor directly over the progress bar — hover stays NONE
    because progress_bar is display-only (no `update_control` call)."""
    var ctx = Context()
    # Mouse at (10, 10) — well inside the 200×24 rect at (0, 0).
    _make_ctx(ctx, Vec2(10.0, 10.0))
    progress_bar(ctx, Float32(0.5))
    if UInt32(ctx.control.hover) != UInt32(IMM_ID_NONE):
        _fail("progress_bar should NEVER claim hover (display-only)")
    if UInt32(ctx.control.focus) != UInt32(IMM_ID_NONE):
        _fail("progress_bar should NEVER claim focus (display-only)")
    if UInt32(ctx.control.active) != UInt32(IMM_ID_NONE):
        _fail("progress_bar should NEVER claim active (display-only)")


def test_progress_bar_advances_layout() raises:
    """Test 7: progress_bar reserves a layout slot, so the layout cursor
    advances past the slot height (so the next widget flows below it)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0))
    var before_max_y = Int(ctx.layout.frames[0].max_y)
    progress_bar(ctx, Float32(0.5))
    var after_max_y = Int(ctx.layout.frames[0].max_y)
    if after_max_y <= before_max_y:
        _fail("progress_bar should advance layout max_y (reserves a slot)")


def main() raises:
    test_progress_half_emits_bg_fill_and_border()
    test_progress_zero_emits_no_fill()
    test_progress_full_emits_full_width_fill()
    test_progress_indeterminate_emits_no_fill()
    test_progress_overflow_clamps_to_one()
    test_progress_bar_never_claims_hover()
    test_progress_bar_advances_layout()
    print("PASS: progress_bar widget smoke tests (7 tests)")
