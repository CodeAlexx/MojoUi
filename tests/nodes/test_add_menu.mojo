"""Smoke tests for `mojoui/nodes/add_menu.mojo` — AddMenuState + filter
helpers + closed-menu no-op.

Behavior tests focus on the pure-Mojo helpers (`_lower`,
`_contains_substr`, `_filter_registry`) and the state-machine surface
(`AddMenuState` open/close + show_at). The widget call (`add_menu`) is
exercised in the "closed" path only, which never touches FFI — the
open-menu path reaches `ctx.input.key_pressed` whose underlying array
is initialized to zeros under `Context.begin_frame_no_input`, but to
stay on the conservative side we wrap any `add_menu(...)` call that
could go through the open branch in the c15/c16 runtime-False JIT
guard. The closed-path test does NOT use the guard because the early
return guarantees no FFI-reachable code runs.

The `_filter_registry` test exercises every match path (empty search,
exact-substring case-insensitive, no-match). The `_filter_registry`
function itself does NOT call FFI — it walks the registry's purely
in-memory `Dict[String, NodeTypeDef]` + `List[String]` storage.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.id import RetainedIdAllocator
from mojoui.render.ffi import MOJOUI_KEY_COUNT
from mojoui.nodes.graph import Graph
from mojoui.nodes.registry import (
    NodeRegistry,
    NodeTypeDef,
    register_builtins,
)
from mojoui.nodes.add_menu import (
    AddMenuState,
    add_menu,
    _filter_registry,
    _lower,
    _contains_substr,
)


# ============================================================================
# AddMenuState
# ============================================================================


def test_default_state_closed() raises:
    """A freshly-constructed AddMenuState is closed (open == False)."""
    var st = AddMenuState()
    if st.open:
        raise Error("fresh AddMenuState should not be open")
    if st.search_text.byte_length() != 0:
        raise Error("fresh search_text should be empty")
    if st.selected_idx != 0:
        raise Error("fresh selected_idx should be 0")
    print("  PASS test_default_state_closed")


def test_show_at_opens_and_records_positions() raises:
    """`show_at` flips open=True and records both screen anchor and
    world spawn position."""
    var st = AddMenuState()
    st.show_at(Vec2(100.0, 200.0), Vec2(50.0, 75.0))
    if not st.open:
        raise Error("show_at should flip open=True")
    if st.anchor.x != 100.0 or st.anchor.y != 200.0:
        raise Error("anchor should record screen_pos verbatim")
    if st.world_spawn_pos.x != 50.0 or st.world_spawn_pos.y != 75.0:
        raise Error("world_spawn_pos should record world_pos verbatim")
    if st.search_text.byte_length() != 0:
        raise Error("show_at should reset search_text to empty")
    if st.selected_idx != 0:
        raise Error("show_at should reset selected_idx to 0")
    print("  PASS test_show_at_opens_and_records_positions")


def test_hide_closes() raises:
    """`hide()` flips open back to False (other fields preserved)."""
    var st = AddMenuState()
    st.show_at(Vec2(10.0, 20.0), Vec2(30.0, 40.0))
    if not st.open:
        raise Error("setup: show_at should open")
    st.hide()
    if st.open:
        raise Error("hide should flip open=False")
    # Other fields preserved per the API contract.
    if st.anchor.x != 10.0 or st.anchor.y != 20.0:
        raise Error("hide should preserve anchor")
    if st.world_spawn_pos.x != 30.0 or st.world_spawn_pos.y != 40.0:
        raise Error("hide should preserve world_spawn_pos")
    print("  PASS test_hide_closes")


# ============================================================================
# Helpers: _lower + _contains_substr
# ============================================================================


def test_lower_hello() raises:
    """_lower('HELLO') == 'hello' (ASCII A..Z range)."""
    var got = _lower(String("HELLO"))
    if got != String("hello"):
        raise Error("_lower('HELLO') should be 'hello'")
    # Idempotence on already-lowercase input.
    var got2 = _lower(String("hello"))
    if got2 != String("hello"):
        raise Error("_lower('hello') should be 'hello'")
    # Mixed-case preserves non-letter bytes.
    var got3 = _lower(String("K-Sampler"))
    if got3 != String("k-sampler"):
        raise Error("_lower('K-Sampler') should be 'k-sampler'")
    print("  PASS test_lower_hello")


def test_contains_substr_matches_and_misses() raises:
    """_contains_substr returns True on match, False on miss."""
    if not _contains_substr(String("foobar"), String("oba")):
        raise Error("'foobar' should contain 'oba'")
    if _contains_substr(String("foobar"), String("xyz")):
        raise Error("'foobar' should NOT contain 'xyz'")
    # Empty needle always matches.
    if not _contains_substr(String("foobar"), String("")):
        raise Error("empty needle should match anywhere")
    # Empty haystack only matched by empty needle.
    if _contains_substr(String(""), String("x")):
        raise Error("empty haystack should not contain 'x'")
    # Needle longer than haystack misses.
    if _contains_substr(String("abc"), String("abcdef")):
        raise Error("needle longer than haystack should miss")
    # Match at end of haystack.
    if not _contains_substr(String("foobar"), String("bar")):
        raise Error("'foobar' should contain 'bar' at end")
    print("  PASS test_contains_substr_matches_and_misses")


# ============================================================================
# _filter_registry
# ============================================================================


def test_filter_empty_returns_all_builtins() raises:
    """Empty search returns every registered type_id (5 builtins, in
    insertion order)."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var matches = _filter_registry(reg, String(""))
    if len(matches) != 5:
        raise Error(
            "empty filter on 5 builtins should return 5 entries; got "
            + String(len(matches))
        )
    # First is the first registered (insertion order; register_builtins
    # registers load_checkpoint first).
    if matches[0] != String("core/load_checkpoint"):
        raise Error("matches[0] should be 'core/load_checkpoint'")
    print("  PASS test_filter_empty_returns_all_builtins")


