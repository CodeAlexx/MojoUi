"""Tests for the graph-backed inference bridge."""

from mojoui.app.inference_graph_bridge import (
    GraphUiRuntime,
    _count_occurrences,
    _resolve_model_spec,
    dry_run_klein9b_graph,
    graph_backend_label,
)
from mojoui.app.inference_model import InferenceState


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var state = InferenceState()
    var ok = dry_run_klein9b_graph(state)
    _expect(ok, String("Klein 9B graph dry-run should compile and execute"))
    _expect(state.model_label() == String("Klein 9B"), String("Klein 9B is the default model"))

    var ltx2 = _resolve_model_spec(String("LTX2 Fast"))
    _expect(ltx2.supported, String("LTX2 Fast backend should be registered"))
    _expect(ltx2.slug == String("ltx2"), String("LTX2 Fast slug mismatch"))
    _expect(ltx2.arg_style == 2, String("LTX2 Fast must use the video CLI contract"))
    _expect(
        ltx2.bin.find(String("/ltx2_video_smoke_runner")) >= 0,
        String("LTX2 Fast must launch the pure-Mojo video runner"),
    )
    _expect(
        _count_occurrences(
            String("--- step 1 / 8\n--- step 2 / 8\n--- step 3 / 8"),
            String("--- step"),
        ) == 3,
        String("LTX2 progress markers should count completed step starts"),
    )
    var rt = GraphUiRuntime()
    rt.cli_slug = String("ltx2")
    rt.last_status = String("LTX2 step 3 of 8")
    var status = graph_backend_label(rt)
    _expect(status.find(String("Mojo CLI")) >= 0, String("LTX2 status should say Mojo CLI"))
    _expect(status.find(String("LTX2 Fast")) >= 0, String("LTX2 status should name its backend"))
    _expect(status.find(String("step 3 of 8")) >= 0, String("LTX2 status should expose progress"))
    print("PASS: inference graph bridge")
