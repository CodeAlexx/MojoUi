"""Tree view widget — collapsible hierarchy with selection.

Renders a flat, pre-order list of `TreeItem`s (each carrying its `depth`)
as an indented tree. Nodes with children show a ▶/▼ toggle; collapsing a
node hides its whole subtree. Exactly one row can be selected. The caller
owns a `TreeState` (expanded set + selected id) across frames — microui
convention, no widget-retained state.

Data model: the caller flattens its tree into pre-order with explicit
`depth` (0 = root). This keeps the widget free of any recursive tree type
and lets the caller back it by whatever structure it likes:

    var items = List[TreeItem]()
    items.append(TreeItem(1, String("src"), 0, True))
    items.append(TreeItem(2, String("main.mojo"), 1, False))
    items.append(TreeItem(3, String("widgets"), 1, True))
    items.append(TreeItem(4, String("button.mojo"), 2, False))
    var state = TreeState()
    state.set_expanded(1, True)   # open "src" initially
    var clicked = tree_view(ctx, String("file_tree"), items, state)

Layout: like `popup`/`add_menu`, takes ONE `layout_next()` slot for its
top-left + width and lays visible rows downward at `theme.row_height`
each (the total height is not fed back to the layout cursor — the caller
reserves vertical space). A collapsed node's descendants (any following
items with greater depth) are skipped.

Interaction: clicking a row selects it; if it has children, the click also
toggles expand/collapse. Returns the clicked item id this frame, or -1.

`.copy()` discipline per MOJO_NOTES.md.
`raises`: `TreeState.is_expanded` reads a Dict (getitem raises in beta).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_RELEASED, OPT_NONE


comptime _INDENT_PX: Float32 = 16.0
"""Horizontal indent per depth level (px)."""

comptime _TRI_SIZE: Float32 = 10.0
"""Bounding-box edge of the ▶/▼ toggle (px) — matches collapsing_header."""

comptime _TRI_BAR_THICKNESS: Float32 = 2.0

comptime TREE_ID_NONE: Int64 = -1
"""Sentinel for 'no selection' / 'nothing clicked'."""


struct TreeItem(Copyable, Movable):
    """One pre-order tree row. `id` is a stable caller-assigned key (used
    for expand/selection state); `depth` is the indentation level (0 =
    root); `has_children` controls whether a toggle is drawn and whether
    the subtree can be collapsed."""

    var id: Int64
    var label: String
    var depth: Int32
    var has_children: Bool

    def __init__(
        out self, id: Int64, label: String, depth: Int32, has_children: Bool
    ):
        self.id = id
        self.label = label.copy()
        self.depth = depth
        self.has_children = has_children


struct TreeState(Movable):
    """Caller-owned tree state: which node ids are expanded + the selected
    id. Absent from `expanded` == collapsed. Movable-only."""

    var expanded: Dict[Int64, Bool]
    var selected: Int64

    def __init__(out self):
        self.expanded = Dict[Int64, Bool]()
        self.selected = TREE_ID_NONE

    def is_expanded(self, id: Int64) raises -> Bool:
        """True iff `id` is currently expanded (absent → collapsed)."""
        if id in self.expanded:
            return self.expanded[id]
        return False

    def set_expanded(mut self, id: Int64, value: Bool):
        """Directly set a node's expanded flag."""
        self.expanded[id] = value

    def toggle(mut self, id: Int64) raises:
        """Flip a node's expanded flag."""
        self.expanded[id] = not self.is_expanded(id)

    def set_selected(mut self, id: Int64):
        self.selected = id


def _draw_toggle(mut ctx: Context, x: Float32, y_center: Float32, open: Bool):
    """Draw the ▶ (closed) / ▼ (open) toggle glyph as stacked thin rects —
    same stub as collapsing_header (M3 tessellator replaces)."""
    var tri_y = y_center - _TRI_SIZE * 0.5
    var col = ctx.theme.text.copy()
    if open:
        ctx.draw_rect(
            Rect(
                x,
                tri_y + (_TRI_SIZE - _TRI_BAR_THICKNESS) * 0.5,
                _TRI_SIZE,
                _TRI_BAR_THICKNESS,
            ),
            col^,
        )
    else:
        var seg_h = _TRI_SIZE / 3.0
        ctx.draw_rect(Rect(x, tri_y, _TRI_SIZE / 3.0, seg_h), col.copy())
        ctx.draw_rect(
            Rect(x, tri_y + seg_h, _TRI_SIZE * 2.0 / 3.0, seg_h), col.copy()
        )
        ctx.draw_rect(Rect(x, tri_y + 2.0 * seg_h, _TRI_SIZE / 3.0, seg_h), col^)


