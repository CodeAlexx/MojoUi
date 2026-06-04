"""MojoUI M1 demo — static three-frame walk of Context + button + label.

Run via `pixi run m1`. The pixi task BUILDS to a
binary then runs it; the JIT path (`mojo run`) does NOT work here because
the JIT eagerly materialises every reachable `external_call` symbol even
under the runtime-False guard, tripping "Symbols not found" on the gated
`Backend.draw_*` dispatch in the walker. Building links against
libmojoui_floor.so via `-Xlinker -L. -Xlinker -lmojoui_floor`, so the
gate works as intended — `mojoui_draw_*` is symbol-resolvable but never
called. See Mojo implementation notes "mojo run (JIT) does NOT dlopen the shared
library" + "Module-level state for frame callbacks — UNRESOLVED".

M1 phase capstone (chunk 18). Proves the immediate-mode loop composes
end-to-end: `Context` (c16) → `layout_row`+`layout_next` (c13) →
`button(ctx, label)` (c17) → `update_control` (c14) → `CommandBuffer`
(c12) → walker dispatch through `Backend` (c9).

Static (no `Backend.run_blocking`, no live window) because the no-arg
sokol_app frame callback would need shared mutable state with `main()`,
but current beta Mojo rejects module-level `var` and cannot materialise
capturing closures as runtime function pointers. The canonical fix is a
2-symbol C-floor `user_data` extension (~10 LoC) — deferred to a future
chunk; tracked under Mojo implementation notes "Module-level state for frame
callbacks — UNRESOLVED".

Three frames simulated:
  F1: mouse at (500,500), press=F rel=F  → no click, no hover claim.
  F2: mouse at (50,10),   press=T rel=F  → button claims active, no click yet.
  F3: mouse at (50,10),   press=F rel=T  → release-inside-active → click.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP,
    CMD_CLIP,
    CMD_RECT,
    CMD_TEXT,
    CMD_ICON,
    CMD_IMAGE,
    read_cmd_rect,
    read_cmd_text,
)
from mojoui.widgets.basic import button, label
from mojoui.render.backend import Backend
# Runtime-False JIT guard pattern (see _walk_and_dispatch). `Int(MOJOUI_KEY_COUNT)
# - 96` is always 0 but the optimiser doesn't fold it, so gated FFI calls
# type-check without forcing actual execution. Same trick as test_input.mojo.
from mojoui.render.ffi import MOJOUI_KEY_COUNT


comptime WINDOW_W: Float32 = 600.0
comptime WINDOW_H: Float32 = 400.0
comptime BUTTON_W: Int32 = 200
comptime BUTTON_H: Int32 = 32
comptime LABEL_W: Int32 = 400
comptime LABEL_H: Int32 = 24


def _walk_and_dispatch(mut ctx: Context, never_run: Bool) raises -> Int:
    """Walk ctx.commands; dispatch each through Backend (gated by `never_run`).

    Returns total command count. The Backend calls are compile-proved against
    real signatures but never execute at runtime (no GL context is alive in
    this static demo). Built binary links `mojoui_draw_*` against
    libmojoui_floor.so via `-Xlinker -L. -Xlinker -lmojoui_floor` so the
    symbols resolve at link time — the JIT path cannot achieve the same.
    """
    var count: Int = 0
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            # Guard against backward / self-referential JUMP — would
            # otherwise infinite-loop the walker. See FRAGILE #2 in
            # regression notes and the walker-invariant
            # note on `CommandBuffer.read_jump_dst`.
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            count = count + 1
            if off <= prev_off:
                print(
                    "MojoUI: walker breaking on non-forward JUMP at",
                    Int(prev_off),
                    "dst=",
                    Int(off),
                )
                break
            continue
        var size = ctx.commands.size_at(off)
        if kind == CMD_RECT:
            var cmd = read_cmd_rect(ctx.commands, off)
            if never_run:
                Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
            count = count + 1
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(ctx.commands, off)
            if never_run:
                _ = Backend.draw_text(
                    cmd.font_id, cmd.size_pt, cmd.text,
                    cmd.pos.copy(), cmd.color.copy(),
                )
            count = count + 1
        elif kind == CMD_CLIP or kind == CMD_ICON or kind == CMD_IMAGE:
            # CLIP: M1 backend has no scissor (M3 will wire it).
            # ICON/IMAGE: not used by M1 widgets; counted for completeness.
            count = count + 1
        off = off + size
    return count


def _simulate_frame(
    mut ctx: Context, mouse_pos: Vec2, pressed: Bool, released: Bool,
    mut counter: Int32,
) raises -> Bool:
    """Run one frame: begin → row → button → row → label → end. Returns the
    button's click event (True only on release-inside-active).

    Per FRAGILE #7 (regression notes): the counter is
    bumped IMMEDIATELY on click and BEFORE the label() call, so the label
    in the SAME frame reflects the new count — the user-visible string is
    consistent with the click event reported that frame.
    """
    ctx.begin_frame_no_input(
        Vec2(WINDOW_W, WINDOW_H), mouse_pos.copy(), pressed, released
    )
    var widths1 = List[Int32]()
    widths1.append(BUTTON_W)
    ctx.layout_row(widths1^, BUTTON_H)
    var clicked = button(ctx, String("Click me"))
    if clicked:
        counter = counter + 1
    var widths2 = List[Int32]()
    widths2.append(LABEL_W)
    ctx.layout_row(widths2^, LABEL_H)
    var msg = String("Clicked ") + String(counter) + String(" times")
    label(ctx, msg)
    ctx.end_frame()
    return clicked


def _run_frame(
    mut ctx: Context, never_run: Bool, label: String,
    mouse_pos: Vec2, pressed: Bool, released: Bool, mut counter: Int32,
    expect_click: Bool,
) raises -> Int:
    """Run+walk one frame; assert click matches expectation; print summary.

    `counter` is `mut` so `_simulate_frame`'s in-frame bump (see FRAGILE #7)
    propagates back to `main`.
    """
    var clicked = _simulate_frame(ctx, mouse_pos.copy(), pressed, released, counter)
    var count = _walk_and_dispatch(ctx, never_run)
    if clicked != expect_click:
        print("FAIL:", label, "expected click=", expect_click, "got", clicked)
        raise Error("click expectation mismatch")
    # Min budget per frame: button (1 bg + 4 border + 1 text) + label (1 text) = 7.
    if count < 7:
        print("FAIL:", label, "emitted", count, "commands; expected >= 7")
        raise Error("command count below minimum")
    print(label, " click=", clicked, " commands=", count)
    return count


def main() raises:
    """Three-frame static M1 demo. Built binary required (NOT mojo run)."""
    var never_marker = Int(MOJOUI_KEY_COUNT) - 96
    var never_run: Bool = never_marker != 0

    var ctx = Context()
    # c10 deterministic-FFI trick: id 1 is what the live font registry would
    # assign. Static demo doesn't load a font (no GL context), just flows a
    # non-zero id through so CMD_TEXT records look realistic.
    ctx.set_default_font(UInt32(1))

    var counter: Int32 = 0
    var total: Int = 0
    total = total + _run_frame(
        ctx, never_run, String("frame 1: mouse=(500,500) press=F rel=F"),
        Vec2(500.0, 500.0), False, False, counter, False,
    )
    total = total + _run_frame(
        ctx, never_run, String("frame 2: mouse=(50,10)   press=T rel=F"),
        Vec2(50.0, 10.0), True, False, counter, False,
    )
    total = total + _run_frame(
        ctx, never_run, String("frame 3: mouse=(50,10)   press=F rel=T"),
        Vec2(50.0, 10.0), False, True, counter, True,
    )
    # `counter` is now bumped inside `_simulate_frame` ON the click (F3),
    # so by the time we reach this print the value is already 1 (see
    # FRAGILE #7 in regression notes — the previous
    # design bumped here, AFTER the per-frame loop, so F3's label still
    # showed "Clicked 0 times" even though the click was detected).
    print(
        "PASS: M1 demo emitted", total,
        "draw commands across 3 frames; counter ended at", counter,
    )
