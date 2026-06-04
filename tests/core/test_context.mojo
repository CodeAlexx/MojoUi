"""Smoke tests for `mojoui/core/context.mojo`.

Run: `pixi run test-context`

Covers the per-frame Context coordinator: construction, begin_frame /
end_frame lifecycle (window_rect set, layout depth=1, then 0 again),
id_stack push/pop/get_id with contextual hashing, layout shortcut forwarding,
update_control forwarding, draw_rect / draw_text command emission, theme
default font setter, and a two-frame "reset between frames" check.

JIT note: per Mojo implementation notes "mojo run (JIT) does NOT dlopen the shared
library", `input.poll()` (inside `begin_frame`) would trigger
"Symbols not found" for `mojoui_get_mouse_*` / `mojoui_get_key` under
`mojo run`. Tests instead use `begin_frame_no_input(window_size, mouse_pos,
pressed, released)` which threads mouse state in directly without polling
the C floor — so the JIT never needs to resolve those FFI symbols. The
production path (`begin_frame`) is still exercised end-to-end by the
M1+ visual demos (where `Backend.run_blocking` is in the call graph and
the .so loads cleanly).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import (
    ImmediateId,
    IMM_ID_NONE,
    hash_str,
    derive_id,
    FNV1A_OFFSET_32,
)
from mojoui.core.commands import CommandBuffer, CMD_RECT, CMD_TEXT
from mojoui.core.control import (
    ControlState,
    CTRL_HOVERED,
    CTRL_PRESSED,
    OPT_NONE,
)
from mojoui.core.context import Context, DefaultTheme


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_construct() raises:
    """Test 1: Context() constructs without error; everything is zero-init."""
    var ctx = Context()
    if len(ctx.id_stack) != 0:
        _fail("fresh Context should have empty id_stack")
    if ctx.layout.depth() != 0:
        _fail("fresh Context should have layout depth 0")
    if ctx.commands.byte_count() != 0:
        _fail("fresh Context should have empty command buffer")
    if ctx.window_rect.w != 0.0 or ctx.window_rect.h != 0.0:
        _fail("fresh Context should have zero window_rect")
    if Int(ctx._container_jump_offset) != -1:
        _fail("fresh Context should have _container_jump_offset == -1")
    if Int(ctx.theme.font_id) != 0:
        _fail("fresh Context theme.font_id should default to 0")


def test_begin_frame_sets_window_rect_and_root_layout() raises:
    """Test 2: begin_frame(Vec2(800,600)) sets window_rect to (0,0,800,600),
    pushes the root layout frame (depth=1), resets id_stack + commands."""
    var ctx = Context()
    # Seed some state so we can verify it gets reset.
    ctx.id_stack.append(ImmediateId(123))
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    if ctx.window_rect.x != 0.0 or ctx.window_rect.y != 0.0:
        _fail("window_rect origin should be (0,0)")
    if ctx.window_rect.w != 800.0 or ctx.window_rect.h != 600.0:
        _fail("window_rect size should be (800,600)")
    if len(ctx.id_stack) != 0:
        _fail("id_stack should be empty after begin_frame")
    if ctx.layout.depth() != 1:
        _fail("layout depth should be 1 (root frame) after begin_frame")
    if ctx.commands.byte_count() != 0:
        _fail("commands should be empty after begin_frame")


def test_push_pop_id_changes_stack_depth() raises:
    """Test 3: push_id_str("alpha") then push_id_str("beta") → stack length 2;
    get_id("x") under that stack returns a DIFFERENT hash than get_id("x")
    under just "alpha" (contextual hashing)."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    ctx.push_id_str("alpha")
    if len(ctx.id_stack) != 1:
        _fail("after one push, id_stack length should be 1")
    var id_under_alpha = ctx.get_id("x")
    ctx.push_id_str("beta")
    if len(ctx.id_stack) != 2:
        _fail("after two pushes, id_stack length should be 2")
    var id_under_alpha_beta = ctx.get_id("x")
    if UInt32(id_under_alpha) == UInt32(id_under_alpha_beta):
        _fail("get_id('x') should differ under different id_stack tops")
    ctx.pop_id()
    if len(ctx.id_stack) != 1:
        _fail("after pop, id_stack length should be 1 again")
    # Re-derive get_id("x") — should match the original under "alpha".
    var id_after_pop = ctx.get_id("x")
    if UInt32(id_after_pop) != UInt32(id_under_alpha):
        _fail("after pop, get_id('x') should match original under-alpha hash")


def test_get_id_without_push_is_top_level_hash() raises:
    """Test 4: get_id without any push returns the bare hash_str(key) —
    the same as a top-level widget."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    var id_via_ctx = ctx.get_id("foo")
    var id_direct = hash_str("foo")
    if UInt32(id_via_ctx) != UInt32(id_direct):
        _fail("top-level get_id should equal hash_str(key)")


def test_push_get_pop_balances() raises:
    """Test 5: full push → get_id → pop cycle leaves id_stack length 1
    (we pushed once before checking)."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    ctx.push_id_str("outer")
    ctx.push_id_str("inner")
    _ = ctx.get_id("widget")
    ctx.pop_id()
    if len(ctx.id_stack) != 1:
        _fail("after one pop from depth=2, id_stack length should be 1")