def tree_view(
    mut ctx: Context,
    id_str: String,
    items: List[TreeItem],
    mut state: TreeState,
) raises -> Int64:
    """Render the visible rows of a tree and return the clicked item id this
    frame (or `TREE_ID_NONE`).

    Args:
        ctx:     Per-frame Context.
        id_str:  Id seed; per-row ids derive under it.
        items:   Pre-order flattened tree (each with depth + has_children).
        state:   Caller-owned expand/selection state. Clicking a row selects
                 it; clicking a parent row also toggles its expansion.

    Returns: clicked item id, or `TREE_ID_NONE` if no row was clicked.
    """
    var n = len(items)
    if n == 0:
        return TREE_ID_NONE

    ctx.push_id_str(id_str)
    var origin = ctx.layout_next()
    var row_h = Float32(ctx.theme.row_height)
    var clicked = TREE_ID_NONE

    var i = 0
    var row_index = 0
    while i < n:
        var it = items[i].copy()
        var row_rect = Rect(
            origin.x,
            origin.y + Float32(row_index) * row_h,
            origin.w,
            row_h,
        )
        var indent = Float32(it.depth) * _INDENT_PX
        var pad = Float32(ctx.theme.padding)
        var y_center = row_rect.y + row_h * 0.5

        # Split hit regions: the chevron toggles expand/collapse ONLY; the
        # rest of the row (the label) selects ONLY. Register the ROW control
        # first, then the chevron control — `update_control` sets the active
        # slot to the LAST control whose rect contained the press, so a press
        # over the (smaller, inner) chevron is won by the chevron while a
        # press over the label is won by the row. Parents without children
        # have no chevron and the whole row selects.
        var row_id = ctx.get_id(String(it.id))
        var flags = ctx.update_control(row_id, row_rect.copy(), OPT_NONE)

        var chevron_rect = Rect(
            row_rect.x + pad + indent, row_rect.y, _TRI_SIZE, row_h
        )
        var chevron_flags = Int32(0)
        if it.has_children:
            var chevron_id = ctx.get_id(String(it.id) + String("#chev"))
            chevron_flags = ctx.update_control(
                chevron_id, chevron_rect.copy(), OPT_NONE
            )

        if it.has_children and (chevron_flags & CTRL_RELEASED) != 0:
            # Chevron click — toggle only, no selection change.
            state.toggle(it.id)
            clicked = it.id
        elif (flags & CTRL_RELEASED) != 0:
            # Label/row click — select only, no toggle.
            state.set_selected(it.id)
            clicked = it.id

        # Row background: selected > hovered > transparent.
        if state.selected == it.id:
            ctx.draw_rect(row_rect.copy(), ctx.theme.active_bg.copy())
        elif (flags & CTRL_HOVERED) != 0 or (chevron_flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.hover_bg.copy())

        var expanded_now = False
        if it.has_children:
            expanded_now = state.is_expanded(it.id)
            _draw_toggle(ctx, row_rect.x + pad + indent, y_center, expanded_now)

        # Label — after the indent + toggle slot.
        if ctx.theme.font_id != 0:
            var label_x = row_rect.x + pad + indent + _TRI_SIZE + pad
            var label_y = (
                row_rect.y + (row_h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                Vec2(label_x, label_y),
                ctx.theme.text.copy(),
                it.label,
            )

        row_index = row_index + 1

        # Advance: skip a collapsed node's subtree (following items whose
        # depth is greater than this node's depth).
        if it.has_children and not expanded_now:
            var j = i + 1
            while j < n and items[j].depth > it.depth:
                j = j + 1
            i = j
        else:
            i = i + 1

    ctx.pop_id()
    return clicked
