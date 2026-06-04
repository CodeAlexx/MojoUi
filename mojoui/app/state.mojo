"""Module-level frame-callback state via mojoui_set/get_user_data (c50).

This module is the canonical Mojo-side fix for the long-standing "no-arg
sokol_app frame callback cannot share mutable state with main()" wall
documented under Mojo implementation notes "Module-level state for frame callbacks". The
c50 C-floor extension (`mojoui_set_user_data` / `mojoui_get_user_data`) stashes
an opaque pointer in a static slot; this module wraps the FFI with a typed
`store_user_state[T]` / `retrieve_user_state[T]` pair so demo authors do not
have to spell `.bitcast[NoneType]()` / `.bitcast[T]()` by hand.

Usage in a demo:

    from std.memory import UnsafePointer
    from mojoui.app.state import store_user_state, retrieve_user_state
    from mojoui.render.backend import Backend

    struct MyAppState:
        var counter: Int32
        var font_id: UInt32

        def __init__(out self):
            self.counter = 0
            self.font_id = 0

    def _frame():
        # No args (sapp's frame callback is void (*)(void)). Recover the
        # typed pointer to the AppState that main() stashed before run_blocking.
        var state_ptr = retrieve_user_state[MyAppState]()
        # state_ptr[].counter += 1 ; etc.

    def main() raises:
        var state = MyAppState()
        # Pointer lifetime: `state` lives for the duration of main(), which
        # contains run_blocking; run_blocking returns when the window closes,
        # so the pointer is valid for the entire frame-loop lifetime.
        store_user_state(UnsafePointer(to=state))
        Backend.init(...)
        Backend.run_blocking(_frame)

Lifetime contract: the pointer passed to `store_user_state` MUST remain valid
for the entire time any frame callback might fire. The typical pattern is a
stack-allocated state struct in main() living strictly longer than
`Backend.run_blocking`. Heap allocation via `UnsafePointer[T].alloc(1)` works
too — call `free()` after run_blocking returns. NULL is a valid stored value
(initial state and "no state attached" sentinel).

The C side just stashes/returns the bits — it never dereferences. Type safety
is the caller's responsibility: `retrieve_user_state[T]()` returns whatever T
the caller asks for, regardless of what was stashed. Don't mix types across
store/retrieve calls in the same process.
"""

from std.memory import UnsafePointer
from std.builtin.type_aliases import MutAnyOrigin
from mojoui.render.ffi import set_user_data, get_user_data


def store_user_state[T: AnyType](state_ptr: UnsafePointer[T, MutAnyOrigin]):
    """Hand off a typed pointer to the C-side user_data slot.

    Bitcasts the typed pointer to the opaque `UnsafePointer[NoneType,
    MutAnyOrigin]` expected by `mojoui_set_user_data`. The pointer's lifetime
    is the CALLER's responsibility — see the module docstring for the
    canonical "stack-allocated AppState in main() lives strictly longer than
    Backend.run_blocking" pattern.

    T is inferred from the `state_ptr` element type — callers do not need to
    spell it explicitly.
    """
    set_user_data(state_ptr.bitcast[NoneType]())


def retrieve_user_state[T: AnyType]() -> UnsafePointer[T, MutAnyOrigin]:
    """Recover the previously-stored typed pointer from inside a frame callback.

    Bitcasts the opaque `UnsafePointer[NoneType, MutAnyOrigin]` returned by
    `mojoui_get_user_data` back to the caller-specified `UnsafePointer[T,
    MutAnyOrigin]`. The compiler cannot check that T matches the type that
    was originally `store_user_state`'d — mismatch is a use-after-cast bug
    that surfaces as a memory-safety violation at deref time.
    """
    return get_user_data().bitcast[T]()
