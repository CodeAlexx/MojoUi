"""Smoke tests for `mojoui/widgets/collapsing_header.mojo` — M2 chunk 26.

Run: `pixi run test-collapsing-header`

Exercises the collapsible-section-header widget end-to-end through Context →
LayoutStack → ControlState → CommandBuffer. Mirrors the c17 test_basic.mojo
patterns: `begin_frame_no_input` to bypass FFI poll (JIT-safe), single-column
rows of fixed width as layout slots, and `.copy()` discipline at every Vec2
read.

Test matrix:
  1. Compile + closed initially: returns False, no draw commands missing.
  2. Open initially: returns True.
  3. Click header (2-frame press+release) when closed: toggles to open;
     returns True on the release frame.
  4. Click header when open: toggles to closed; returns False on the
     release frame.
  5. Two headers with different labels get different IDs and toggle
     independently through their own `mut open` refs.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, hash_str
from mojoui.core.context import Context
from mojoui.widgets.collapsing_header import (
    collapsing_header, collapsing_header_accordion
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — single-column rows of width 200, height 24. Sequential header
# calls auto-wrap into rects (0,0,200,24), (0,24,200,24), ...
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Begin a frame with a 1-column row of width 200, height 24."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_closed_initial_returns_false() raises:
    """Test 1: closed initial state — `open = False`, no click — returns
    False; `open` stays False; emits draw commands (bg + triangle pieces +
    label)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var before_bytes = ctx.commands.byte_count()
    var open: Bool = False
    var result = collapsing_header(ctx, String("Section A"), open)
    var after_bytes = ctx.commands.byte_count()
    if result:
        _fail("closed header with no click should return False")
    if open:
        _fail("no click should leave open=False")
    if after_bytes <= before_bytes:
        _fail("collapsing_header should emit at least one draw command")
    ctx.end_frame()


