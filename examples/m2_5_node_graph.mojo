"""MojoUI M2.5 capstone — node graph + serde demo.

Static single-frame walk-through proving every M2.5 chunk composes end-to-end:
  c32 Node + FieldValue
  c33 Port + NodeValueType
  c34 JSON
  c35 VersionPeek
  c36 Graph + topo_sort
  c37 NodeRegistry + builtins
  c38 Wires
  c39 NodeCanvas widget
  c40 AddMenuState
  c41 emit_workflow / parse_workflow

Run via:
    pixi run nodes

Builds a typical ComfyUI workflow (LoadCheckpoint -> EncodePrompts ->
KSampler -> VAEDecode -> SaveImage), serializes to JSON, parses back,
verifies round-trip + byte-equivalence, renders one canvas frame.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_NONE, CMD_JUMP, CMD_CLIP, CMD_RECT, CMD_TEXT, CMD_ICON, CMD_IMAGE,
)
from mojoui.core.id import RetainedId
from mojoui.nodes.node import Node, FieldValue
from mojoui.nodes.graph import Graph, Edge, topo_sort
from mojoui.nodes.registry import NodeRegistry, register_builtins
from mojoui.nodes.canvas import CanvasState, begin_node_canvas, end_node_canvas
from mojoui.nodes.add_menu import AddMenuState, add_menu
from mojoui.serde.workflow import emit_workflow, parse_workflow


def _build_workflow_graph(registry: NodeRegistry) raises -> Graph:
    """Spawn a 5-node ComfyUI-shaped graph and wire it up."""
    var graph = Graph()

    # LoadCheckpoint -> outputs model/clip/vae
    var lc_id = graph.id_alloc.alloc()
    var lc = registry.make_node(
        String("core/load_checkpoint"), Vec2(40.0, 40.0), lc_id
    )
    graph.nodes.append(lc^)

    # EncodePrompt (positive conditioning)
    var ep_cond_id = graph.id_alloc.alloc()
    var ep_cond = registry.make_node(
        String("core/encode_prompt"), Vec2(280.0, 20.0), ep_cond_id
    )
    ep_cond.fields[String("text")] = FieldValue.string(
        String("a photo of a mountain lake")
    )
    graph.nodes.append(ep_cond^)

    # EncodePrompt (negative conditioning)
    var ep_uncond_id = graph.id_alloc.alloc()
    var ep_uncond = registry.make_node(
        String("core/encode_prompt"), Vec2(280.0, 140.0), ep_uncond_id
    )
    ep_uncond.fields[String("text")] = FieldValue.string(
        String("ugly, blurry")
    )
    graph.nodes.append(ep_uncond^)

    # KSampler -> denoise step
    var ks_id = graph.id_alloc.alloc()
    var ks = registry.make_node(
        String("core/k_sampler"), Vec2(540.0, 80.0), ks_id
    )
    ks.fields[String("seed")] = FieldValue.int_(Int64(42))
    ks.fields[String("steps")] = FieldValue.int_(Int64(30))
    ks.fields[String("cfg")] = FieldValue.number(Float64(7.5))
    graph.nodes.append(ks^)

    # VAEDecode -> latent to image
    var vd_id = graph.id_alloc.alloc()
    var vd = registry.make_node(
        String("core/vae_decode"), Vec2(800.0, 80.0), vd_id
    )
    graph.nodes.append(vd^)

    # SaveImage -> terminal sink
    var si_id = graph.id_alloc.alloc()
    var si = registry.make_node(
        String("core/save_image"), Vec2(1040.0, 80.0), si_id
    )
    si.fields[String("path")] = FieldValue.string(String("output.png"))
    graph.nodes.append(si^)

    # Edges: LoadCheckpoint outputs model/clip/vae feed downstream.
    # NOTE: the c37 builtin k_sampler typedef does not declare an "uncond"
    # input port (it ships model/cond/uncond/latent/output-latent). We wire
    # by port name per the EriGui invariant — the Graph storage layer
    # records any (from_port, to_port) string pair without validating
    # against the registry; type-checking lives in the canvas widget.
    _ = graph.add_edge(lc_id, String("clip"), ep_cond_id, String("clip"))
    _ = graph.add_edge(lc_id, String("clip"), ep_uncond_id, String("clip"))
    _ = graph.add_edge(lc_id, String("model"), ks_id, String("model"))
    _ = graph.add_edge(ep_cond_id, String("cond"), ks_id, String("cond"))
    _ = graph.add_edge(ep_uncond_id, String("cond"), ks_id, String("uncond"))
    _ = graph.add_edge(lc_id, String("vae"), vd_id, String("vae"))
    _ = graph.add_edge(ks_id, String("latent"), vd_id, String("latent"))
    _ = graph.add_edge(vd_id, String("image"), si_id, String("image"))
    return graph^


def main() raises:
    # === Step 1: registry ===
    var registry = NodeRegistry()
    register_builtins(registry)
    print("Registry: ", len(registry.all_type_ids()), " builtin node types")

    # === Step 2: build graph ===
    var graph = _build_workflow_graph(registry)
    print("Graph: ", graph.node_count(), " nodes, ", graph.edge_count(), " edges")

    # === Step 3: topo sort ===
    var order = topo_sort(graph)
    print("Topo order: ", len(order), " nodes (cycle-free)")

    # === Step 4: emit workflow ===
    var json_text = emit_workflow(graph)
    print("Emitted workflow JSON: ", json_text.byte_length(), " bytes")

    # === Step 5: parse workflow ===
    var parsed = parse_workflow(json_text.copy())
    print(
        "Parsed back: ",
        parsed.node_count(),
        " nodes, ",
        parsed.edge_count(),
        " edges",
    )

    # === Step 6: structural equality (node + edge counts) ===
    if parsed.node_count() != graph.node_count():
        raise Error("node count mismatch after parse")
    if parsed.edge_count() != graph.edge_count():
        raise Error("edge count mismatch after parse")

    # === Step 7: byte-equivalent round-trip ===
    var json_text2 = emit_workflow(parsed)
    if json_text != json_text2:
        raise Error("byte-equivalent round-trip failed; emit(parse(json)) != json")
    print(
        "Round-trip byte-equivalent: ",
        json_text2.byte_length(),
        " bytes preserved exactly",
    )

    # === Step 8: static canvas frame ===
    var ctx = Context()
    # c10 deterministic-FFI trick: non-zero font_id so CMD_TEXT records
    # actually emit (the FRAGILE #5 guard short-circuits at font_id == 0).
    ctx.set_default_font(UInt32(1))
    var canvas_state = CanvasState()
    var menu_state = AddMenuState()
    ctx.begin_frame_no_input(
        Vec2(1280.0, 720.0), Vec2(0.0, 0.0), False, False
    )
    # One row covering the full window — the canvas widget consumes the
    # whole slot via `layout_next`.
    var widths = List[Int32]()
    widths.append(Int32(1280))
    ctx.layout_row(widths^, Int32(720))
    _ = begin_node_canvas(ctx, String("main_canvas"), canvas_state, graph)
    end_node_canvas(ctx)
    # Render the add-menu too (closed by default; this proves it composes
    # without crashing — `add_menu` early-outs when `menu_state.open` is
    # False, so no spawn happens).
    _ = add_menu(ctx, String("add_menu"), menu_state, registry, graph)
    ctx.end_frame()
    print("Canvas frame: ", ctx.commands.byte_count(), " bytes of draw commands")

    print("PASS: M2.5 capstone — node graph + serde round-trip complete")
