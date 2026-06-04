"""Row/column flow layout stack — microui `mu_Layout` equivalent.

A `LayoutFrame` is one "container" in the layout stack: a bounding box
(`body`), a pen position (`cursor`), and a row template (`widths` +
`row_height`) that `next()` consumes column-by-column. Push a frame for
each nested column/window; pop when done.

`layout_row(widths, height)` sets the next row's column widths + row
height. `layout_next()` returns the next slot `Rect` and advances the
cursor; when the cursor walks off the end of the current row's widths
template, the row is implicitly ended (cursor snaps down by row_height +
spacing.y, cursor.x resets to body.x, col_index goes back to 0) and
`next()` continues to vend rects using the *same* template — same
behaviour as microui's `mu_layout_next` when `item_index == items`.

Width semantics (per `widths[i]`):
  * `> 0`  — fixed pixel width
  * `== 0` — default cell width (80 px in M1)
  * `< 0`  — stretch-share (M3 will divide remaining body.w among
              stretchy columns; in M1 a negative entry collapses to the
              default 80 px so layouts compose predictably while flex
              constraints are still pending).

Row height semantics (per `row_height` set by `row()` / `push()`):
  * `> 0`  — fixed pixel height
  * `== 0` — default row height (24 px in M1)

This module is owned by `Context` (chunk 16): `Context.layout` is a
`LayoutStack`, `Context.begin_frame` calls `layout.reset()`, and the
chunk-17 widget code calls `layout.next()` for its slot. NOT flex
constraints (M3) and NOT scroll/clip (commands.mojo, chunk 12 handles
clip stack independently).

Mirrors microui's `mu_Layout` per
`/home/alex/mojoui-audit/AUDIT_microui.md` "Layout System".
"""

from mojoui.core.types import Rect, Vec2


# ============================================================
# Compile-time defaults
# ============================================================
#
# `comptime` (not `alias`) for compile-time constants per current beta —
# see /home/alex/mojoui-audit/MOJO_NOTES.md "`comptime` not `alias`".

comptime ROW_DEFAULT_H: Int32 = 0
"""Sentinel for `row_height == default`. `_compute_row_height` returns
`DEFAULT_ROW_PX` when it sees this. Stored (not resolved) so a downstream
theme change can shift the default without rewriting layout state."""

comptime DEFAULT_ROW_PX: Int32 = 24
"""Pixel height returned by `_compute_row_height` when `row_height == 0`.
24 px matches typical button / text-edit row heights at 14-16 pt."""

comptime DEFAULT_COL_PX: Int32 = 80
"""Pixel width returned by `_compute_col_width` for a 0-entry or (M1) a
negative entry. 80 px is a comfortable label/button width at the M1
defaults."""

comptime SPACING_DEFAULT: Float32 = 4.0
"""Default horizontal + vertical gap between adjacent slots in a frame.
Matches microui's default `style.spacing` of 4 px."""


# ============================================================
# LayoutFrame — one container in the stack
# ============================================================


struct LayoutFrame(Copyable, Movable):
    """One frame of the layout stack: a rectangular container + flow state.

    Created by `LayoutStack.push(body)` and `begin_column()`. Mutated
    in-place by `LayoutStack.row` / `next` / internal helpers. All fields
    are kept inside the frame (no shadow state elsewhere) so the frame is
    self-contained and trivially copyable for tests.

    Fields:
        body         — the container's content rect (post-padding)
        cursor       — current pen position (top-left of the next slot)
        widths       — per-column width template for the current row
                       (positive = fixed px, 0 = default, negative =
                       stretch-share in M3; M1 treats negative as default)
        col_index    — which column we're emitting next within the row
        row_height   — height of the current row (0 = default = DEFAULT_ROW_PX)
        max_y        — bottom-most extent seen so far (for parent sizing
                       in `begin_column`/`end_column` and for future
                       scroll-content sizing in chunk-12 commands)
        spacing      — horizontal/vertical gap between slots (px)
        indent       — left-side indent for collapsing groups (M2)
    """

    var body: Rect
    var cursor: Vec2
    var widths: List[Int32]
    var col_index: Int32
    var row_height: Int32
    var max_y: Int32
    var spacing: Vec2
    var indent: Int32

    def __init__(out self):
        """Zero-init frame at the origin. Used by InlineArray fill and
        tests; real frames come from `LayoutStack.push(body)`."""
        self.body = Rect()
        self.cursor = Vec2.zero()
        self.widths = List[Int32]()
        self.col_index = 0
        self.row_height = ROW_DEFAULT_H
        self.max_y = 0
        self.spacing = Vec2(SPACING_DEFAULT, SPACING_DEFAULT)
        self.indent = 0

    def __init__(
        out self,
        body: Rect,
        cursor: Vec2,
        var widths: List[Int32],
        col_index: Int32,
        row_height: Int32,
        max_y: Int32,
        spacing: Vec2,
        indent: Int32,
    ):
        self.body = body.copy()
        self.cursor = cursor.copy()
        self.widths = widths^
        self.col_index = col_index
        self.row_height = row_height
        self.max_y = max_y
        self.spacing = spacing.copy()
        self.indent = indent


