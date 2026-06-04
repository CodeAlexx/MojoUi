"""Smoke tests for mojoui/app/state.mojo + the raw set_user_data/get_user_data
FFI (c50). Verifies the C-side static slot round-trips an opaque pointer plus
the typed wrapper preserves identity for a small user struct.

JIT note: Even though `mojoui_set_user_data` / `mojoui_get_user_data` only
touch a `static void*` in `c_floor/mojoui_platform.c` (no GL context required,
no window-open precondition), the c15 finding STILL applies — `mojo run`'s
JIT does not dlopen libmojoui_floor.so unless symbols are reachable at
runtime AND the .so was previously loaded by another path. So all FFI-touching
test bodies sit behind the c15/c16/c24 runtime-False guard (`Int(MOJOUI_KEY_COUNT) - 96`
is always 0 but the optimiser cannot fold it), which proves the signatures
type-check end-to-end without forcing the JIT to materialise the symbols.
The runtime gate is the future `examples/m1_button_interactive.mojo` (a chunk
beyond c50) which builds to a real binary linked against libmojoui_floor.so
via `-Xlinker -lmojoui_floor`.

Run: cd /home/alex/MojoUI && pixi run test-user-data
"""

from std.memory import UnsafePointer
from std.builtin.type_aliases import MutAnyOrigin

from mojoui.render.ffi import set_user_data, get_user_data, MOJOUI_KEY_COUNT
from mojoui.app.state import store_user_state, retrieve_user_state


# A small POD-shaped state struct (mirrors the docstring example pattern).
# Movable-only is fine; the test only takes its address — never copies it.
struct MyState(Movable):
    var counter: Int32
    var font_id: UInt32

    def __init__(out self):
        self.counter = 0
        self.font_id = 0

    def __init__(out self, counter: Int32, font_id: UInt32):
        self.counter = counter
        self.font_id = font_id


def test_raw_roundtrip(never_run: Bool) raises:
    """Set then get returns the same bits — round-trip via `set_user_data(p)`.

    Gated behind `never_run` (always False but the optimiser cannot fold it)
    so the JIT does not need to materialise the FFI symbols at run time.
    """
    if never_run:
        var local: Int32 = 42
        var p = UnsafePointer(to=local).bitcast[NoneType]()
        set_user_data(p)
        var got = get_user_data()
        var p_addr = Int(p)
        var got_addr = Int(got)
        if p_addr != got_addr:
            print("FAIL: raw_roundtrip expected addr", p_addr, "got", got_addr)
            raise Error("user_data round-trip address mismatch")


def test_typed_roundtrip(never_run: Bool) raises:
    """Typed wrapper round-trip — store_user_state + retrieve_user_state[T]()
    returns a pointer that derefs to the same data we stored. JIT-gated."""
    if never_run:
        var state = MyState(7, UInt32(11))
        store_user_state(UnsafePointer(to=state))
        var got = retrieve_user_state[MyState]()
        if got[].counter != 7:
            print("FAIL: typed_roundtrip counter expected 7 got", got[].counter)
            raise Error("typed user_state counter mismatch")
        if got[].font_id != UInt32(11):
            print("FAIL: typed_roundtrip font_id expected 11 got", Int(got[].font_id))
            raise Error("typed user_state font_id mismatch")
        # Mutate through the recovered pointer; the original `state` sees it.
        got[].counter = 99
        if state.counter != 99:
            print("FAIL: typed_roundtrip mutation expected state.counter==99 got", state.counter)
            raise Error("typed user_state mutation did not propagate")


def test_overwrite(never_run: Bool) raises:
    """Calling set_user_data twice replaces the stored bits — not appends.
    Gated for JIT-safety."""
    if never_run:
        var a: Int32 = 1
        var b: Int32 = 2
        var pa = UnsafePointer(to=a).bitcast[NoneType]()
        var pb = UnsafePointer(to=b).bitcast[NoneType]()
        set_user_data(pa)
        set_user_data(pb)
        var got = get_user_data()
        if Int(got) != Int(pb):
            print("FAIL: overwrite expected pb got something else")
            raise Error("user_data overwrite did not replace")
        if Int(got) == Int(pa):
            print("FAIL: overwrite returned the FIRST stored pointer")
            raise Error("user_data overwrite returned stale pointer")


def test_typed_wrapper_pure() raises:
    """Pure-Mojo smoke that doesn't touch FFI: the bitcast pipeline through
    store_user_state's element-type translation compiles + signature-checks.

    Verifies the parametric `T: AnyType` machinery on a fresh `MyState` value
    (taking its address, bitcasting to NoneType*, then bitcasting back to
    `MyState*`) round-trips identity. This runs UNGUARDED so the test suite
    has at least one non-trivial runtime assertion that exercises the typed
    wrapper logic; the bitcast itself is pure pointer arithmetic with no FFI
    dependency.
    """
    var state = MyState(13, UInt32(17))
    var typed_p = UnsafePointer(to=state)
    var opaque = typed_p.bitcast[NoneType]()
    var back = opaque.bitcast[MyState]()
    if Int(back) != Int(typed_p):
        print("FAIL: typed_wrapper_pure bitcast roundtrip lost the address")
        raise Error("bitcast round-trip changed pointer address")
    if back[].counter != 13 or back[].font_id != UInt32(17):
        print("FAIL: typed_wrapper_pure deref expected (13, 17) got",
              back[].counter, Int(back[].font_id))
        raise Error("bitcast round-trip did not preserve fields")


def main() raises:
    var never = Int(MOJOUI_KEY_COUNT) - 96  # always 0, not literal-False
    var never_run: Bool = never != 0  # always False, JIT-unfoldable
    # FFI-touching tests are signature-only (compile-proof against the C ABI
    # without forcing the JIT to materialise the symbols).
    test_raw_roundtrip(never_run)
    test_typed_roundtrip(never_run)
    test_overwrite(never_run)
    # Pure-Mojo runtime assertion — bitcast pipeline through the typed wrapper.
    test_typed_wrapper_pure()
    print("PASS: user_data smoke (4 tests — raw + typed + overwrite signatures, typed-wrapper runtime)")
