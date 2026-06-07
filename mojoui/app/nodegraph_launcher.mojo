"""Launch helpers for the reusable Comfy-style MojoUI node graph."""

from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.builtin.type_aliases import MutExternalOrigin


comptime BytePtr = UnsafePointer[UInt8, MutExternalOrigin]

comptime MOJOUI_ROOT = "/home/alex/MojoUI"
comptime PIXI_BIN = "/home/alex/.pixi/bin/pixi"
comptime NODEGRAPH_BIN = "/tmp/mojoui_m6_nodegraph"
comptime NODEGRAPH_LOG = "/tmp/mojoui_m6_nodegraph.log"


def _sys_system(command: String) -> Int:
    var n = command.byte_length()
    var buf = alloc[UInt8](n + 1)
    var src = command.as_bytes()
    for i in range(n):
        buf[i] = src[i]
    buf[n] = 0
    var cstr = BytePtr(unsafe_from_address=Int(buf))
    var status = Int(external_call["system", Int32](cstr))
    buf.free()
    return status


def comfy_nodegraph_launch_command() -> String:
    """Shell command that builds/reuses and opens the m6 Comfy graph window."""
    return (
        String("cd ")
        + String(MOJOUI_ROOT)
        + String(" && if ! pgrep -f '^/tmp/mojoui_m6_nodegraph($|[[:space:]])' >/dev/null; then if ! test -x ")
        + String(NODEGRAPH_BIN)
        + String("; then ")
        + String(PIXI_BIN)
        + String(" run mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm examples/m6_nodegraph.mojo -o ")
        + String(NODEGRAPH_BIN)
        + String("; fi; nohup setsid env LD_LIBRARY_PATH=")
        + String(MOJOUI_ROOT)
        + String(" ")
        + String(NODEGRAPH_BIN)
        + String(" > ")
        + String(NODEGRAPH_LOG)
        + String(" 2>&1 < /dev/null & fi")
    )


def launch_comfy_nodegraph() -> Int:
    """Open the Comfy-style workflow graph window.

    Returns libc `system(3)` status for the short launcher command. The build
    and node graph process run in the background so the calling UI does not
    block on first launch.
    """
    return _sys_system(comfy_nodegraph_launch_command())