def test_layout_row_and_next_forward() raises:
    """Test 6: layout_row + layout_next returns the same slot a direct
    LayoutStack call would (proves the forward is faithful)."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    var widths = List[Int32]()
    widths.append(100)
    widths.append(50)
    ctx.layout_row(widths^, 30)
    var slot = ctx.layout_next()
    # First slot of a 100/50 @ 30 row, starting at the root frame's body
    # origin (0,0): should be (0,0,100,30).
    if slot.x != 0.0 or slot.y != 0.0:
        _fail("first slot origin should be (0,0)")
    if slot.w != 100.0 or slot.h != 30.0:
        _fail("first slot size should be (100,30)")


def test_update_control_forwards_to_control_state() raises:
    """Test 7: ctx.update_control matches the contract of the free-function
    update_control. Mocked input: directly set ctx.control fields so the
    test doesn't depend on FFI-polled mouse state."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    # Mock: pretend the mouse is at (20,20) and LMB just went down.
    # Direct field writes are safe — ControlState exposes plain mutable
    # fields; we're standing in for what `begin_frame` would normally
    # populate from `input.poll()`.
    ctx.control.mouse_pos = Vec2(20.0, 20.0)
    ctx.control.mouse_pressed_this_frame = True
    ctx.control.mouse_released_this_frame = False
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    var flags = ctx.update_control(id, rect, OPT_NONE)
    if (flags & CTRL_HOVERED) == 0:
        _fail("ctx.update_control should report CTRL_HOVERED on mouse-inside")
    if (flags & CTRL_PRESSED) == 0:
        _fail("ctx.update_control should report CTRL_PRESSED on press edge")
    if UInt32(ctx.control.active) != UInt32(id):
        _fail("ctx.update_control should claim active slot on press-inside")


def test_draw_rect_emits_one_rect_command() raises:
    """Test 8: ctx.draw_rect appends a CMD_RECT to the command buffer."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    var before = ctx.commands.byte_count()
    ctx.draw_rect(Rect(10.0, 10.0, 50.0, 30.0), Color(255, 128, 64, 255))
    var after = ctx.commands.byte_count()
    if after <= before:
        _fail("draw_rect should grow command buffer")
    if Int32(ctx.commands.kind_at(0)) != Int32(CMD_RECT):
        _fail("first command kind should be CMD_RECT")


def test_draw_text_emits_one_text_command() raises:
    """Test 9: ctx.draw_text appends a CMD_TEXT to the command buffer."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    ctx.draw_text(
        UInt32(1),
        Int32(14),
        Vec2(10.0, 10.0),
        Color(255, 255, 255, 255),
        String("Hello"),
    )
    if ctx.commands.byte_count() == 0:
        _fail("draw_text should grow command buffer")
    if Int32(ctx.commands.kind_at(0)) != Int32(CMD_TEXT):
        _fail("first command kind should be CMD_TEXT")


def test_end_frame_pops_root_layout() raises:
    """Test 10: full begin_frame / end_frame cycle leaves layout.depth() == 0."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    if ctx.layout.depth() != 1:
        _fail("after begin_frame, depth should be 1")
    ctx.end_frame()
    if ctx.layout.depth() != 0:
        _fail("after end_frame, depth should be 0 (no state leak)")


def test_begin_frame_twice_resets_state() raises:
    """Test 11: calling begin_frame twice — each call resets prior state
    (commands empty again, layout depth still 1, id_stack still empty)."""
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    # Dirty some state on the first frame.
    ctx.draw_rect(Rect(0.0, 0.0, 10.0, 10.0), Color(255, 0, 0, 255))
    ctx.push_id_str("dirty")
    if ctx.commands.byte_count() == 0:
        _fail("setup: commands should be non-empty after dirty draw")
    if len(ctx.id_stack) == 0:
        _fail("setup: id_stack should be non-empty after dirty push")
    # Second frame — should fully reset.
    ctx.begin_frame_no_input(Vec2(640.0, 480.0), Vec2(0.0, 0.0), False, False)
    if ctx.commands.byte_count() != 0:
        _fail("commands should be reset on second begin_frame")
    if len(ctx.id_stack) != 0:
        _fail("id_stack should be reset on second begin_frame")
    if ctx.layout.depth() != 1:
        _fail("layout depth should be 1 again on second begin_frame")
    if ctx.window_rect.w != 640.0 or ctx.window_rect.h != 480.0:
        _fail("window_rect should be updated to new window_size")


def test_set_default_font_updates_theme() raises:
    """Test 12: set_default_font(7) updates theme.font_id."""
    var ctx = Context()
    if Int(ctx.theme.font_id) != 0:
        _fail("default font_id should start at 0")
    ctx.set_default_font(UInt32(7))
    if Int(ctx.theme.font_id) != 7:
        _fail("set_default_font(7) should set theme.font_id to 7")


def test_set_theme_replaces_wholesale() raises:
    """Test 13: set_theme replaces the entire theme. Build a custom theme
    with a known bg color and confirm it sticks."""
    var ctx = Context()
    var custom = DefaultTheme()
    custom.bg = Color(10, 20, 30, 255)
    custom.font_size_pt = 24
    ctx.set_theme(custom)
    if Int(ctx.theme.bg.r) != 10 or Int(ctx.theme.bg.g) != 20 or Int(ctx.theme.bg.b) != 30:
        _fail("set_theme should swap in the custom bg color")
    if Int(ctx.theme.font_size_pt) != 24:
        _fail("set_theme should swap in the custom font_size_pt")


def main() raises:
    test_construct()
    test_begin_frame_sets_window_rect_and_root_layout()
    test_push_pop_id_changes_stack_depth()
    test_get_id_without_push_is_top_level_hash()
    test_push_get_pop_balances()
    test_layout_row_and_next_forward()
    test_update_control_forwards_to_control_state()
    test_draw_rect_emits_one_rect_command()
    test_draw_text_emits_one_text_command()
    test_end_frame_pops_root_layout()
    test_begin_frame_twice_resets_state()
    test_set_default_font_updates_theme()
    test_set_theme_replaces_wholesale()
    print("PASS: context smoke tests (13 tests)")
