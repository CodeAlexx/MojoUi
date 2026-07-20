"""Tests for the graph-backed inference bridge."""

from mojoui.app.inference_graph_bridge import dry_run_klein9b_graph
from mojoui.app.inference_model import InferenceState


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var state = InferenceState()
    var ok = dry_run_klein9b_graph(state)
    _expect(ok, String("Klein 9B graph dry-run should compile and execute"))
    _expect(state.model_label() == String("Klein 9B"), String("Klein 9B is the default model"))
    print("PASS: inference graph bridge")
