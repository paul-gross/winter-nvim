# winter.nvim

[![CI](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Neovim integration for [winter](https://github.com/paul-gross/winter) workspaces.

📚 **Documentation:** <https://paul-gross.github.io/winter-docs/>

This plugin provides rich editor integration with winter workspaces. Three integrated features are included:

- **Worktrees picker** — a [snacks.nvim](https://github.com/folke/snacks.nvim) fuzzy-finder over every `<env>/<repo>` feature-environment worktree and standalone repository; jump Neovim's working directory into it, restoring a saved session if one exists.
- **Workspace status dashboard** — a persistent toggle-able panel showing all feature-environment worktrees and their git state (ahead/behind/dirty/diverged), rendered as a grid of cells with hjkl/arrow navigation and quick-diffs openable in a new tab.
- **Cross-repo diff viewer** — aggregated multi-repo feature diff via [paul-gross/codediff.nvim](https://github.com/paul-gross/codediff.nvim), with branch/uncommitted/staged variants.

<!-- Screenshot placeholder: add a GIF or PNG of the picker in action -->
<!-- ![winter.nvim picker](https://github.com/paul-gross/winter-nvim/assets/screenshot.gif) -->

---

## Requirements

| Dependency | Minimum version |
|---|---|
| Neovim | 0.10+ (`vim.system` requires 0.10) |
| [folke/snacks.nvim](https://github.com/folke/snacks.nvim) | latest stable |
| [winter CLI](https://github.com/paul-gross/winter) | on `$PATH` |
| [paul-gross/codediff.nvim](https://github.com/paul-gross/codediff.nvim) | latest (optional — required for `:WinterDiff` and dashboard quick-diffs) |

Run `:checkhealth winter` after installation to confirm everything is wired up.

---

## Installation

### lazy.nvim (recommended)

```lua
{
  "paul-gross/winter-nvim",
  dependencies = {
    "folke/snacks.nvim",                    -- required (worktrees picker + dashboard window)
    "paul-gross/codediff.nvim",             -- optional (required for :WinterDiff and dashboard quick-diffs)
  },
  opts = {},
  -- optional keymaps (entry-point keymaps are the USER's responsibility — not auto-registered):
  -- keys = {
  --   { "<leader>fw", "<cmd>WinterWorktrees<cr>",  desc = "Winter: find workspace" },
  --   { "<leader>fd", "<cmd>WinterDashboard<cr>",  desc = "Winter: workspace dashboard" },
  -- },
}
```

### Manual keymap example

```lua
vim.keymap.set("n", "<leader>fw", "<cmd>WinterWorktrees<cr>",  { desc = "Winter: find workspace" })
vim.keymap.set("n", "<leader>fd", "<cmd>WinterDashboard<cr>",  { desc = "Winter: workspace dashboard" })
```

### packer.nvim

```lua
use {
  "paul-gross/winter-nvim",
  requires = {
    "folke/snacks.nvim",          -- required
    "paul-gross/codediff.nvim",   -- optional (diff features)
  },
  config = function()
    require("winter").setup()
  end,
}
```

---

## Configuration

All configuration is optional — unspecified fields inherit their defaults.

```lua
require("winter").setup({
  -- The winter CLI executable name, or a full path if not on PATH.
  winter_cmd = "winter",  -- string

  -- Global args inserted immediately after winter_cmd and before the subcommand
  -- on every winter invocation. NOTE: --winter=PATH must be the FIRST argument
  -- after the executable; the plugin guarantees this ordering automatically.
  -- Example: run a specific winter-cli source tree during development:
  winter_args = {},  -- string[]
  -- winter_args = { "--winter=/home/me/ws/alpha/winter" },

  -- Load existing Neovim sessions when switching directories.
  -- When true, switch_to() loads a session file if one already exists for the
  -- target path. Does not create new sessions unless create_sessions is also true.
  use_sessions = true,  -- boolean

  -- Save a Neovim session on switch so future visits restore your layout.
  -- When false (default), winter only LOADS sessions that already exist and
  -- otherwise just :cd's — it never creates session files on its own.
  -- Set to true to have winter write a session after each switch.
  create_sessions = false,  -- boolean

  -- Directory where per-path session files are stored.
  -- Created automatically on first use.
  session_dir = vim.fn.stdpath("state") .. "/winter-nvim/sessions",  -- string

  -- Vim cd command used when switching directories.
  -- "cd" (global), "tcd" (tab-local), or "lcd" (window-local).
  cd_command = "cd",  -- string

  -- Options for the snacks.nvim picker window.
  picker = {
    -- snacks.nvim layout name (e.g. "default", "ivy", "telescope").
    -- nil uses the snacks default layout.
    layout = nil,  -- string | nil
  },

  -- Optional keymaps registered during setup().
  keymaps = {
    -- If set, maps this key in normal mode to open the worktrees picker.
    open = nil,  -- string | nil  e.g. "<leader>fw"
  },

  -- Configuration for the cross-repo diff viewer (:WinterDiff).
  diff = {
    -- Default mode: "branch" (commits ahead of origin), "uncommitted" (working tree), or "staged".
    mode = "branch",  -- string

    -- Optional codediff layout override: "inline" | "side-by-side". nil uses codediff's default.
    layout = nil,  -- string | nil
  },

  -- Configuration for the workspace status dashboard (:WinterDashboard).
  dashboard = {
    position = "bottom",   -- "bottom" | "top" | "left" | "right" | "float"  (default: "bottom")
    size     = 15,         -- lines for bottom/top dock; cols for left/right dock;
                           -- or { width = 0.8, height = 0.6 } for float  (default: 15)
    border   = "rounded",  -- any snacks border string; only used for position="float"  (default: "rounded")
    title    = " Winter ", -- window title shown in the border; nil disables  (default: " Winter ")
  },
})
```

---

## Commands

| Command | Description |
|---|---|
| `:WinterWorktrees [winter-args...]` | Open the worktrees picker |
| `:Winter [worktrees\|diff\|dashboard] [winter-args...]` | Umbrella dispatcher; no args defaults to worktrees |
| `:WinterDiff[!] [env] [--repo <name>] [winter-args...]` | Open the cross-repo diff viewer for `env` (default: `alpha`); `!` forces uncommitted mode |
| `:WinterDashboard [winter-args...]` | Toggle the workspace status dashboard |
| `:WinterRefresh` | Refresh the dashboard (no-op if not open) |

### `:WinterDiff` — cross-repo feature diff viewer

Opens the aggregated cross-repo diff for a winter feature environment using [paul-gross/codediff.nvim](https://github.com/paul-gross/codediff.nvim) as the renderer. codediff computes diffs from repo worktree roots and git revisions, opening its own diff explorer in a new tab with native navigation, file-list, syntax highlighting, and stage/unstage support.

```vim
:WinterDiff              " branch diff for env alpha (config.diff.mode)
:WinterDiff beta         " branch diff for env beta
:WinterDiff!             " uncommitted working-tree diff for alpha (bang forces uncommitted)
:WinterDiff! beta        " uncommitted diff for beta
:WinterDiff beta --repo winter          " single-repo scope
:WinterDiff gamma --winter=/home/me/ws/alpha/winter   " with per-invocation winter-args
```

The `[env]` argument is the first positional argument (default: `"alpha"`). `--repo <name>` limits the diff to a single repo worktree. Any remaining arguments are passed as global winter args for that invocation, overriding `config.winter_args` — useful for targeting a dev CLI build.

**Modes:**
- **`branch`** — committed diff: HEAD vs `origin/<main_branch>` (uses `codediff.diff_repos`)
- **`uncommitted`** — working-tree changes: staged + unstaged + conflicts (uses `codediff.diff_repos_uncommitted`)
- **`staged`** — routes to the uncommitted explorer; codediff's working-tree view surfaces a "Staged Changes" group within the same explorer

codediff's explorer provides its own navigation keymaps (next/prev hunk, next/prev file, file-list, etc.). winter.nvim does NOT impose buffer-local commands.

#### Lua API

```lua
-- Open diff for env "alpha" (uses config.diff.mode)
require("winter").diff()

-- Open for a specific env and mode
require("winter").diff({ env = "beta", mode = "uncommitted" })

-- Single-repo scope
require("winter").diff({ env = "beta", repo = "winter" })

-- With a per-invocation winter_args override
require("winter").diff({ env = "gamma", winter_args = { "--winter=/path/to/dev-cli" } })
```

An autocmd `User WinterDiffOpened` fires after dispatch with `data = { env, repo, mode }` — use it to react to diff opens without the plugin imposing keymaps.

### Optional winter-args pass-through

All commands accept optional extra arguments that override `config.winter_args` for that single invocation. This is useful for targeting a development CLI build:

```vim
" Use a specific winter-cli source tree (--winter=PATH must be first — the plugin handles ordering):
:WinterWorktrees --winter=/home/me/ws/alpha/winter
:Winter worktrees --winter=/home/me/ws/alpha/winter
:WinterDiff beta --winter=/home/me/ws/alpha/winter
```

Tab completion on `:Winter <Tab>` lists available subcommands.

### Picker keymaps

| Key | Mode | Action |
|---|---|---|
| `<c-s>` | insert / normal | Toggle git-status annotations (slower, queries each repo) |

### Lua API

```lua
-- Open the worktrees picker programmatically
require("winter").worktrees()

-- Open with a per-invocation winter_args override
require("winter").worktrees({ winter_args = { "--winter=/path/to/dev-cli" } })

-- Switch directly to a path (useful for scripts)
require("winter").switch_to("/abs/path/to/worktree", "alpha/winter")
```

---

### `:WinterDashboard` — workspace status dashboard

Opens a persistent workspace status panel (toggled open/closed) showing all feature-environment worktrees and their git state. The dashboard renders as a grid of cells: one row per repo, one column per env.

```vim
:WinterDashboard     " open / toggle the dashboard
:WinterRefresh       " refresh (triggers ws status --json, re-renders)
```

#### Dashboard keymaps

| Key | Action |
|---|---|
| `l` / `<Right>` | Move selection right (next env column) |
| `h` / `<Left>` | Move selection left (prev env column) |
| `j` / `<Down>` | Move selection down (next repo row) |
| `k` / `<Up>` | Move selection up (prev repo row) |
| `d` | Open a repo diff for the selected cell (uses `config.diff.mode`) |
| `D` | Open an env-wide diff for the selected env (uses `config.diff.mode`) |
| `a` | Open a repo diff vs main (`origin/<main_branch>`) |
| `A` | Open an env-wide diff vs main (all repos) |
| `s` | Open a repo diff vs master (`origin/master`) |
| `S` | Open an env-wide diff vs master (all repos) |
| `e` | Open a repo diff vs the previous commit (`HEAD~1`) |
| `E` | Open an env-wide diff vs `HEAD~1` (all repos) |
| `o` | Open the selected worktree in Neovim (cd + session switch); closes the dashboard |
| `q` | Close the dashboard window (buffer stays alive in background) |

Press `d` or `D` to open a diff in a new tab from the dashboard. Both use the
configured `config.diff.mode` (default `branch`) — set `diff.mode = "uncommitted"`
to make `d`/`D` show working-tree (dirty) changes instead of the diff against
`origin/<main>`. For a one-off mode override use `:WinterDashboardDiff [scope] [mode]`.

The base-specific keys `a`/`A`, `s`/`S`, and `e`/`E` always open a committed diff
against a fixed base (`origin/<main_branch>`, `origin/master`, and `HEAD~1`
respectively) regardless of `config.diff.mode`. Note: for repos whose main branch
IS `master`, `a` (vs `origin/<main_branch>`) and `s` (vs `origin/master`) resolve
to the same base — they differ only for repos whose main branch is not `master`
(e.g. `main`). `o` resolves the selected worktree path and switches the active
Neovim session into it via `session.switch_to`, then closes the dashboard.

#### `:WinterDashboardDiff [scope] [mode]`

Buffer-local command available inside the dashboard buffer:

```vim
:WinterDashboardDiff              " repo diff, branch mode (explicit; d uses config.diff.mode)
:WinterDashboardDiff env          " env-wide diff, branch mode (explicit; D uses config.diff.mode)
:WinterDashboardDiff repo uncommitted  " repo uncommitted diff
:WinterDashboardDiff env staged        " env staged diff (routes to uncommitted explorer)
```

Tab-completes scope (`repo`/`env`) and mode (`branch`/`uncommitted`/`staged`).

#### Dashboard Lua API

```lua
-- Toggle the dashboard
require("winter").dashboard()

-- Refresh programmatically
require("winter").dashboard_refresh()

-- Get current selection (returns { kind, env, repo, row, col } or nil)
require("winter").dashboard_selection()

-- Open diff for the current selection
require("winter").dashboard_diff({ scope = "repo", mode = "branch" })
require("winter").dashboard_diff({ scope = "env",  mode = "uncommitted" })
```

The `_last_status` cache in `dashboard.lua` means the quick-diff keymaps reuse the already-fetched status — no extra CLI round-trip when pressing any of the diff keys (`d`/`D`, `a`/`A`, `s`/`S`, `e`/`E`) after the dashboard renders.

#### Dashboard state colors

Each worktree cell is colored according to its git status:

| Color | Meaning | Highlight group |
|---|---|---|
| green | commits ahead of upstream (`+N`) | `WinterDashAhead` |
| yellow | commits behind upstream (`-N`) | `WinterDashBehind` |
| red | uncommitted working-tree changes (`N files`) | `WinterDashDirty` |
| cyan | tracking branch diverged from remote feature branch (`[+A,-B]`) | `WinterDashDiverged` |
| orange | unborn upstream — local commits exist but no remote tracking ref (`[+]`) | `WinterDashUnborn` |
| dim | clean (zero ahead/behind/dirty) — rendered as `·` | `WinterDashClean` |

Environment name badges (extension indicators) are rendered in `WinterDashBadge` (`Special`). All groups link to standard Neovim highlight groups via `default = true`, so colorschemes override them naturally.

#### Quick-diffs (codediff.nvim)

`d` opens a diff for the currently selected repo cell (using `config.diff.mode`); `D` opens an env-wide diff for all repos. The base-specific keys open committed diffs against a fixed revision regardless of mode. All of these open in a new codediff tab (`:WinterDiff` behaviour). For uncommitted or staged variants use `:WinterDashboardDiff`:

| Keymap / command | Scope | Base / mode |
|---|---|---|
| `d` | repo | `config.diff.mode` (default: `origin/<main_branch>`) |
| `D` | env | `config.diff.mode` (default: all repos) |
| `a` | repo | `origin/<main_branch>` (fixed) |
| `A` | env | `origin/<main_branch>` (fixed, all repos) |
| `s` | repo | `origin/master` (fixed) |
| `S` | env | `origin/master` (fixed, all repos) |
| `e` | repo | `HEAD~1` (fixed) |
| `E` | env | `HEAD~1` (fixed, all repos) |
| `:WinterDashboardDiff repo uncommitted` | repo | uncommitted |
| `:WinterDashboardDiff env staged` | env | staged (routes to uncommitted explorer) |

Quick-diffs reuse the already-fetched status JSON — no extra CLI round-trip.

#### `User WinterDashboard*` events

| Event | When | `data` payload |
|---|---|---|
| `WinterDashboardOpened` | dashboard window shown (toggle open / first open) | `{ buf }` |
| `WinterDashboardRefreshed` | async refresh finished re-rendering | `{ buf }` |
| `WinterDashboardSelectionChanged` | virtual selection moved to a new cell | `{ buf, selection = { kind, env, repo, row, col } }` |

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "WinterDashboard*",
  callback = function(ev)
    local data = ev.data
    -- data.buf is always set; data.selection only for SelectionChanged.
  end,
})
```

#### Dashboard `setup` options

```lua
require("winter").setup({
  dashboard = {
    position = "bottom",   -- "bottom" | "top" | "left" | "right" | "float" (default: "bottom")
    size     = 15,         -- lines for bottom/top dock; cols for left/right dock;
                           -- or { width = 0.8, height = 0.6 } for float (default: 15)
    border   = "rounded",  -- any snacks border string; only used for position="float" (default: "rounded")
    title    = " Winter ", -- window title shown in the border; nil disables (default: " Winter ")
  },
})
```

The dashboard window is rendered through `Snacks.win` — already a hard dependency of the worktrees picker, so no additional package is required. See [context/dashboard-layout-decision.md](./context/dashboard-layout-decision.md) for the snacks-vs-nui-vs-handrolled rationale.

#### Scope note — Textual-only plugin surface

The Neovim dashboard is **read-only and MVP-scoped**. It does not implement:

- fetch/pull/push/merge operations
- drill-in detail views or `git log --graph` panels
- Rich detail panels, custom plugin screens, or Python keybound action handlers

These features remain in the **Textual `winter dashboard`** (the Python TUI), which is the canonical full-featured surface for workspace management. The Neovim dashboard is a read-only status monitor designed to live alongside your editor, not replace the TUI.

---

## How it works

### Workspace root discovery

When the picker is opened, the plugin walks up the directory tree starting from
the current buffer's file directory (falling back to `cwd` if the buffer has no
associated file). The workspace root is the first ancestor directory that
contains a `.winter/` directory. This matches the winter CLI's own root
convention, so the plugin recognises every winter workspace.

If no such ancestor is found, the plugin emits a clean message and returns
without opening a picker:

```
winter.nvim: not inside a winter workspace
```

### Data source

Once the root is found, the plugin runs:

```
winter [global-args] ws worktrees --json
```

with `cwd` set to the workspace root. The `global-args` come from
`config.winter_args` (or the per-invocation override). The command returns a
JSON array; each element has these keys: `kind` (`"worktree"` or
`"standalone"`), `env`, `repo`, `name`, `label`, and `path`. The `label`
(e.g. `"alpha/winter"` or `"winter-harness"`) is what the fuzzy matcher
operates on.

The CLI call is **asynchronous**: the picker is driven by a native snacks
finder that runs `winter` via `vim.system(…, on_exit)` off the UI thread. The
picker window opens immediately with a loading indicator and populates when the
CLI returns — Neovim is never frozen while the call is in flight. snacks also
cancels the in-flight call if the picker is closed before it returns.

### Dashboard data source

The dashboard calls:

```
winter [global-args] ws status --json
```

asynchronously via `vim.system(…, on_exit)`, then parses the JSON and renders the env×repo grid. A `vim.uv` repeating timer triggers a background refresh every 30 seconds (mirroring the Textual TUI's poll rate) so the display stays current. The initial fetch runs immediately on open; the timer fires for subsequent updates.

A non-zero exit code from `winter ws status` is treated as success if it reflects a dirty/ahead/behind workspace state (the CLI exits non-zero semantically in those cases); only genuine errors surface as notifications.

### Git-status annotations (picker)

Press `<c-s>` inside the picker to toggle git-status annotations. When ON, the
picker re-fetches with `winter [global-args] ws worktrees --json --status` (a
slower call that queries each repo's git state) and appends colored indicators
to each row. The re-fetch is async too: the picker stays interactive with a
loading indicator while it runs, and a rapid double `<c-s>` cannot render a
stale result (the toggle re-runs the finder, and snacks aborts any in-flight
fetch first).

| Symbol | Color | Meaning |
|---|---|---|
| `+N` | green | N commits ahead of upstream |
| `-N` | yellow | N commits behind upstream |
| `[+N]` | red | N uncommitted changes (dirty working tree) |
| `=` | dim | clean, zero ahead/behind |

Press `<c-s>` again to return to the fast plain list. The picker title changes
to **"Winter Worktrees (status)"** when annotations are active.

### Session-aware switching

By default, winter.nvim only **loads** existing sessions — it never creates
them automatically. On selection, `switch_to(path, label)` runs:

1. **Save the current session** (only if `create_sessions = true` AND a session
   file for the current cwd already exists — conservative, never litters sessions
   for arbitrary directories).
2. **`:cd` into the target path** using the configured `cd_command`.
3. If a session file for `path` **exists**: `source` it to restore buffers and
   layout.
4. If **no session file** exists yet and `create_sessions = true`: create one
   with `mksession!` so future switches restore it.

Both `mksession!` and `source` are wrapped in `pcall` — on failure the plugin
degrades gracefully to the bare `:cd` with a WARN notification.

Set `use_sessions = false` to skip session loading entirely and only `:cd`.
Set `create_sessions = true` to have winter write sessions on every switch (so
future visits automatically restore your layout).

---

## Extending

winter.nvim uses a feature-module architecture: each integration lives in
`lua/winter/<feature>.lua` with a corresponding `M.<feature>(opts?)` entry
point in `lua/winter/init.lua` and a `:Winter <feature>` subcommand in
`plugin/winter.lua`. Adding a new feature is a clean, obvious addition to each
of those three files.

See [context/patterns.md](./context/patterns.md) for the implicit conventions every feature module follows (async-via-cli-seam, pcall-wrap-Ex-commands, degrade-don't-error, feature module shape, and root discovery).

---

## Health check

```vim
:checkhealth winter
```

Reports:

- **snacks.nvim** — whether `require("snacks")` succeeds
- **winter CLI** — whether the configured executable is on PATH and its version
- **codediff.nvim** — whether `paul-gross/codediff.nvim` is installed (required for `:WinterDiff` and dashboard quick-diffs) and whether its expected API functions (`diff_repos`, `diff_repos_uncommitted`, `next_hunk`, etc.) are present; a warning here means diff features will degrade gracefully to an error notify when invoked

---

## Development

### Formatting and linting

```bash
make lint       # stylua --check + luacheck
make fmt        # auto-format with stylua
```

Tools used:

- **[stylua](https://github.com/JohnnyMorganz/StyLua)** — Lua formatter. Config: `.stylua.toml` (120 col, 2-space indent, double quotes).
- **[luacheck](https://github.com/mpeterv/luacheck)** — Lua linter. Config: `.luacheckrc`.

### Tests

```bash
make deps       # clone mini.nvim into .tests/ (one-time)
make test       # run mini.test suite with headless Neovim
```

Tests are written with [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md) and live under `tests/winter/`.

The test suite covers:
- `setup()` config merging and default preservation
- `config.validate()` — per-field validation with correct error messages; `diff.layout` accepted/rejected
- `cli.build_argv()` — argument ordering (global args before subcommand)
- `cli.run_async()` — injected callback-style fake runner driven synchronously
  (no real process needed)
- `worktrees.parse_items()` — pure JSON parsing, with and without status fields
- `worktrees.fetch_async()` — async fetch wired through the fake runner
- `workspace.find_root()` — directory walking with a tmp filesystem fixture
- `session.session_file()` — deterministic slugification
- `worktrees()` — clean notification when outside a workspace
- `diff.build_specs()` — pure spec building (basic, repo filter, missing dirs, unknown env)
- `diff.build_roots()` — pure root building (basic, repo filter, missing dirs, unknown env)
- `diff.open()` — codediff spy tests (branch/uncommitted/staged dispatch), degrade notify when
  codediff absent, `WinterDiffOpened` event fires with correct data, CLI fetch argv shape
- Dashboard: buffer attributes, keymaps, refresh flow, status parsing, selection navigation,
  quick-diff dispatch (`d`/`D`, `a`/`A`, `s`/`S`, `e`/`E`), `o` open-session action, `:WinterDashboardDiff` command

---

## License

MIT — see [LICENSE](LICENSE).
