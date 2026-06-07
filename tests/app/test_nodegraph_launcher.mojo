"""Tests for the reusable node graph launcher command."""

from mojoui.app.nodegraph_launcher import comfy_nodegraph_launch_command
from mojoui.serde.version import _find_substr


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var cmd = comfy_nodegraph_launch_command()
    _expect(cmd.byte_length() > 0, String("launcher command is non-empty"))
    _expect(cmd.byte_length() > 180, String("launcher command has build/run body"))
    _expect(
        _find_substr(
            cmd,
            String("pgrep -f '^/tmp/mojoui_m6_nodegraph($|[[:space:]])'"),
            0,
            cmd.byte_length(),
        ) >= 0,
        String("launcher process guard must not match its own shell command"),
    )
    _expect(
        _find_substr(cmd, String("nohup setsid env LD_LIBRARY_PATH="), 0, cmd.byte_length()) >= 0,
        String("launcher must detach the graph process directly"),
    )
    print("PASS: nodegraph launcher")
