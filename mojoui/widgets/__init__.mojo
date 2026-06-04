"""mojoui.widgets — public widget functions.

Every widget is a free function taking `mut ctx: Context` and following the
microui 6-step recipe (get_id → layout_next → update_control → behavior →
draw → return). See `mojoui/widgets/basic.mojo` for the canonical pattern.
"""