def test_open_initial_returns_true() raises:
    """Test 2: open initial state — `open = True`, no click — returns True;
    `open` stays True."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var open: Bool = True
    var result = collapsing_header(ctx, String("Section B"), open)
    if not result:
        _fail("open header with no click should return True")
    if not open:
        _fail("no click should leave open=True")
    ctx.end_frame()


def test_click_toggles_closed_to_open() raises:
    """Test 3: click sequence flips closed → open. Two frames.

    Frame 1 — press-inside (no toggle yet, returns False — header still closed).
    Frame 2 — release-inside (toggles to open, returns True on release frame).
    """
    var ctx = Context()
    var open: Bool = False
    # Frame 1: mouse-down inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var f1 = collapsing_header(ctx, String("Toggle"), open)
    if f1:
        _fail("frame 1 (press only) should return False — header still closed")
    if open:
        _fail("frame 1 (press only) should not yet flip open")
    ctx.end_frame()
    # Frame 2: mouse-up inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2 = collapsing_header(ctx, String("Toggle"), open)
    if not f2:
        _fail("frame 2 (release-inside) should return True — header now open")
    if not open:
        _fail("frame 2 (release-inside) should flip open False → True")
    ctx.end_frame()


def test_click_toggles_open_to_closed() raises:
    """Test 4: click sequence flips open → closed. Two frames.

    Frame 1 — press-inside (no toggle yet, returns True — header still open).
    Frame 2 — release-inside (toggles to closed, returns False).
    """
    var ctx = Context()
    var open: Bool = True
    # Frame 1: press inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var f1 = collapsing_header(ctx, String("Toggle"), open)
    if not f1:
        _fail("frame 1 (press only) should return True — header still open")
    if not open:
        _fail("frame 1 (press only) should leave open=True")
    ctx.end_frame()
    # Frame 2: release inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2 = collapsing_header(ctx, String("Toggle"), open)
    if f2:
        _fail("frame 2 (release-inside) should return False — header closed")
    if open:
        _fail("frame 2 (release-inside) should flip open True → False")
    ctx.end_frame()


def test_two_headers_independent() raises:
    """Test 5: two headers with different labels get different IDs and toggle
    independently through their own `mut open` refs.

    Setup: row 0 holds header "A" (rect 0..24), row 1 holds header "B"
    (rect 24..48). Click on header A (mouse at y=10) flips ONLY A.
    """
    var ctx = Context()
    var a_open: Bool = False
    var b_open: Bool = False
    # Frame 1: press inside A (y=10 → first slot).
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var _f1a = collapsing_header(ctx, String("A"), a_open)
    var _f1b = collapsing_header(ctx, String("B"), b_open)
    ctx.end_frame()
    # Frame 2: release inside A.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2a = collapsing_header(ctx, String("A"), a_open)
    var f2b = collapsing_header(ctx, String("B"), b_open)
    ctx.end_frame()
    # A should have toggled (closed → open); B should not.
    if not f2a:
        _fail("header A should return True after release (now open)")
    if f2b:
        _fail("header B should return False (still closed, no click)")
    if not a_open:
        _fail("a_open should flip False → True")
    if b_open:
        _fail("b_open should remain False (independent state)")
    # Sanity: IDs differ.
    var id_a = hash_str(String("A"))
    var id_b = hash_str(String("B"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'A' and 'B' should hash to different IDs")


def test_accordion_opens_one_closes_siblings() raises:
    """Accordion variant: a shared `open_index` keeps at most one section
    open. Three headers (rows 0/1/2) share `open_index`. Initially open_index
    = 0 (section 0 open). Click section 1's header (row 1, y=30) → opening it
    sets open_index=1, implicitly closing section 0."""
    var ctx = Context()
    var open_index: Int32 = 0
    # Frame 1: press inside section 1's header (row 1: y in 24..48 → y=30).
    _make_ctx(ctx, Vec2(10.0, 30.0), True, False)
    _ = collapsing_header_accordion(ctx, String("S0"), Int32(0), open_index)
    _ = collapsing_header_accordion(ctx, String("S1"), Int32(1), open_index)
    _ = collapsing_header_accordion(ctx, String("S2"), Int32(2), open_index)
    ctx.end_frame()
    # Frame 2: release inside section 1. (S0 is evaluated before S1's click
    # updates open_index, so S0's same-frame return is stale — the close is
    # observed next frame; we assert the authoritative open_index here and the
    # per-section states on frame 3.)
    _make_ctx(ctx, Vec2(10.0, 30.0), False, True)
    _ = collapsing_header_accordion(ctx, String("S0"), Int32(0), open_index)
    var r1 = collapsing_header_accordion(ctx, String("S1"), Int32(1), open_index)
    var r2 = collapsing_header_accordion(ctx, String("S2"), Int32(2), open_index)
    ctx.end_frame()
    if open_index != Int32(1):
        _fail("accordion: clicking S1 should set open_index=1, got " + String(Int(open_index)))
    if not r1:
        _fail("accordion: S1 should be open")
    if r2:
        _fail("accordion: S2 should stay closed")
    # Frame 3: no input — now every section's return reflects open_index=1.
    _make_ctx(ctx, Vec2(900.0, 900.0), False, False)
    var f3_0 = collapsing_header_accordion(ctx, String("S0"), Int32(0), open_index)
    var f3_1 = collapsing_header_accordion(ctx, String("S1"), Int32(1), open_index)
    ctx.end_frame()
    if f3_0:
        _fail("accordion: S0 should report closed on the next frame")
    if not f3_1:
        _fail("accordion: S1 should report open on the next frame")


def test_accordion_click_open_section_closes_all() raises:
    """Clicking the currently-open section's header closes it, leaving
    open_index = -1 (no section open)."""
    var ctx = Context()
    var open_index: Int32 = 0
    # Frame 1: press inside section 0's header (row 0: y=10).
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    _ = collapsing_header_accordion(ctx, String("S0"), Int32(0), open_index)
    _ = collapsing_header_accordion(ctx, String("S1"), Int32(1), open_index)
    ctx.end_frame()
    # Frame 2: release inside section 0.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var r0 = collapsing_header_accordion(ctx, String("S0"), Int32(0), open_index)
    _ = collapsing_header_accordion(ctx, String("S1"), Int32(1), open_index)
    ctx.end_frame()
    if open_index != Int32(-1):
        _fail("accordion: clicking the open section should set open_index=-1, got " + String(Int(open_index)))
    if r0:
        _fail("accordion: S0 should be closed after clicking it")


def main() raises:
    test_closed_initial_returns_false()
    test_open_initial_returns_true()
    test_click_toggles_closed_to_open()
    test_click_toggles_open_to_closed()
    test_two_headers_independent()
    test_accordion_opens_one_closes_siblings()
    test_accordion_click_open_section_closes_all()
    print("PASS: collapsing_header widget smoke tests (7 tests)")
