"""Context menu — right-click popup at a captured anchor. M5 menu system.

A context menu is conceptually a `popup` whose anchor is the point where the
user right-clicked. The caller is responsible for:

  1. Detecting the right-click event on whatever surface should open the menu
     (canvas, node, list row, etc) — use the `right_click_at` helper.
  2. Storing the captured `anchor: Vec2` and an `is_open: Bool` flag across
     frames (since Mojo has no module-level state — see MOJOUI_NOTES.md
     "Module-level `var` is REJECTED"; same convention as combobox).
  3. Calling `context_menu(ctx, id, anchor, items, is_open)` every frame.
     When `is_open` is True the popup renders; clicking an item returns its
     index and closes; clicking outside closes via popup's built-in logic.

Typical usage shape (in a canvas widget):

    if right_click_at(ctx, canvas_rect, state.ctx_anchor):
        state.ctx_open = True
        state.ctx_items = [String("Copy"), String("Paste"), String("Delete")]

    var item = context_menu(
        ctx, String("canvas_ctx"),
        state.ctx_anchor, state.ctx_items, 180.0, state.ctx_open,
    )
    if item == 0: ... copy
    if item == 1: ... paste
    if item == 2: ... delete

Why split this from `popup` even though the body is one line:
  - Intent clarity at call sites — `context_menu(...)` reads like the
    right-click thing it is, not a generic dropdown.
  - Forward extensibility — adding submenu chaining or keyboard shortcut
    glyphs at the right edge of each row belongs to context-menu UX, not
    to the generic popup primitive. Future M6 work lands here without
    polluting the popup widget every caller uses.
"""

from mojoui.core.types import Vec2, Rect
from mojoui.core.context import Context
from mojoui.render.ffi import MOJOUI_BTN_RIGHT
from mojoui.widgets.popup import popup


def right_click_at(
    mut ctx: Context,
    rect: Rect,
    mut anchor: Vec2,
) -> Bool:
    """Detect a right-mouse press inside `rect` this frame. On press,
    writes the current cursor position into `anchor` (the point where
    the context menu should open) and returns True. Otherwise leaves
    `anchor` untouched and returns False.

    Uses press-edge (RMB transitioning down this frame) rather than
    release-edge for snappier UX — the menu appears the instant the
    user clicks, matching Windows/most-Linux behaviour. Caller wanting
    macOS-style release-edge can replicate the body with
    `ctx.input.mouse_released(MOJOUI_BTN_RIGHT)`.

    Note: this helper reads `ctx.input.mouse_pressed`, which is an FFI
    call. Under `mojo run` (JIT) the static call graph would normally
    fail to resolve `mojoui_get_mouse_*` — but tests pass mouse state
    via `begin_frame_no_input`, which writes the same edges into
    `ctx.input` directly, bypassing the FFI poll. Live demos build to
    a binary so the FFI links normally.
    """
    if not ctx.input.mouse_pressed(MOJOUI_BTN_RIGHT):
        return False
    # Read the mouse position from `ctx.control.mouse_pos` rather than
    # `ctx.input.mouse_pos`: control's copy is populated by both production
    # (`begin_frame` → input.poll() → control.begin_frame(mouse_pos)) AND
    # tests (`begin_frame_no_input` threads the test-supplied mouse_pos
    # directly into control). Reading from input would be stale under
    # begin_frame_no_input where input.poll() is skipped.
    var p = ctx.control.mouse_pos.copy()
    if not rect.contains(p):
        return False
    anchor = p^
    return True


def context_menu(
    mut ctx: Context,
    id_str: String,
    anchor: Vec2,
    items: List[String],
    item_width: Float32,
    mut is_open: Bool,
) -> Int32:
    """Render a context-menu popup at `anchor` when `is_open` is True.
    Returns the clicked-item index, or -1 if no item was clicked this
    frame. Clicking outside the popup closes it via the underlying
    `popup` widget's logic.

    `id_str` scopes the popup id; pair distinct context menus in the
    same window with distinct ids (e.g. `"canvas_ctx"`, `"node_ctx"`)
    so they do not collide on input claims.
    """
    return popup(ctx, id_str, anchor, items, item_width, is_open)
