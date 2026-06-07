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

from std.io.file import open
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
from mojoui.render.command_renderer import render_context_commands
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
    CanvasGroup,
    CanvasState,
    canvas_all_nodes_bounds,
    canvas_fit_rect,
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
    NODE_ACTION_COLOR,
)
from mojoui.nodes.progress import (
    ProgressState,
    draw_progress_overlay,
    PROG_RUNNING,
    PROG_DONE,
)
from mojoui.app.state import store_user_state, retrieve_user_state
from mojoui.app.inference_model import InferenceState, QueueJob
from mojoui.app.inference_graph_bridge import (
    build_klein9b_inference_graph,
    _sys_system,
    _write_text_file,
)
from mojoui.serde.comfy_workflow import parse_comfy_workflow
from mojoui.serde.workflow import emit_workflow, parse_workflow


comptime _TOOLBAR_H: Float32 = 56.0
comptime _RUN_FRAMES_PER_NODE: Int = 24
comptime _PERSIST_DIR = "/home/alex/.cache/serenityui"
comptime _PERSIST_WORKFLOW = "/home/alex/.cache/serenityui/klein9b_nodegraph.workflow.json"


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

        var inference = InferenceState()
        var display = QueueJob(
            UInt64(1),
            inference.prompt.copy(),
            Int32(Int(inference.width)),
            Int32(Int(inference.height)),
            Int32(Int(inference.steps)),
            inference.sampler_label(),
            Int64(-1),
            UInt32(0),
        )
        var g = build_klein9b_inference_graph(
            inference,
            display,
            String("/home/alex/mojodiffusion/output/serenityui_klein9b_nodes.png"),
            Int32(1024),
            Int32(1024),
        )
        try:
            var file = open(String(_PERSIST_WORKFLOW), String("r"))
            var saved = parse_workflow(file.read())
            if saved.node_count() > 0:
                g = saved^
        except e:
            pass

        self.registry = reg^
        self.graph = g^
        var canvas = CanvasState()
        canvas.pan = Vec2(110.0, 115.0)
        canvas.zoom = Float32(1.30)
        canvas.show_minimap = True
        canvas.snap_to_grid = True

        var klein_group = CanvasGroup(
            Int64(1),
            String("SerenityUI Klein 9B Generate Workflow"),
            Rect(20.0, 35.0, 2500.0, 840.0),
            Color(64, 118, 210, 68),
        )
        for i in range(self.graph.node_count()):
            klein_group.members.append(self.graph.nodes[i].id)
        canvas.groups.append(klein_group^)
        canvas.next_group_id = Int64(2)
        self.canvas = canvas^
        self.progress = ProgressState()
        self.addmenu = AddMenuState()
        self.rename_buffer = String("")
        self.rename_state = TextEditState(single_line=True)
        self.run_active = False
        self.run_order = List[UInt64]()
        self.run_idx = 0
        self.run_tick = 0
        self.last_action = String(
            "SerenityUI graph: Klein 9B checkpoint, prompts, sampler, VAE decode, save image"
        )
        self.font_id = 0


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    _ = Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    """Render through the shared live command-buffer adapter."""
    _ = render_context_commands(ctx, String("MojoUI m6"))


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


def _start_run(mut s: NodeGraphDemoState) raises:
    s.progress.reset()
    s.run_order = topo_sort(s.graph)
    s.run_idx = 0
    s.run_tick = 0
    if len(s.run_order) > 0:
        s.run_active = True
        s.progress.set_status(s.run_order[0], PROG_RUNNING)
        s.last_action = String("Generate queued on workflow DAG")
    else:
        s.run_active = False
        s.last_action = String("Generate skipped: graph has no nodes")


def _add_demo_image_node(mut s: NodeGraphDemoState) raises:
    var node_id = s.graph.id_alloc.alloc()
    var pos = s.canvas.action_anchor_world.copy()
    var node = s.registry.make_node(String("core/load_image"), pos.copy(), node_id)
    node.title = String("Image Node")
    node.size = Vec2(Float32(320.0), Float32(330.0))
    node.fields[String("path")] = FieldValue.string(
        String("/home/alex/Downloads/image (17).webp")
    )
    node.fields[String("upload_label")] = FieldValue.string(
        String("SerenityUI reference image")
    )
    s.graph.nodes.append(node^)
    s.last_action = String("added image node from /home/alex/Downloads/image (17).webp")


