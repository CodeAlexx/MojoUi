"""MojoUI m6 — interactive node-graph demo.

Live window exercising the node-graph interaction layer landed this
session, on top of the M2.5 canvas/registry/serde core:

  - Left-drag a node body to move it; middle-drag to pan the viewport.
  - Right-click a NODE   → context menu: Delete / Duplicate / Rename.
  - Right-click EMPTY     → add-node menu (registry builtins); click to spawn.
  - Hover a WIRE          → it thickens; left-click to select (turns
                            theme-primary); press Delete to remove it.
  - Each node shows its FIELDS as `name: value` rows (the draw_body hook).
  - Press P                → simulate a run: nodes light up RUNNING→DONE in
                            topo order (per-node progress badges).
  - Press C                → clear progress.
  - Rename                 → a text field appears in the top bar; click it,
                            type, Enter commits / Esc cancels.

Build + run: `pixi run nodegraph`. Build-then-run scaffold (like
kitchen/menus) because the canvas reaches FFI input symbols + the
text_edit rename field needs the input-text FFI the JIT cannot dlopen.
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
from mojoui.core.textedit import TextEditState
from mojoui.render.backend import Backend
from mojoui.render.ffi import (
    MOJOUI_BTN_RIGHT,
    MOJOUI_KEY_RETURN,
    MOJOUI_KEY_ESCAPE,
    MOJOUI_KEY_P,
    MOJOUI_KEY_C,
)
from mojoui.widgets.text_edit import text_edit
from mojoui.nodes.node import FieldValue
from mojoui.nodes.graph import Graph, topo_sort
from mojoui.nodes.registry import NodeRegistry, register_builtins
from mojoui.nodes.canvas import (
    CanvasState,
    canvas_screen_to_world,
    begin_node_canvas,
    end_node_canvas,
)
from mojoui.nodes.add_menu import AddMenuState, add_menu
from mojoui.nodes.node_menu import (
    node_context_menu,
    NODE_ACTION_DELETE,
    NODE_ACTION_DUPLICATE,
    NODE_ACTION_RENAME,
)
from mojoui.nodes.progress import (
    ProgressState,
    draw_progress_overlay,
    PROG_RUNNING,
    PROG_DONE,
)
from mojoui.app.state import store_user_state, retrieve_user_state


comptime _TOOLBAR_H: Float32 = 40.0
comptime _RUN_FRAMES_PER_NODE: Int = 24


struct NodeGraphDemoState(Movable):
    """Persistent state — the Context MUST survive across frames so the
    input edge-detector + control active/focus slots persist (same reason
    as kitchen/menus; both demos need a persistent Context)."""

    var ctx: Context
    var registry: NodeRegistry
    var graph: Graph
    var canvas: CanvasState
    var progress: ProgressState
    var addmenu: AddMenuState
    var rename_buffer: String
    var rename_state: TextEditState
    var run_active: Bool
    var run_order: List[UInt64]
    var run_idx: Int
    var run_tick: Int
    var last_action: String
    var font_id: UInt32

    def __init__(out self) raises:
        self.ctx = Context()
        var reg = NodeRegistry()
        register_builtins(reg)

        var g = Graph()
        # A compact ComfyUI-shaped graph so there's something to play with.
        var lc = g.id_alloc.alloc()
        g.nodes.append(
            reg.make_node(String("core/load_checkpoint"), Vec2(60.0, 120.0), lc)
        )
        var ep = g.id_alloc.alloc()
        var ep_node = reg.make_node(
            String("core/encode_prompt"), Vec2(340.0, 80.0), ep
        )
        ep_node.fields[String("text")] = FieldValue.string(
            String("a serene mountain lake")
        )
        g.nodes.append(ep_node^)
        var ks = g.id_alloc.alloc()
        g.nodes.append(
            reg.make_node(String("core/k_sampler"), Vec2(640.0, 200.0), ks)
        )
        var vd = g.id_alloc.alloc()
        g.nodes.append(
            reg.make_node(String("core/vae_decode"), Vec2(940.0, 220.0), vd)
        )
        var si = g.id_alloc.alloc()
        g.nodes.append(
            reg.make_node(String("core/save_image"), Vec2(1180.0, 240.0), si)
        )
        _ = g.add_edge(lc, String("model"), ks, String("model"))
        _ = g.add_edge(lc, String("clip"), ep, String("clip"))
        _ = g.add_edge(ep, String("cond"), ks, String("cond"))
        _ = g.add_edge(lc, String("vae"), vd, String("vae"))
        _ = g.add_edge(ks, String("latent"), vd, String("latent"))
        _ = g.add_edge(vd, String("image"), si, String("image"))

        self.registry = reg^
        self.graph = g^
        self.canvas = CanvasState()
        self.progress = ProgressState()
        self.addmenu = AddMenuState()
        self.rename_buffer = String("")
        self.rename_state = TextEditState(single_line=True)
        self.run_active = False
        self.run_order = List[UInt64]()
        self.run_idx = 0
        self.run_tick = 0
        self.last_action = String(
            "Drag nodes • R-click node/empty for menus • click a wire + Del • P=run C=clear"
        )
        self.font_id = 0


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                print("MojoUI m6: non-forward JUMP at", Int(prev_off))
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


def _tick_run(mut s: NodeGraphDemoState):
    """Advance the simulated run one frame: the current node is RUNNING;
    after `_RUN_FRAMES_PER_NODE` frames mark it DONE and start the next."""
    if not s.run_active:
        return
    s.run_tick = s.run_tick + 1
    if s.run_tick < _RUN_FRAMES_PER_NODE:
        return
    s.run_tick = 0
    if s.run_idx < len(s.run_order):
        s.progress.set_status(s.run_order[s.run_idx], PROG_DONE)
        s.run_idx = s.run_idx + 1
    if s.run_idx < len(s.run_order):
        s.progress.set_status(s.run_order[s.run_idx], PROG_RUNNING)
    else:
        s.run_active = False
        s.last_action = String("run complete")


def _ui(mut s: NodeGraphDemoState, win_w: Float32, win_h: Float32) raises:
    ref ctx = s.ctx

    # ---- Top toolbar row (hosts the rename field when renaming) ----
    var tb = List[Int32]()
    tb.append(Int32(Int(win_w)))
    ctx.layout_row(tb^, Int32(Int(_TOOLBAR_H)))
    var renaming = s.canvas.renaming_node != UInt64(0)
    if renaming:
        _ = text_edit(ctx, String("rename_field"), s.rename_buffer, s.rename_state)
    else:
        _ = ctx.layout_next()  # consume the toolbar cell to advance layout y

    # ---- Canvas fills the rest ----
    var cw = List[Int32]()
    cw.append(Int32(Int(win_w)))
    ctx.layout_row(cw^, Int32(Int(win_h - _TOOLBAR_H)))
    _ = begin_node_canvas(ctx, String("nodes"), s.canvas, s.graph)
    end_node_canvas(ctx)

    # ---- Right-click on empty canvas → add-node menu ----
    # begin_node_canvas already opened the per-node menu if RMB hit a node
    # (sets canvas.ctx_menu_open). If RMB fired this frame and no node menu
    # opened, treat it as an empty-canvas right-click → add menu.
    if ctx.input.mouse_pressed(MOJOUI_BTN_RIGHT) and not s.canvas.ctx_menu_open:
        var mp = ctx.control.mouse_pos.copy()
        if mp.y > _TOOLBAR_H:
            var world = canvas_screen_to_world(s.canvas, mp.copy())
            s.addmenu.show_at(mp.copy(), world)
    if s.canvas.ctx_menu_open:
        s.addmenu.hide()  # node menu wins over add menu

    # ---- Node context menu overlay (Delete/Duplicate/Rename) ----
    var act = node_context_menu(ctx, String("node_ctx"), s.canvas, s.graph)
    if act == NODE_ACTION_DELETE:
        s.last_action = String("deleted node")
    elif act == NODE_ACTION_DUPLICATE:
        s.last_action = String("duplicated node")
    elif act == NODE_ACTION_RENAME:
        # Seed the rename buffer from the target node's current title.
        var idx = s.graph.find_node(s.canvas.renaming_node)
        if idx >= 0:
            s.rename_buffer = s.graph.nodes[idx].title.copy()
            s.rename_state = TextEditState(single_line=True)
        s.last_action = String("renaming — click the top field, type, Enter")

    # ---- Add-node menu overlay ----
    if add_menu(ctx, String("add_menu"), s.addmenu, s.registry, s.graph):
        s.last_action = String("added node")

    # ---- Rename commit / cancel ----
    if renaming:
        if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
            var idx = s.graph.find_node(s.canvas.renaming_node)
            if idx >= 0:
                s.graph.nodes[idx].title = s.rename_buffer.copy()
            s.last_action = String("renamed → ") + s.rename_buffer
            s.canvas.renaming_node = UInt64(0)
        elif ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
            s.canvas.renaming_node = UInt64(0)
            s.last_action = String("rename cancelled")

    # ---- Run simulation controls ----
    if ctx.input.key_pressed(MOJOUI_KEY_P) and not s.run_active:
        s.progress.reset()
        s.run_order = topo_sort(s.graph)
        s.run_idx = 0
        s.run_tick = 0
        if len(s.run_order) > 0:
            s.run_active = True
            s.progress.set_status(s.run_order[0], PROG_RUNNING)
            s.last_action = String("running…")
    if ctx.input.key_pressed(MOJOUI_KEY_C):
        s.progress.reset()
        s.run_active = False
        s.last_action = String("progress cleared")
    _tick_run(s)

    # Progress badges on top of everything.
    _ = draw_progress_overlay(ctx, s.canvas, s.graph, s.progress)

    # ---- Toolbar hint + status text (drawn over the toolbar / bottom) ----
    if ctx.theme.font_id != 0:
        if not renaming:
            ctx.draw_text(
                ctx.theme.font_id, Int32(16),
                Vec2(Float32(10.0), Float32(26.0)),
                Color(180, 185, 200, 255),
                String(
                    "L-drag move | M-drag pan | R-click node=menu |"
                    " R-click empty=add | click wire+Del | P run | C clear"
                ),
            )
        ctx.draw_text(
            ctx.theme.font_id, Int32(16),
            Vec2(Float32(10.0), win_h - Float32(10.0)),
            Color(150, 200, 160, 255),
            s.last_action,
        )


def _frame() -> None:
    var sp = retrieve_user_state[NodeGraphDemoState]()

    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
        sp[].ctx.theme.font_size_pt = Int32(16)
        sp[].ctx.theme.row_height = Int32(28)
        sp[].ctx.theme.padding = Int32(8)
        sp[].ctx.theme.spacing = Int32(6)

    var win_w = Float32(1500.0)
    var win_h = Float32(950.0)
    sp[].ctx.begin_frame(Vec2(win_w, win_h))
    Backend.frame_begin(Color(18, 18, 22, 255))

    try:
        _ui(sp[], win_w, win_h)
    except e:
        print("MojoUI m6 UI error:", String(e))

    sp[].ctx.end_frame()
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m6 walker error:", String(e))
    Backend.frame_end()


def main() raises:
    var state = NodeGraphDemoState()
    var sp = UnsafePointer(to=state)
    store_user_state(sp)

    var rc = Backend.init(
        Int32(1500), Int32(950), String("MojoUI m6 — Node Graph"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening node-graph demo — right-click a node or empty canvas.")
    Backend.run_blocking(_frame)
    print("PASS: m6 node-graph exited cleanly. last_action=", state.last_action)