# ============================================================
# LayoutStack — the per-Context layout stack
# ============================================================


struct LayoutStack(Movable):
    """The layout stack itself. Owned by `Context` (chunk 16).

    Holds a `List[LayoutFrame]` (the active stack), grown by `push()` and
    `begin_column()`, shrunk by `pop()` and `end_column()`. Per-frame
    lifecycle: `Context.begin_frame` calls `reset()`, the user/widget
    code pushes/pops frames and emits slots via `next()`, and the stack
    is empty again at `Context.end_frame`.
    """

    var frames: List[LayoutFrame]

    def __init__(out self):
        self.frames = List[LayoutFrame]()

    # ----- Stack mechanics ---------------------------------------------

    def reset(mut self):
        """Empty the stack. Called per frame by `Context.begin_frame`
        (chunk 16) so a new frame starts with no leftover containers."""
        self.frames = List[LayoutFrame]()

    def push(mut self, body: Rect):
        """Push a new frame at the given body rect.

        The frame's cursor starts at `body.x, body.y` (top-left), row
        template is empty (next `next()` falls back to DEFAULT_COL_PX),
        row_height defaults, max_y starts at body.y, and spacing is the
        module-level default. Indent is 0 (M2 treenodes will bump it).
        """
        var frame = LayoutFrame(
            body=body,
            cursor=Vec2(body.x, body.y),
            widths=List[Int32](),
            col_index=0,
            row_height=ROW_DEFAULT_H,
            max_y=Int32(body.y),
            spacing=Vec2(SPACING_DEFAULT, SPACING_DEFAULT),
            indent=0,
        )
        self.frames.append(frame^)

    def pop(mut self):
        """Pop the current frame. No-op safety: callers are expected to
        push/pop in balanced pairs (Context invariant)."""
        _ = self.frames.pop()

    def depth(self) -> Int32:
        """Number of frames currently on the stack. 0 between frames /
        before the first `push()`."""
        return Int32(len(self.frames))

    # ----- Row mechanics -----------------------------------------------

    def row(mut self, var widths: List[Int32], height: Int32):
        """Begin a new row with the given column widths + row height.

        Resets `col_index = 0` and snaps the cursor to the new row's
        baseline. If a previous row was mid-flight (col_index > 0), it
        is implicitly ended first via `_row_end` so the new row starts
        at the right y position.

        `height == 0` means "use the default row height" (per
        DEFAULT_ROW_PX).
        """
        var n = Int(len(self.frames)) - 1
        if self.frames[n].col_index > 0:
            self._row_end()
        # Move-in the widths List (caller transfers ownership). Typical
        # widths arrays are 1-5 entries; M3 may switch to a fixed
        # `InlineArray[Int32, 16]` mirror to drop the allocation entirely.
        self.frames[n].widths = widths^
        self.frames[n].col_index = 0
        if height > 0:
            self.frames[n].row_height = height
        else:
            self.frames[n].row_height = ROW_DEFAULT_H

    def next(mut self) -> Rect:
        """Return the next layout slot as a `Rect` and advance the cursor.

        Slot dimensions come from `_compute_col_width(col_index)` +
        `_compute_row_height()`. After emission:
          * `col_index += 1`
          * if we're past the last column → `_row_end()` (wraps cursor
            to the next row using the *same* widths template, matching
            microui's `mu_layout_next` auto-wrap behaviour);
          * else cursor.x advances by (slot width + spacing.x).
        `max_y` is updated to the bottom of the emitted slot for parent
        sizing.

        Empty-stack diagnostic: if no frame has been pushed yet (the
        caller forgot `Context.begin_frame()` or popped a frame too many
        with `end_column`), this prints a one-line message naming the
        actual root cause and returns a zero rect rather than the cryptic
        "index -1 out of bounds" List crash. See FRAGILE #6 in
        SKEPTIC_FINDINGS_M1_2026-05-28.md.
        """
        if len(self.frames) == 0:
            print(
                "MojoUI: layout_next called with no active frame",
                "(forgot begin_frame or end_column without matching begin_column?)",
            )
            return Rect(0.0, 0.0, 0.0, 0.0)
        var n = Int(len(self.frames)) - 1
        var w = self._compute_col_width(n)
        var h = self._compute_row_height(n)
        var slot = Rect(
            self.frames[n].cursor.x,
            self.frames[n].cursor.y,
            Float32(w),
            Float32(h),
        )
        # Track max_y BEFORE we possibly _row_end (which advances cursor.y).
        var slot_bottom = Int32(slot.y) + h
        if slot_bottom > self.frames[n].max_y:
            self.frames[n].max_y = slot_bottom
        # Advance col_index; wrap row if needed.
        self.frames[n].col_index = self.frames[n].col_index + 1
        var n_widths = Int32(len(self.frames[n].widths))
        if n_widths > 0 and self.frames[n].col_index >= n_widths:
            self._row_end()
        else:
            self.frames[n].cursor.x = (
                self.frames[n].cursor.x
                + Float32(w)
                + self.frames[n].spacing.x
            )
        return slot.copy()

    def begin_column(mut self):
        """Push a sub-frame for a nested column layout.

        The sub-frame's body is the next slot from the parent (the
        cursor advances past it like any other slot). Use `end_column()`
        to pop.
        """
        var slot = self.next()
        self.push(slot)

    def end_column(mut self):
        """Pop the current sub-frame.

        Parent's cursor is already past the column (it was advanced when
        `begin_column` called `self.next()`). M3 will optionally bubble
        the child's `max_y` up to the parent so a tall column expands
        the parent's content size — for M1 we just pop.
        """
        self.pop()

    # ----- Internal helpers --------------------------------------------

    def _row_end(mut self):
        """End the current row: snap cursor.y down by row_height +
        spacing.y, reset cursor.x to body.x, reset col_index to 0."""
        var n = Int(len(self.frames)) - 1
        var h = self._compute_row_height(n)
        self.frames[n].cursor.y = (
            self.frames[n].cursor.y
            + Float32(h)
            + self.frames[n].spacing.y
        )
        self.frames[n].cursor.x = self.frames[n].body.x
        self.frames[n].col_index = 0

    def _compute_col_width(self, n: Int) -> Int32:
        """Width for the column the cursor is currently on.

        Resolution rules (per the module docstring):
          * No widths template OR col_index >= len(widths) → DEFAULT_COL_PX
          * widths[col_index] > 0 → that fixed pixel width
          * widths[col_index] == 0 → DEFAULT_COL_PX
          * widths[col_index] < 0 → DEFAULT_COL_PX (M1 simplification;
            M3 will divide remaining body.w among negative entries).
        """
        var n_widths = Int(len(self.frames[n].widths))
        var col = Int(self.frames[n].col_index)
        if n_widths == 0 or col >= n_widths:
            return DEFAULT_COL_PX
        var w = self.frames[n].widths[col]
        if w > 0:
            return w
        # w == 0 or w < 0 → default in M1.
        return DEFAULT_COL_PX

    def _compute_row_height(self, n: Int) -> Int32:
        """Height for the current row. `row_height > 0` is the explicit
        request; `0` (the ROW_DEFAULT_H sentinel) resolves to
        DEFAULT_ROW_PX."""
        if self.frames[n].row_height > 0:
            return self.frames[n].row_height
        return DEFAULT_ROW_PX
