"""Smoke tests for `mojoui/widgets/tree.mojo`.

Run: `pixi run test-tree`

Pure `mojo run`. Visible-row count is observed via CMD_TEXT (one label per
visible row, with a font set). Row k sits at y = k * row_height; we set
row_height = 24 and click at row-center y values.

Sample tree (pre-order, depth in parens):
  1 src(0, parent)
  2   main(1)
  3   widgets(1, parent)
  4     button(2)
  5 README(0)

Covers:
  1. Empty → TREE_ID_NONE, no draws.
  2. All collapsed → only the 2 depth-0 rows visible.
  3. Expand src → 4 rows (button still hidden under collapsed widgets).
  4. Expand src + widgets → all 5 rows.
  5. Click a parent row toggles expansion + selects + returns its id.
  6. Click a leaf selects it (no toggle).
"""

from mojoui.core.types import Vec2
from mojoui.core.context import Context
from mojoui.core.commands import CMD_TEXT
from mojoui.widgets.tree import TreeItem, TreeState, tree_view, TREE_ID_NONE


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _count_kind(ctx: Context, target_kind: Int32) -> Int32:
    var n: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == target_kind:
            n = n + 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off = off + step
    return n


def _sample() -> List[TreeItem]:
    var t = List[TreeItem]()
    t.append(TreeItem(Int64(1), String("src"), Int32(0), True))
    t.append(TreeItem(Int64(2), String("main"), Int32(1), False))
    t.append(TreeItem(Int64(3), String("widgets"), Int32(1), True))
    t.append(TreeItem(Int64(4), String("button"), Int32(2), False))
    t.append(TreeItem(Int64(5), String("README"), Int32(0), False))
    return t^


def _begin(mut ctx: Context, mouse: Vec2, pressed: Bool, released: Bool) raises:
    ctx.set_default_font(UInt32(1))
    ctx.theme.row_height = Int32(24)
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(Int32(300))
    ctx.layout_row(widths^, Int32(24))


def test_empty_tree_noop() raises:
    var ctx = Context()
    var state = TreeState()
    var empty = List[TreeItem]()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var before = ctx.commands.byte_count()
    var clicked = tree_view(ctx, String("t"), empty, state)
    if clicked != TREE_ID_NONE:
        _fail("empty tree should return TREE_ID_NONE")
    if ctx.commands.byte_count() != before:
        _fail("empty tree should emit nothing")
    ctx.end_frame()
    print("PASS: test_empty_tree_noop")


def test_all_collapsed_shows_roots() raises:
    var ctx = Context()
    var state = TreeState()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    var rows = _count_kind(ctx, Int32(CMD_TEXT))
    if rows != Int32(2):
        _fail("all-collapsed should show 2 depth-0 rows, got " + String(Int(rows)))
    ctx.end_frame()
    print("PASS: test_all_collapsed_shows_roots")


def test_expand_src_hides_grandchild() raises:
    var ctx = Context()
    var state = TreeState()
    state.set_expanded(Int64(1), True)  # src open, widgets still closed
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    var rows = _count_kind(ctx, Int32(CMD_TEXT))
    if rows != Int32(4):
        _fail("src-open should show 4 rows (button hidden), got " + String(Int(rows)))
    ctx.end_frame()
    print("PASS: test_expand_src_hides_grandchild")


def test_expand_all_shows_everything() raises:
    var ctx = Context()
    var state = TreeState()
    state.set_expanded(Int64(1), True)
    state.set_expanded(Int64(3), True)
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    var rows = _count_kind(ctx, Int32(CMD_TEXT))
    if rows != Int32(5):
        _fail("all-open should show 5 rows, got " + String(Int(rows)))
    ctx.end_frame()
    print("PASS: test_expand_all_shows_everything")


def test_click_chevron_toggles_only() raises:
    """Click the chevron of row 0 (src). The chevron region is at
    x in [pad, pad+_TRI_SIZE] = [6, 16] for a depth-0 row; click x=10. It
    TOGGLES expand (collapsed→open) WITHOUT selecting (hit-region split)."""
    var ctx = Context()
    var state = TreeState()
    # Frame 1: press on the chevron (y 0..24 → click y=12, x=10).
    _begin(ctx, Vec2(10.0, 12.0), True, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    # Frame 2: release on the chevron.
    _begin(ctx, Vec2(10.0, 12.0), False, True)
    var clicked = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    if clicked != Int64(1):
        _fail("clicking src chevron should return id 1, got " + String(clicked))
    if not state.is_expanded(Int64(1)):
        _fail("clicking the chevron should expand a collapsed parent")
    if state.selected == Int64(1):
        _fail("chevron click must NOT change selection")
    print("PASS: test_click_chevron_toggles_only")


def test_click_label_selects_only() raises:
    """Click the LABEL of row 0 (src) at x=150 (well past the chevron). It
    SELECTS id 1 WITHOUT toggling expansion (hit-region split)."""
    var ctx = Context()
    var state = TreeState()
    _begin(ctx, Vec2(150.0, 12.0), True, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    _begin(ctx, Vec2(150.0, 12.0), False, True)
    var clicked = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    if clicked != Int64(1):
        _fail("clicking src label should return id 1, got " + String(clicked))
    if state.selected != Int64(1):
        _fail("clicking the label should select it")
    if state.is_expanded(Int64(1)):
        _fail("label click must NOT toggle expansion")
    print("PASS: test_click_label_selects_only")


def test_click_leaf_selects_only() raises:
    """With src expanded, rows are: src(0), main(1), widgets(2), README(3).
    Click row 1 (main, a leaf) at y=36 → selects id 2, no toggle."""
    var ctx = Context()
    var state = TreeState()
    state.set_expanded(Int64(1), True)
    _begin(ctx, Vec2(150.0, 36.0), True, False)
    _ = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    _begin(ctx, Vec2(150.0, 36.0), False, True)
    var clicked = tree_view(ctx, String("t"), _sample(), state)
    ctx.end_frame()
    if clicked != Int64(2):
        _fail("clicking main should return id 2, got " + String(clicked))
    if state.selected != Int64(2):
        _fail("leaf click should select id 2")
    if Int64(2) in state.expanded:
        _fail("leaf (no children) must not get an expand entry")
    print("PASS: test_click_leaf_selects_only")


def main() raises:
    test_empty_tree_noop()
    test_all_collapsed_shows_roots()
    test_expand_src_hides_grandchild()
    test_expand_all_shows_everything()
    test_click_chevron_toggles_only()
    test_click_label_selects_only()
    test_click_leaf_selects_only()
    print("PASS: all 7 tree tests")