def test_filter_k_sampler_case_insensitive() raises:
    """Filter 'K-Sampler' (matches display_name 'K-Sampler') returns
    exactly one entry (core/k_sampler). Verifies case-insensitive
    substring match on display_name (NOT type_id)."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var matches = _filter_registry(reg, String("K-Sampler"))
    if len(matches) != 1:
        raise Error(
            "filter 'K-Sampler' should return 1 entry; got "
            + String(len(matches))
        )
    if matches[0] != String("core/k_sampler"):
        raise Error(
            "filter 'K-Sampler' should match type_id 'core/k_sampler'"
        )
    # Lower-case variant returns same result.
    var matches2 = _filter_registry(reg, String("k-sampler"))
    if len(matches2) != 1:
        raise Error("lower-case 'k-sampler' should also match 1")
    if matches2[0] != String("core/k_sampler"):
        raise Error("lower-case should match same type_id")
    # Partial substring also matches.
    var matches3 = _filter_registry(reg, String("Sampler"))
    if len(matches3) != 1:
        raise Error("partial 'Sampler' should match 1")
    print("  PASS test_filter_k_sampler_case_insensitive")


def test_filter_no_match_returns_empty() raises:
    """A search that doesn't match any display_name returns an empty
    list."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var matches = _filter_registry(reg, String("xyz-no-such-thing"))
    if len(matches) != 0:
        raise Error(
            "no-match filter should return 0 entries; got "
            + String(len(matches))
        )
    print("  PASS test_filter_no_match_returns_empty")


# ============================================================================
# add_menu — closed state is no-op (compile + return False)
# ============================================================================


def test_add_menu_closed_returns_false_no_commands() raises:
    """When menu_state.open == False, add_menu returns False without
    emitting any commands. The closed path is pure-Mojo (no FFI in the
    call graph) so this test runs directly under JIT.
    """
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False)
    var pre_bytes = ctx.commands.byte_count()
    var menu_state = AddMenuState()  # closed
    var reg = NodeRegistry()
    register_builtins(reg)
    var graph = Graph()
    var spawned = add_menu(
        ctx, String("test_menu"), menu_state, reg, graph
    )
    if spawned:
        raise Error("closed add_menu should return False")
    var post_bytes = ctx.commands.byte_count()
    if post_bytes != pre_bytes:
        raise Error(
            "closed add_menu should not emit any commands; pre_bytes="
            + String(pre_bytes)
            + " post_bytes="
            + String(post_bytes)
        )
    if graph.node_count() != 0:
        raise Error("closed add_menu should not spawn a node")
    print("  PASS test_add_menu_closed_returns_false_no_commands")


# ============================================================================
# add_menu — open compile/import check (JIT-guarded)
# ============================================================================


def test_add_menu_open_compile_only() raises:
    """Compile-only check that the open path type-checks against
    Context/NodeRegistry/Graph. The body runs behind a never-True
    runtime guard (c15/c16/c24 pattern) so the JIT does NOT need to
    resolve FFI symbols reachable through the static call graph
    (`ctx.input.key_pressed` is pure-Mojo today but
    `Context.begin_frame` reaches FFI; we use the no_input fixture +
    the guard for belt-and-braces).
    """
    var never = Int(MOJOUI_KEY_COUNT) - 96  # always 0, optimizer can't fold
    if never != 0:
        var ctx = Context()
        ctx.begin_frame_no_input(
            Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False
        )
        var menu_state = AddMenuState()
        menu_state.show_at(Vec2(100.0, 200.0), Vec2(50.0, 75.0))
        var reg = NodeRegistry()
        register_builtins(reg)
        var graph = Graph()
        # Type-check the open-menu call signature against current ABI.
        var _spawned = add_menu(
            ctx, String("test_menu"), menu_state, reg, graph
        )
    print("  PASS test_add_menu_open_compile_only")


# ============================================================================
# main
# ============================================================================


def main() raises:
    print("Running add_menu tests...")
    test_default_state_closed()
    test_show_at_opens_and_records_positions()
    test_hide_closes()
    test_lower_hello()
    test_contains_substr_matches_and_misses()
    test_filter_empty_returns_all_builtins()
    test_filter_k_sampler_case_insensitive()
    test_filter_no_match_returns_empty()
    test_add_menu_closed_returns_false_no_commands()
    test_add_menu_open_compile_only()
    print("PASS: all 10 smoke tests")
