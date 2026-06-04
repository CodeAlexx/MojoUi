"""MojoUI m5 — live menu-system demo.

Top-bar menubar (File / Edit / Help), each opens a popup of items below.
A "canvas" area fills the rest of the window; right-clicking the canvas
opens a context menu (Copy / Paste / Delete) anchored at the click point.
The most recent menu action is shown in a status line at the bottom.

Build + run: `pixi run menus`. Same build-then-run scaffold as `kitchen`
because the demo's right_click_at + menubar invocation reach FFI symbols
the JIT cannot dlopen (sokol input poll + tessellator sin/cos via the
background panel's draw chain).
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_CLIP, CMD_RECT, CMD_TEXT, CMD_ICON, CMD_IMAGE,
    CMD_TRIANGLES,
    CmdTriangles,
    read_cmd_rect, read_cmd_text, read_cmd_triangles,
)
from mojoui.render.backend import Backend
from mojoui.widgets.basic import label
from mojoui.widgets.menubar import menubar, MenuSpec
from mojoui.widgets.context_menu import context_menu, right_click_at
from mojoui.app.state import store_user_state, retrieve_user_state


struct MenuDemoState(Movable):
    """Persistent state. As with the kitchen sink, the Context MUST be
    kept across frames so InputState's edge detector and ControlState's
    active/focus slots survive — otherwise CTRL_RELEASED never fires and
    the menu buttons swallow every click. See
    HANDOFF_2026-05-28_KITCHEN_SINK.md "Persistent Context fix"."""

    var ctx: Context
    var menus: List[MenuSpec]
    var open_menu: Int32          # menubar caller-managed open state
    var ctx_items: List[String]   # context-menu items
    var ctx_anchor: Vec2          # captured right-click position
    var ctx_open: Bool            # context-menu open flag
    var last_action: String       # status-line label
    var font_id: UInt32

    def __init__(out self):
        self.ctx = Context()

        var file_items = List[String]()
        file_items.append(String("New"))
        file_items.append(String("Open"))
        file_items.append(String("Save"))
        file_items.append(String("Quit"))

        var edit_items = List[String]()
        edit_items.append(String("Undo"))
        edit_items.append(String("Redo"))
        edit_items.append(String("Cut"))
        edit_items.append(String("Copy"))
        edit_items.append(String("Paste"))

        var help_items = List[String]()
        help_items.append(String("Docs"))
        help_items.append(String("About"))

        var ms = List[MenuSpec]()
        ms.append(MenuSpec(String("File"), file_items^))
        ms.append(MenuSpec(String("Edit"), edit_items^))
        ms.append(MenuSpec(String("Help"), help_items^))
        self.menus = ms^

        self.open_menu = -1

        var ci = List[String]()
        ci.append(String("Copy"))
        ci.append(String("Paste"))
        ci.append(String("Delete"))
        self.ctx_items = ci^

        self.ctx_anchor = Vec2(0.0, 0.0)
        self.ctx_open = False
        self.last_action = String("(no action yet — click a menu or right-click the canvas)")
        self.font_id = 0


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    """Same walker as m4_kitchen_sink: in-document order, JUMPs are
    forward-only (current widgets emit none — popup layering happens via
    end_frame byte append, not JUMPs)."""
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                print("MojoUI m5: non-forward JUMP at", Int(prev_off))
                return
            continue
        var size = ctx.commands.size_at(off)
        if kind == CMD_RECT:
            var cmd = read_cmd_rect(ctx.commands, off)
            Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(ctx.commands, off)
            _ = Backend.draw_text(
                cmd.font_id, cmd.size_pt, cmd.text,
                cmd.pos.copy(), cmd.color.copy(),
            )
        elif kind == CMD_TRIANGLES:
            var cmd = read_cmd_triangles(ctx.commands, off)
            _dispatch_triangles(cmd)
        off = off + size


def _frame() -> None:
    var state_ptr = retrieve_user_state[MenuDemoState]()

    # Lazy font load on first frame.
    if state_ptr[].font_id == 0:
        state_ptr[].font_id = Backend.load_font(String(""))
        state_ptr[].ctx.theme.font_id = state_ptr[].font_id
        state_ptr[].ctx.theme.font_size_pt = Int32(24)
        state_ptr[].ctx.theme.row_height = Int32(36)
        state_ptr[].ctx.theme.padding = Int32(10)
        state_ptr[].ctx.theme.spacing = Int32(6)

    ref ctx = state_ptr[].ctx
    var win_w = Float32(1400.0)
    var win_h = Float32(900.0)
    ctx.begin_frame(Vec2(win_w, win_h))

    Backend.frame_begin(Color(20, 20, 26, 255))

    # Window-fill background panel for the "canvas" — fills below the
    # menubar row (row_height tall). This is what users right-click on.
    var menubar_h = Float32(ctx.theme.row_height)
    var canvas_rect = Rect(0.0, menubar_h, win_w, win_h - menubar_h - menubar_h)
    ctx.draw_rect(canvas_rect.copy(), Color(40, 40, 50, 255))

    # Right-click → open context menu. Detect BEFORE drawing the menubar
    # so the captured anchor is the literal click point. If the click
    # lands inside the menubar row, right_click_at returns False
    # (canvas_rect doesn't include the menubar), so right-clicking on a
    # menu button doesn't accidentally open the canvas context menu.
    var anchor_local = state_ptr[].ctx_anchor.copy()
    if right_click_at(ctx, canvas_rect.copy(), anchor_local):
        state_ptr[].ctx_anchor = anchor_local^
        state_ptr[].ctx_open = True
    else:
        state_ptr[].ctx_anchor = anchor_local^

    # Top menubar.
    var open_local = state_ptr[].open_menu
    var cm: Int32 = -1
    var ci: Int32 = -1
    menubar(
        ctx,
        String("main_menubar"),
        state_ptr[].menus,
        Float32(100.0),  # menu button width
        Float32(180.0),  # popup item width
        open_local, cm, ci,
    )
    state_ptr[].open_menu = open_local
    if cm >= 0 and ci >= 0:
        state_ptr[].last_action = (
            String("menubar: ")
            + state_ptr[].menus[Int(cm)].label
            + String(" → ")
            + state_ptr[].menus[Int(cm)].items[Int(ci)]
        )

    # Context menu (if open). Anchored at the captured right-click point.
    var ctx_open_local = state_ptr[].ctx_open
    var ctx_item = context_menu(
        ctx,
        String("canvas_ctx"),
        state_ptr[].ctx_anchor.copy(),
        state_ptr[].ctx_items,
        Float32(180.0),
        ctx_open_local,
    )
    state_ptr[].ctx_open = ctx_open_local
    if ctx_item >= 0:
        state_ptr[].last_action = (
            String("context: ")
            + state_ptr[].ctx_items[Int(ctx_item)]
        )

    # Status line at the bottom.
    if ctx.theme.font_id != 0:
        var status_pos = Vec2(
            Float32(ctx.theme.padding),
            win_h - menubar_h * 0.5 + Float32(ctx.theme.font_size_pt) * 0.35,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            status_pos^,
            Color(200, 200, 210, 255),
            state_ptr[].last_action,
        )

    ctx.end_frame()

    try:
        _render_command_buffer(ctx)
    except e:
        print("MojoUI walker error:", String(e))
    Backend.frame_end()


def main() raises:
    var state = MenuDemoState()
    var state_ptr = UnsafePointer(to=state)
    store_user_state(state_ptr)

    var rc = Backend.init(
        Int32(1400), Int32(900), String("MojoUI m5 — Menu System"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening menus demo — click a top menu, or right-click the canvas.")
    Backend.run_blocking(_frame)

    print(
        "PASS: m5 menus exited cleanly. last_action=",
        state.last_action,
    )
