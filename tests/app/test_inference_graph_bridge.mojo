"""Tests for the graph-backed inference bridge."""

from mojoui.app.inference_graph_bridge import (
    dry_run_klein9b_graph, _resolve_model_spec,
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
    var ltx2 = _resolve_model_spec(String("LTX2"))
    _expect(ltx2.supported, String("LTX2 request backend must be registered"))
    _expect(ltx2.arg_style == 2, String("LTX2 must use the canonical request contract"))
    _expect(
        ltx2.src == String("serenitymojo/sampling/ltx2_request_cli.mojo"),
        String("LTX2 must resolve to the pure-Mojo request CLI"),
    )
    print("PASS: inference graph bridge")