def _import_demo_comfy_json(mut s: NodeGraphDemoState, win_w: Float32, win_h: Float32) raises:
    var file = open(String("/home/alex/Downloads/image_ideogram4_t2i.json"), String("r"))
    var raw = file.read()
    var imported = parse_comfy_workflow(raw)
    s.graph = imported.take_graph()
    s.canvas = imported.take_canvas()
    s.canvas.show_minimap = True
    s.canvas.snap_to_grid = True
    var bounds = canvas_all_nodes_bounds(s.graph)
    if bounds[0]:
        canvas_fit_rect(
            s.canvas,
            bounds[1].copy(),
            Rect(Float32(0.0), _TOOLBAR_H, win_w, win_h - _TOOLBAR_H),
            Float32(120.0),
        )
    s.progress.reset()
    s.run_active = False
    s.last_action = String("imported Comfy workflow JSON: /home/alex/Downloads/image_ideogram4_t2i.json")


def _autosave_workflow(s: NodeGraphDemoState):
    try:
        _ = _sys_system(String("mkdir -p ") + String(_PERSIST_DIR))
        _write_text_file(String(_PERSIST_WORKFLOW), emit_workflow(s.graph))
    except e:
        pass


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
    var canvas_changed = begin_node_canvas(ctx, String("nodes"), s.canvas, s.graph)
    end_node_canvas(ctx)

    if s.canvas.generate_requested:
        _start_run(s)
    if s.canvas.add_image_requested:
        _add_demo_image_node(s)
        canvas_changed = True
    if s.canvas.import_json_requested:
        _import_demo_comfy_json(s, win_w, win_h)
        canvas_changed = True

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
        canvas_changed = True
    elif act == NODE_ACTION_DUPLICATE:
        s.last_action = String("duplicated node")
        canvas_changed = True
    elif act == NODE_ACTION_RENAME:
        # Seed the rename buffer from the target node's current title.
        var idx = s.graph.find_node(s.canvas.renaming_node)
        if idx >= 0:
            s.rename_buffer = s.graph.nodes[idx].title.copy()
            s.rename_state = TextEditState(single_line=True)
        s.last_action = String("renaming — click the top field, type, Enter")
    elif act == NODE_ACTION_COLOR:
        s.last_action = String("cycled node color")
        canvas_changed = True

    # ---- Add-node menu overlay ----
    if add_menu(ctx, String("add_menu"), s.addmenu, s.registry, s.graph):
        s.last_action = String("added node")
        canvas_changed = True

    # ---- Rename commit / cancel ----
    if renaming:
        if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
            var idx = s.graph.find_node(s.canvas.renaming_node)
            if idx >= 0:
                s.graph.nodes[idx].title = s.rename_buffer.copy()
            s.last_action = String("renamed → ") + s.rename_buffer
            s.canvas.renaming_node = UInt64(0)
            canvas_changed = True
        elif ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
            s.canvas.renaming_node = UInt64(0)
            s.last_action = String("rename cancelled")

    if canvas_changed:
        _autosave_workflow(s)

    # ---- Run simulation controls ----
    if ctx.input.key_pressed(MOJOUI_KEY_P) and not s.run_active:
        _start_run(s)
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
                ctx.theme.font_id, Int32(18),
                Vec2(Float32(14.0), Float32(35.0)),
                Color(180, 185, 200, 255),
                String(
                    "L-drag move | Shift multi-select | M-drag pan | R-click menus |"
                    " click wire+Del | R reroute | G group | F fit | P run | C clear"
                ),
            )
        ctx.draw_text(
            ctx.theme.font_id, Int32(18),
            Vec2(Float32(14.0), win_h - Float32(18.0)),
            Color(150, 200, 160, 255),
            s.last_action,
        )


def _frame() -> None:
    var sp = retrieve_user_state[NodeGraphDemoState]()

    var win = Backend.window_size()
    var win_w = win.x
    var win_h = win.y
    if win_w < Float32(320.0):
        win_w = Float32(1900.0)
    if win_h < Float32(240.0):
        win_h = Float32(1100.0)

    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
    var ui_font = Int32(16)
    sp[].ctx.theme.font_size_pt = ui_font
    sp[].ctx.theme.row_height = ui_font + Int32(14)
    sp[].ctx.theme.padding = Int32(10)
    sp[].ctx.theme.spacing = Int32(8)

    sp[].ctx.begin_frame(Vec2(win_w, win_h))
    Backend.frame_begin(Color(14, 16, 22, 255))

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
        Int32(1900), Int32(1100), String("MojoUI m6 — Node Graph"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening node-graph demo — right-click a node or empty canvas.")
    Backend.run_blocking(_frame)
    print("PASS: m6 node-graph exited cleanly. last_action=", state.last_action)
