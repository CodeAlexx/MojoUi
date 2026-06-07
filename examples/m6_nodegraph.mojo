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
)
from mojoui.nodes.progress import (
    ProgressState,
    draw_progress_overlay,
    PROG_RUNNING,
    PROG_DONE,
)
from mojoui.app.state import store_user_state, retrieve_user_state
from mojoui.serde.comfy_workflow import parse_comfy_workflow


comptime _TOOLBAR_H: Float32 = 56.0
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
        # A larger SerenityUI workflow that exercises image nodes, bboxes,
        # Ideogram prompt/generate logic, video preview, groups, minimap,
        # typed wires, and field-heavy nodes on the same canvas.
        var load_image = g.id_alloc.alloc()
        var load_image_node = reg.make_node(
            String("core/load_image"), Vec2(90.0, 180.0), load_image
        )
        load_image_node.title = String("Image Node")
        load_image_node.size = Vec2(320.0, 330.0)
        load_image_node.fields[String("path")] = FieldValue.string(
            String("/home/alex/Downloads/image (17).webp")
        )
        load_image_node.fields[String("upload_label")] = FieldValue.string(
            String("SerenityUI reference image")
        )
        g.nodes.append(load_image_node^)

        var prompt_builder = g.id_alloc.alloc()
        var prompt_builder_node = reg.make_node(
            String("core/ideogram4_prompt_builder"),
            Vec2(500.0, 80.0),
            prompt_builder,
        )
        prompt_builder_node.title = String("SerenityUI Ideogram Prompt Builder")
        prompt_builder_node.size = Vec2(640.0, 650.0)
        prompt_builder_node.fields[String("width")] = FieldValue.int_(Int64(1024))
        prompt_builder_node.fields[String("height")] = FieldValue.int_(Int64(1024))
        prompt_builder_node.fields[String("high_level_description")] = FieldValue.string(
            String("anime image-to-video layout with precise bbox composition")
        )
        prompt_builder_node.fields[String("background")] = FieldValue.string(
            String("soft-lit studio backdrop with clean depth and readable silhouettes")
        )
        prompt_builder_node.fields[String("art_style")] = FieldValue.string(
            String("anime key art, expressive line work")
        )
        prompt_builder_node.fields[String("aesthetics")] = FieldValue.string(
            String("polished, cinematic, sharp focus")
        )
        prompt_builder_node.fields[String("lighting")] = FieldValue.string(
            String("rim light, soft volumetric fill")
        )
        prompt_builder_node.fields[String("medium")] = FieldValue.string(
            String("digital painting")
        )
        prompt_builder_node.fields[String("elements_data")] = FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72},{\"label\":\"motion cue\",\"x\":0.58,\"y\":0.25,\"w\":0.26,\"h\":0.30}]")
        )
        g.nodes.append(prompt_builder_node^)

        var magic_prompt = g.id_alloc.alloc()
        var magic_prompt_node = reg.make_node(
            String("core/ideogram4_magic_prompt"),
            Vec2(1220.0, 150.0),
            magic_prompt,
        )
        magic_prompt_node.title = String("Ideogram4 Magic Prompt")
        magic_prompt_node.size = Vec2(370.0, 180.0)
        magic_prompt_node.fields[String("magic_prompt_model")] = FieldValue.string(
            String("qwen3-local-v1")
        )
        g.nodes.append(magic_prompt_node^)

        var text_preview = g.id_alloc.alloc()
        var text_preview_node = reg.make_node(
            String("core/preview_text"), Vec2(1220.0, 395.0), text_preview
        )
        text_preview_node.title = String("Prompt Preview")
        text_preview_node.size = Vec2(370.0, 230.0)
        text_preview_node.fields[String("previewMode")] = FieldValue.string(
            String("JSON + prompt text")
        )
        g.nodes.append(text_preview_node^)

        var generate = g.id_alloc.alloc()
        var generate_node = reg.make_node(
            String("core/ideogram4_generate"), Vec2(1700.0, 130.0), generate
        )
        generate_node.title = String("Ideogram4 Generate GPU")
        generate_node.size = Vec2(380.0, 270.0)
        generate_node.fields[String("preset")] = FieldValue.string(
            String("V4_QUALITY_48")
        )
        generate_node.fields[String("steps")] = FieldValue.int_(Int64(48))
        generate_node.fields[String("magic_prompt")] = FieldValue.bool_(True)
        g.nodes.append(generate_node^)

        var save_image = g.id_alloc.alloc()
        var save_image_node = reg.make_node(
            String("core/save_image"), Vec2(2220.0, 205.0), save_image
        )
        save_image_node.title = String("Save / Preview Image")
        save_image_node.size = Vec2(330.0, 125.0)
        save_image_node.fields[String("path")] = FieldValue.string(
            String("/home/alex/mojodiffusion/output/ideogram4_generated_1024.png")
        )
        g.nodes.append(save_image_node^)

        var load_video = g.id_alloc.alloc()
        var load_video_node = reg.make_node(
            String("core/load_video"), Vec2(500.0, 850.0), load_video
        )
        load_video_node.title = String("Load Video")
        load_video_node.size = Vec2(330.0, 145.0)
        load_video_node.fields[String("path")] = FieldValue.string(
            String("/home/alex/Downloads/lance_i2v_anime.mp4")
        )
        load_video_node.fields[String("frame_count")] = FieldValue.int_(Int64(96))
        g.nodes.append(load_video_node^)

        var preview_video = g.id_alloc.alloc()
        var preview_video_node = reg.make_node(
            String("core/preview_video"), Vec2(930.0, 850.0), preview_video
        )
        preview_video_node.title = String("Preview Video")
        preview_video_node.size = Vec2(340.0, 160.0)
        preview_video_node.fields[String("autoplay")] = FieldValue.bool_(True)
        preview_video_node.fields[String("loop")] = FieldValue.bool_(True)
        g.nodes.append(preview_video_node^)

        _ = g.add_edge(load_image, String("image"), prompt_builder, String("image"))
        _ = g.add_edge(prompt_builder, String("prompt"), magic_prompt, String("prompt"))
        _ = g.add_edge(prompt_builder, String("prompt"), text_preview, String("source"))
        _ = g.add_edge(magic_prompt, String("caption_json"), generate, String("caption_json"))
        _ = g.add_edge(generate, String("image"), save_image, String("image"))
        _ = g.add_edge(load_video, String("video"), preview_video, String("video"))

        self.registry = reg^
        self.graph = g^
        var canvas = CanvasState()
        canvas.pan = Vec2(100.0, 96.0)
        canvas.zoom = Float32(1.0)
        canvas.show_minimap = True
        canvas.snap_to_grid = True

        var image_group = CanvasGroup(
            Int64(1),
            String("SerenityUI Ideogram Image Workflow"),
            Rect(45.0, 35.0, 2610.0, 755.0),
            Color(64, 118, 210, 68),
        )
        image_group.members.append(load_image)
        image_group.members.append(prompt_builder)
        image_group.members.append(magic_prompt)
        image_group.members.append(text_preview)
        image_group.members.append(generate)
        image_group.members.append(save_image)
        canvas.groups.append(image_group^)

        var video_group = CanvasGroup(
            Int64(2),
            String("Video Preview Lane"),
            Rect(455.0, 805.0, 860.0, 245.0),
            Color(80, 180, 190, 58),
        )
        video_group.members.append(load_video)
        video_group.members.append(preview_video)
        canvas.groups.append(video_group^)
        canvas.next_group_id = Int64(3)
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
            "SerenityUI graph: image bbox builder, Ideogram GPU nodes, video preview, groups, minimap"
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

    if s.canvas.generate_requested:
        _start_run(s)
    if s.canvas.add_image_requested:
        _add_demo_image_node(s)
    if s.canvas.import_json_requested:
        _import_demo_comfy_json(s, win_w, win_h)

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
