"""mojoui.theme — semantic design-token system (M3).

The token vocabulary mirrors rerun's `design_tokens.rs` (semantic names like
`text_subdued`, `panel_bg_color`, `alert_warning_fill`) so widgets reference
tokens by purpose rather than by literal RGB. Themes (c44 themes.mojo) supply
the actual palette; theme switching (c47) swaps Context's active theme.
"""
