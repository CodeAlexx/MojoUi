"""Per-frame `Context` — microui `mu_Context` equivalent.

Owns all per-frame state: id_stack, layout, commands, control (hover/focus/
active), input, theme, window_rect, and a reserved container_jump_offset for
future M2 container z-order. Widget functions (chunk 17+) take `mut ctx:
Context` and use the forwarder methods (`get_id`, `layout_next`,
`update_control`, `draw_rect`, `draw_text`) instead of touching the sub-
components directly.

Lifecycle per frame:
    ctx.begin_frame(window_size)   # poll input, reset, push root layout
    ...widget calls...
    ctx.end_frame()                # finalise control, pop root layout
    ...renderer adapter walks ctx.commands and submits to Backend...

Mirrors microui per `internal audit notes` "The Context
Struct (mu_Context)". Does NOT add: widgets (c17+), containers/windows (M2),
the full theme system (M3), or the renderer adapter.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import (
    ImmediateId,
    IMM_ID_NONE,
    hash_str,
    derive_id,
    FNV1A_OFFSET_32,
)
from mojoui.core.commands import CommandBuffer
from mojoui.core.layout import LayoutStack
from mojoui.core.control import ControlState, update_control as _ctrl_update_control
from mojoui.core.input import InputState
from mojoui.render.ffi import (
    MOJOUI_KEY_TAB,
    MOJOUI_KEY_LSHIFT,
    MOJOUI_KEY_RSHIFT,
)


# ============================================================================
# Draw layers — popup z-order without JUMP patching (M5 chunk: menu system)
# ============================================================================
# Microui z-orders containers via emit-in-order + JUMP-patch-at-end. We achieve
# the same effect with a second `CommandBuffer` (`popup_commands`) that holds
# all draws emitted between `begin_popup`/`end_popup`. At `end_frame` the popup
# bytes are appended onto the primary `commands` buffer — so they walk LAST
# and render ON TOP of every base-layer widget that drew earlier in the frame.
# This is simpler than JUMP-patching (no walker changes) and gives the menu
# system its z-order primitive. Tradeoff: the popup buffer is allocated even
# when no popup opens (cheap — it's an empty List[UInt8] each frame).

comptime LAYER_BASE: Int32 = 0
"""Default draw layer. Walks first → renders below popups."""

comptime LAYER_POPUP: Int32 = 1
"""Popup overlay layer. All draws between `begin_popup`/`end_popup` land here;
appended to the main buffer at `end_frame` → walks LAST → renders ON TOP."""


# ============================================================================
# DefaultTheme — minimal placeholder until the full M3 theme lands
# ============================================================================
# Minimal token set so chunk-17 widgets can paint defaults without depending
# on the full M3 token-based theme. Replace wholesale via `Context.set_theme`.
# `Copyable, Movable` — reads must `.copy()` (Mojo implementation notes
# "Copyable ≠ ImplicitlyCopyable").


struct DefaultTheme(Copyable, Movable):
    """Minimal theme placeholder. Defaults follow egui-dark + microui spacing
    (24 px row, 4 px spacing, 6 px padding, 14 pt text)."""

    var bg: Color           # window/container background
    var fg: Color           # foreground (text on bg)
    var primary: Color      # accent (focus rings, slider/progress fill, links)
    var control_bg: Color   # resting fill of input controls (combobox/button/
                            # drag_value). Split from `primary` so an app can
                            # have neutral controls AND a vivid accent. Defaults
                            # to `primary` so existing callers are unchanged.
    var hover_bg: Color     # background under hovered widgets
    var active_bg: Color    # background under pressed (active) widgets
    var border: Color       # border / separator color
    var text: Color         # default text color (== fg by default)

    # Extended semantic palette. These mirror mojoui.theme.tokens.ColorTokens
    # so apps can theme all surfaces/states through ctx.theme without needing
    # a second token object at every widget call.
    var bg_panel: Color
    var bg_surface: Color
    var bg_input: Color
    var floating_bg: Color
    var faint_bg: Color
    var extreme_bg: Color
    var text_subdued: Color
    var text_disabled: Color
    var text_on_accent: Color
    var text_strong: Color
    var primary_hover: Color
    var primary_active: Color
    var border_strong: Color
    var separator: Color
    var selection_bg: Color
    var selection_stroke: Color
    var focus_outline: Color
    var info_bg: Color
    var info_text: Color
    var warning_bg: Color
    var warning_text: Color
    var error_bg: Color
    var error_text: Color
    var success_bg: Color
    var success_text: Color
    var graph_canvas_bg: Color
    var graph_node_bg: Color
    var graph_node_selected_bg: Color
    var graph_node_title_bg: Color

    var font_id: UInt32     # default font id (0 until set_default_font called)
    var font_size_pt: Int32 # default text size in points (14)
    var row_height: Int32   # default layout row height in px (24)
    var spacing: Int32      # default gap between slots (4 px, microui default)
    var padding: Int32      # default padding around widget content (6 px)

    def __init__(out self):
        self.bg = Color(24, 24, 28, 255)
        self.fg = Color(225, 225, 235, 255)
        self.primary = Color(110, 90, 200, 255)
        self.control_bg = Color(110, 90, 200, 255)  # == primary: preserves
        #                                              pre-split widget look
        self.hover_bg = Color(50, 50, 60, 255)
        self.active_bg = Color(80, 70, 140, 255)
        self.border = Color(70, 70, 80, 255)
        self.text = Color(225, 225, 235, 255)

        self.bg_panel = self.bg.copy()
        self.bg_surface = self.hover_bg.copy()
        self.bg_input = self.control_bg.copy()
        self.floating_bg = Color(36, 38, 44, 255)
        self.faint_bg = Color(32, 34, 40, 255)
        self.extreme_bg = Color(8, 9, 12, 255)
        self.text_subdued = Color(150, 150, 165, 255)
        self.text_disabled = Color(80, 80, 90, 255)
        self.text_on_accent = Color(255, 255, 255, 255)
        self.text_strong = Color(250, 250, 255, 255)
        self.primary_hover = Color(130, 110, 220, 255)
        self.primary_active = self.active_bg.copy()
        self.border_strong = Color(90, 94, 102, 255)
        self.separator = self.border.copy()
        self.selection_bg = Color(70, 90, 160, 200)
        self.selection_stroke = Color(120, 140, 220, 255)
        self.focus_outline = self.primary_hover.copy()
        self.info_bg = Color(50, 90, 140, 255)
        self.info_text = Color(200, 220, 240, 255)
        self.warning_bg = Color(160, 110, 30, 255)
        self.warning_text = Color(240, 220, 180, 255)
        self.error_bg = Color(160, 50, 50, 255)
        self.error_text = Color(240, 200, 200, 255)
        self.success_bg = Color(50, 130, 60, 255)
        self.success_text = Color(200, 240, 200, 255)
        self.graph_canvas_bg = Color(15, 15, 18, 255)
        self.graph_node_bg = Color(40, 40, 50, 240)
        self.graph_node_selected_bg = Color(60, 60, 90, 240)
        self.graph_node_title_bg = Color(60, 70, 110, 255)

        self.font_id = 0
        self.font_size_pt = 14
        self.row_height = 24
        self.spacing = 4
        self.padding = 6


# ============================================================================
# Context — the per-frame coordinator
# ============================================================================


struct Context(Movable):
    """The MojoUI per-frame context. Equivalent of microui's `mu_Context`.

    Movable-not-Copyable: there is exactly ONE Context per window. Silently
    duplicating it would split the id_stack / control slots and break
    interaction state — same discipline microui enforces by passing
    `mu_Context*` everywhere.

    Per-frame lifecycle: `begin_frame(window_size)` → widget calls →
    `end_frame()` → renderer adapter consumes `ctx.commands`.
    """

    # ---- State owned by Context (see module docstring for the ownership map) ----

    var id_stack: List[ImmediateId]   # contextual hashing parent chain
    var layout: LayoutStack           # row/column flow positioning
    var commands: CommandBuffer       # accumulated draw commands this frame
    var control: ControlState         # hover/focus/active slots
    var input: InputState             # mouse + keyboard + edge detection
    var theme: DefaultTheme           # bg/fg/primary/font_id/sizes
    var window_rect: Rect             # window bounds (set by begin_frame)
    var _container_jump_offset: Int32 # reserved for M2 container z-order (-1)

    # ---- M5 menu-system: popup layer ----
    var popup_commands: CommandBuffer  # draws emitted between begin/end_popup
    """Secondary draw buffer for popup-layer commands. Concatenated onto
    `commands` in `end_frame` so popups render on top. Reset per frame in
    `_begin_frame_common`. See `begin_popup` / `end_popup`."""

    var active_layer: Int32           # LAYER_BASE or LAYER_POPUP
    """Which buffer subsequent `draw_*` forwarders write to. Toggled by
    `begin_popup` / `end_popup`. Nested popups push the int but do not
    bookkeep a stack — every `end_popup` resets to LAYER_BASE. Callers MUST
    pair begin/end within the same widget call."""

    var clipboard: String
    """In-app clipboard for text widgets (Ctrl+C / Ctrl+X / Ctrl+V). Persists
    across frames. Not wired to the OS clipboard yet — copy/paste works
    within the running app only. A future chunk can back this with an FFI
    `mojoui_set_clipboard` / `mojoui_get_clipboard` if cross-app paste is
    needed."""

    var popup_rects: List[Rect]
    """Per-frame list of open-popup rectangles (window-space). Used by
    `update_control` to suppress base-layer hover/active claims when the
    cursor is inside any open popup — without this, a button under an open
    menu would steal the click. Cleared in `_begin_frame_common`. Each
    `begin_popup(rect)` appends; `end_popup()` does NOT pop (popups remain
    "visible to input" for the rest of the frame even after their draws
    finished — same model as microui's container_stack)."""

    var caret_visible: Bool
    """Caret-blink phase for text widgets (text_edit / text_area). True = the
    caret is drawn this frame, False = hidden (the "off" half of a blink).
    Defaults to True so headless tests + static frames always draw the caret
    (their draw-command assertions don't depend on blink phase). Live demos
    drive it via `set_caret_blink(elapsed_secs)` from their FrameTimer; the
    blink is purely cosmetic and never affects editing logic."""

    # ---- Construction ----

    def __init__(out self):
        """Construct an empty Context. No window yet — `begin_frame` is
        required before any widget call.
        """
        self.id_stack = List[ImmediateId]()
        self.layout = LayoutStack()
        self.commands = CommandBuffer()
        self.control = ControlState()
        self.input = InputState()
        self.theme = DefaultTheme()
        self.window_rect = Rect(0.0, 0.0, 0.0, 0.0)
        self._container_jump_offset = -1
        self.popup_commands = CommandBuffer()
        self.active_layer = LAYER_BASE
        self.clipboard = String("")
        self.popup_rects = List[Rect]()
        self.caret_visible = True

    # ---- Caret blink ----

    def set_caret_blink(mut self, elapsed_secs: Float64):
        """Update `caret_visible` from a monotonically-increasing elapsed
        time (seconds). Standard 1 Hz blink: on for the first half-second of
        each second, off for the second half. Cosmetic only — call once per
        frame from a live demo's FrameTimer-derived clock. Headless tests
        leave the default (always on)."""
        var period = 1.0
        var phase = elapsed_secs - Float64(Int(elapsed_secs / period)) * period
        self.caret_visible = phase < (period * 0.5)

    # ---- Frame lifecycle ----

    def begin_frame(mut self, window_size: Vec2):
        """Start a frame.

        Order:
          1. Record window bounds from `window_size`.
          2. Poll input (mouse + keyboard + edges) from the C floor.
          3. Forward mouse pos + LMB edges to `control.begin_frame`.
          4. Reset `layout` + `commands` + `id_stack` + jump offset.
          5. Push the root layout frame covering `window_rect`.

        After this call the stack invariant is:
            id_stack       — empty
            layout.depth() — 1 (root frame covering window_rect)
            commands       — empty
            control.hover  — IMM_ID_NONE (cleared each frame; focus/active stick)

        JIT note: `input.poll()` resolves to `mojoui_get_mouse_*` / `_get_key`
        C symbols. Under `mojo run` (JIT) the shared library is NOT auto-loaded
        — see Mojo implementation notes "mojo run (JIT) does NOT dlopen the shared
        library". For headless tests, use `begin_frame_no_input(window_size,
        mouse_pos, pressed, released)` to bypass the FFI poll. In production
        (where `Backend.run_blocking` is in the call graph) the JIT does
        resolve the symbols and poll runs normally.
        """
        # 1. Window bounds.
        self.window_rect = Rect(0.0, 0.0, window_size.x, window_size.y)
        # 2. Sample current input state from C floor.
        self.input.poll()
        # 3. Thread mouse pos + LMB edges + Tab/Shift state into control
        # state. Vec2 is Copyable-not-ImplicitlyCopyable so the read needs
        # `.copy()` — see Mojo implementation notes "Copyable ≠ ImplicitlyCopyable".
        var pressed = self.input.mouse_pressed(0)   # MOJOUI_BTN_LEFT = 0
        var released = self.input.mouse_released(0)
        # c52: Tab/Shift state for keyboard focus cycling. Tab fires on the
        # rising edge (one frame per press); Shift is level-triggered (either
        # L or R counts).
        var tab_pressed = self.input.key_pressed(MOJOUI_KEY_TAB)
        var shift_held = (
            self.input.key_held(MOJOUI_KEY_LSHIFT)
            or self.input.key_held(MOJOUI_KEY_RSHIFT)
        )
        self._begin_frame_common(
            self.input.mouse_pos.copy(),
            pressed,
            released,
            tab_pressed,
            shift_held,
        )

    def begin_frame_no_input(
        mut self,
        window_size: Vec2,
        mouse_pos: Vec2,
        mouse_pressed: Bool,
        mouse_released: Bool,
        tab_pressed: Bool = False,
        shift_held: Bool = False,
    ):
        """Test-friendly variant of `begin_frame` that takes mouse state
        externally instead of polling the C floor. Use in unit tests so
        the JIT does not need to resolve `mojoui_get_*` symbols (see the
        JIT note on `begin_frame`). Production code uses `begin_frame`.

        c52: `tab_pressed` + `shift_held` default to False so existing
        callers (every prior test fixture) keep working with no changes.
        Tests that exercise tab-focus-cycling pass them explicitly.
        """
        self.window_rect = Rect(0.0, 0.0, window_size.x, window_size.y)
        self._begin_frame_common(
            mouse_pos.copy(),
            mouse_pressed,
            mouse_released,
            tab_pressed,
            shift_held,
        )

    def _begin_frame_common(
        mut self,
        mouse_pos: Vec2,
        mouse_pressed: Bool,
        mouse_released: Bool,
        tab_pressed: Bool,
        shift_held: Bool,
    ):
        """Shared frame-start body for `begin_frame` and `begin_frame_no_input`.
        Threads mouse + Tab/Shift state into control, resets per-frame state,
        pushes the root layout frame.
        """
        self.control.begin_frame(
            mouse_pos.copy(),
            mouse_pressed,
            mouse_released,
            tab_pressed,
            shift_held,
        )
        self.layout.reset()
        self.commands.reset()
        self.popup_commands.reset()
        self.active_layer = LAYER_BASE
        self.popup_rects = List[Rect]()
        self.id_stack = List[ImmediateId]()
        self._container_jump_offset = -1
        # Rect is Copyable-not-ImplicitlyCopyable so the read needs `.copy()`.
        self.layout.push(self.window_rect.copy())

    def end_frame(mut self):
        """End the frame.

        Finalises control state (clears `active` on mouse-release) and pops
        the root layout frame pushed by `begin_frame`. After this call
        `layout.depth()` returns 0 again — no state leaks between frames.

        Widget code that pushed extra layout frames or extra id_stack
        entries is expected to balance its own pushes/pops; this method
        does NOT enforce that balance (microui pattern: caller discipline),
        but it DOES print a one-line warning if the stack depth at entry
        exceeds 1 (orphaned begin_column without matching end_column —
        see regression notes FRAGILE #3). The orphans are
        popped here regardless; the next `begin_frame` would clear them
        via `layout.reset()` but the misbalanced widget's children would
        already have drawn against the wrong body, so naming the leak
        loudly is the only practical aid.
        """
        self.control.end_frame()
        var leaked = Int(self.layout.depth()) - 1
        if leaked > 0:
            print(
                "MojoUI: layout stack leaked",
                leaked,
                "frames at end_frame (forgot end_column?)",
            )
        while self.layout.depth() > 0:
            self.layout.pop()

        # M5 menu-system: append the popup layer's bytes onto the main
        # buffer so the renderer walks them LAST — popup draws end up on
        # top of every base-layer widget. No JUMP patching needed; ordering
        # is byte-level. `popup_commands` is reset in next `_begin_frame_common`.
        var n_popup = self.popup_commands.byte_count()
        if n_popup > 0:
            for i in range(n_popup):
                self.commands.bytes.append(self.popup_commands.bytes[i])

        # Reset active_layer back to BASE in case a widget forgot end_popup.
        # The next frame's _begin_frame_common also does this; doing it here
        # too means a caller that reads ctx.active_layer between frames sees
        # the stable post-frame value rather than a leaked LAYER_POPUP.
        self.active_layer = LAYER_BASE

    # ---- M5 popup layer ----

    def begin_popup(mut self, rect: Rect):
        """Begin a popup overlay. Subsequent `draw_rect` / `draw_text` /
        `draw_clip` calls route to `popup_commands` instead of the main
        buffer; at `end_frame` those bytes are appended onto the main
        buffer so the popup renders on top.

        `rect` is the popup's window-space bounding box. It's recorded in
        `popup_rects` so base-layer widgets whose `update_control` runs
        AFTER this call will see "mouse inside popup" and skip claiming
        hover/active — preventing a button under an open menu from
        stealing the click.

        Pair every `begin_popup` with `end_popup`. Nested popups (submenu
        opened from a popup item) are allowed; `popup_rects` simply grows.

        Note: only `draw_rect` / `draw_text` / `draw_clip` / `draw_image` honour the
        active layer today (the set of forwarders the menu primitives
        need). Widgets that bypass Context and call
        `ctx.commands.emit_*` directly stay on the base buffer regardless.
        Extend this list (and add `draw_icon` / `draw_triangles`
        forwarders) when a popup needs those primitives.
        """
        self.active_layer = LAYER_POPUP
        self.popup_rects.append(rect.copy())

    def end_popup(mut self):
        """End the current popup overlay. Restores `active_layer` to
        `LAYER_BASE`. Does NOT pop `popup_rects` — open popups remain
        "visible to input" for the rest of the frame so widgets that draw
        AFTER the popup also skip claims under it."""
        self.active_layer = LAYER_BASE

    def _mouse_in_any_popup(self) -> Bool:
        """True iff the current mouse position is inside any popup rect
        recorded this frame. Used by `update_control` to suppress base-
        layer claims under open popups."""
        var p = self.control.mouse_pos.copy()
        for i in range(len(self.popup_rects)):
            if self.popup_rects[i].contains(p):
                return True
        return False

    # ---- ID stack helpers ----

    def push_id_str(mut self, key: String):
        """Push a new contextual ID derived from `key`, seeded by the
        current top of the id_stack (or `IMM_ID_NONE` if the stack is
        empty). The hashed ID becomes the new top — subsequent `get_id`
        calls derive off it.
        """
        var parent = IMM_ID_NONE
        if len(self.id_stack) > 0:
            parent = self.id_stack[len(self.id_stack) - 1]
        var new_id = derive_id(parent, key)
        self.id_stack.append(new_id)

    def pop_id(mut self):
        """Pop the top of the id_stack. No-op if empty (caller error)."""
        if len(self.id_stack) > 0:
            _ = self.id_stack.pop()

    def get_id(self, key: String) -> ImmediateId:
        """Compute an `ImmediateId` for `key` under the current id_stack
        top WITHOUT pushing. This is what widgets call to derive their
        own per-frame ID. If the id_stack is empty, returns the bare
        `hash_str(key)` (top-level widget).
        """
        var parent = IMM_ID_NONE
        if len(self.id_stack) > 0:
            parent = self.id_stack[len(self.id_stack) - 1]
        if UInt32(parent) == UInt32(IMM_ID_NONE):
            return hash_str(key)
        return derive_id(parent, key)

    # ---- Layout shortcuts (forward to LayoutStack) ----

    def layout_row(mut self, var widths: List[Int32], height: Int32):
        """Begin a new layout row. Forward to `LayoutStack.row` — see
        `layout.mojo` for width/height resolution rules. Takes `widths`
        by move (`var` parameter = by-value owned)."""
        self.layout.row(widths^, height)

    def layout_next(mut self) -> Rect:
        """Return the next layout slot's screen-space Rect and advance
        the cursor. Forward to `LayoutStack.next`."""
        return self.layout.next()

    def begin_column(mut self):
        """Push a nested column layout frame. Forward to
        `LayoutStack.begin_column`."""
        self.layout.begin_column()

    def end_column(mut self):
        """Pop the current nested column. Forward to
        `LayoutStack.end_column`."""
        self.layout.end_column()

    def begin_panel(mut self, rect: Rect):
        """Push an explicit absolute layout panel.

        Unlike `begin_column`, this does not consume a slot from the parent
        flow. Use it for app-level panes whose x/y/w/h are computed directly.
        """
        self.layout.push(rect)

    def end_panel(mut self):
        """Pop a panel previously pushed with `begin_panel`."""
        self.layout.pop()

    # ---- Control shortcut ----

    def update_control(mut self, id: ImmediateId, rect: Rect, opts: Int32) -> Int32:
        """Microui-style interaction tick for one widget. Forward to the
        free-function `update_control` from `core/control.mojo` — see that
        module for the CTRL_*/OPT_* flag contract.

        M5 popup layer: when `active_layer == LAYER_BASE` and the mouse is
        inside any open popup rect, this widget is "under a menu" — skip
        the interaction tick entirely so the popup wins the click. Widgets
        running in `LAYER_POPUP` (e.g. menu items) bypass the gate and
        update normally.
        """
        if self.active_layer == LAYER_BASE and self._mouse_in_any_popup():
            return 0
        return _ctrl_update_control(self.control, id, rect, opts)

    # ---- Theme accessors ----

    def set_default_font(mut self, font_id: UInt32):
        """Set the theme's default font id. App typically calls this once
        after `Backend.load_font` so subsequent `draw_text` calls can use
        `ctx.theme.font_id` without re-threading the id."""
        self.theme.font_id = font_id

    def set_theme(mut self, theme: DefaultTheme):
        """Replace the active theme wholesale. M3 will swap `DefaultTheme`
        for a richer token-based type; for now this is a `DefaultTheme`-in
        / `DefaultTheme`-out setter."""
        self.theme = theme.copy()

    # ---- Convenience draw forwarders ----
    #
    # Thin wrappers around `commands.emit_*` so widget code reads as
    # `ctx.draw_rect(rect, color)` rather than `_ = ctx.commands.emit_rect(...)`.
    # The emit functions return a Int32 byte offset (used by JUMP patching);
    # widgets that don't need the offset use these wrappers and discard it.

    def draw_rect(mut self, rect: Rect, color: Color):
        """Append a filled-rect draw command. Discards the emit offset.

        Routes to `popup_commands` when `active_layer == LAYER_POPUP` so
        popup draws end up appended after every base-layer draw at
        `end_frame` (z-order on top)."""
        if self.active_layer == LAYER_POPUP:
            _ = self.popup_commands.emit_rect(rect, color)
        else:
            _ = self.commands.emit_rect(rect, color)

    def draw_text(
        mut self,
        font_id: UInt32,
        size_pt: Int32,
        pos: Vec2,
        color: Color,
        text: String,
    ):
        """Append a text draw command. UTF-8 bytes of `text` are copied
        into the command buffer (no NUL — length carried by the prefix).
        Routes to popup layer when active."""
        if self.active_layer == LAYER_POPUP:
            _ = self.popup_commands.emit_text(font_id, size_pt, pos, color, text)
        else:
            _ = self.commands.emit_text(font_id, size_pt, pos, color, text)

    def draw_clip(mut self, rect: Rect):
        """Append a clip-rect draw command. Subsequent draws should be
        clipped to `rect` by the renderer adapter (sets sokol scissor).
        Routes to popup layer when active."""
        if self.active_layer == LAYER_POPUP:
            _ = self.popup_commands.emit_clip(rect)
        else:
            _ = self.commands.emit_clip(rect)

    def draw_image(mut self, rect: Rect, texture_id: UInt32, tint: Color):
        """Append a textured-rect draw command. Routes to popup layer when
        active so lightboxes and other overlays can render images above the
        base UI."""
        if self.active_layer == LAYER_POPUP:
            _ = self.popup_commands.emit_image(rect, texture_id, tint)
        else:
            _ = self.commands.emit_image(rect, texture_id, tint)

    def reset_clip(mut self):
        """Restore clipping to the full current window rect."""
        self.draw_clip(self.window_rect.copy())
