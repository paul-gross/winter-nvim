# Dashboard layout dependency decision

## Decision: use `Snacks.win` (snacks.nvim)

The winter.nvim dashboard window is rendered through `Snacks.win` from the
[snacks.nvim](https://github.com/folke/snacks.nvim) library.

## Options considered

### 1. snacks.nvim (`Snacks.win`) — CHOSEN

**Footprint:** snacks.nvim is already a **hard dependency** of winter.nvim (the
worktrees picker uses `Snacks.picker`). Choosing `Snacks.win` adds zero new
package dependencies.

**Feature fit:** `Snacks.win` supports every layout the dashboard needs out of
the box:
- Docked splits (`position = "bottom" | "top" | "left" | "right"`) using split
  commands, with `winfixheight`/`winfixwidth` applied automatically.
- Floating/popup windows (`position = "float"`) with backdrop dimming, border
  styles, and fractional or absolute sizing.
- An explicit `buf` field that lets callers supply their own pre-existing buffer
  — critical for the dashboard, which must reuse its persistent `nofile` buffer
  across toggle cycles so the module-level `_bufnr` and timer state keep
  targeting the same buffer.
- Built-in `minimal` mode (strips line numbers, sign column, wrap, etc.) that
  is exactly right for a status display.

**Maintenance:** one dependency instead of two; upstream handles cross-Neovim
API compatibility.

### 2. nui.nvim

nui.nvim is a capable popup/split library with a clean API. However:
- It is **not already installed** — adding it would be a new user-facing
  dependency. Requiring a second plugin manager entry solely for dashboard
  layout is not justified when snacks already provides equivalent capability.

### 3. Hand-rolled `nvim_open_win` / `split` commands

Feasible, but this means reimplementing border rendering, fractional sizing
helpers, backdrop dimming, resize listeners, and winfixheight/winfixwidth
bookkeeping — all things snacks already provides and maintains. Maintenance cost
is high for zero benefit given that snacks is already required.

## Default layout position: `"bottom"`

The dashboard renders a grid of environments × repos with status indicators.
That content is inherently **horizontal** — each row is one repo, each
column is one env. A bottom-docked split (`:WinterDashboard`) mirrors the
shape of terminal panels and file-tree splits that Neovim users are already
familiar with and keeps the main editing area unobscured.

A default height of `15` lines is enough to show 8–10 environments plus headers
without taking over the screen. Users who prefer a floating popup can set
`dashboard.position = "float"`.

## Config schema

```lua
require("winter").setup({
  dashboard = {
    position = "bottom",   -- "bottom"|"top"|"left"|"right"|"float"
    size     = 15,         -- lines for bottom/top, cols for left/right,
                           -- or { width = 0.8, height = 0.6 } for float
    border   = "rounded",  -- any snacks border string; only used for "float"
    title    = " Winter ", -- window title string; nil disables
  },
})
```

`size` semantics:
- For dock positions (`bottom`/`top`): integer → height in lines; fraction
  0 < n < 1 → fraction of the editor height.
- For dock positions (`left`/`right`): integer → width in columns; fraction
  0 < n < 1 → fraction of the editor width.
- For `float`: table `{ width = <number>, height = <number> }` where each value
  follows the same integer/fraction rule. A plain number is treated as
  `{ width = n, height = n }`.

Full `Snacks.win` option pass-through is deliberately NOT exposed. The
`dashboard` config table maps to a small, opinionated subset; direct
`Snacks.win` customisation is not a goal for this phase.
