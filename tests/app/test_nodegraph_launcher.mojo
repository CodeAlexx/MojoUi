"""Tests for the reusable node graph launcher command."""

from mojoui.app.nodegraph_launcher import comfy_nodegraph_launch_command


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var cmd = comfy_nodegraph_launch_command()
    _expect(cmd.byte_length() > 0, String("launcher command is non-empty"))
    _expect(cmd.byte_length() > 180, String("launcher command has build/run body"))
    print("PASS: nodegraph launcher")
