# winter.nvim

[![CI](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Neovim integration for [winter](https://github.com/paul-gross/winter) workspaces.

📚 **Documentation:** <https://paul-gross.github.io/winter-docs/>

This plugin provides rich editor integration with winter workspaces. The first integration is a [snacks.nvim](https://github.com/folke/snacks.nvim) **worktrees picker**: fuzzy-find any `<env>/<repo>` feature-environment worktree or standalone repository and jump Neovim's working directory into it, restoring a saved session if one exists. More integrations (e.g. a dashboard) are planned.

<!-- Screenshot placeholder: add a GIF or PNG of the picker in action -->
<!-- ![winter.nvim picker](https://github.com/paul-gross/winter-nvim/assets/screenshot.gif) -->

---

## Requirements

| Dependency | Minimum version |
|---|---|
| Neovim | 0.10+ (`vim.system` requires 0.10) |
| [folke/snacks.nvim](https://github.com/folke/snacks.nvim) | latest stable |
| [winter CLI](https://github.com/paul-gross/winter) | on `$PATH` |

Run `:checkhealth winter` after installation to confirm everything is wired up.

---

## Installation

### lazy.nvim (recommended)

```lua
{
  "paul-gross/winter-nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
  -- optional keymap:
  -- keys = {
  --   { "<leader>fw", "<cmd>WinterWorktrees<cr>", desc = "Winter: find workspace" },
  -- },
}
```

### Manual keymap example

```lua
vim.keymap.set("n", "<leader>fw", "<cmd>WinterWorktrees<cr>", { desc = "Winter: find workspace" })
```

### packer.nvim

```lua
use {
  "paul-gross/winter-nvim",
  requires = { "folke/snacks.nvim" },
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
})
```

---

## Commands

| Command | Description |
|---|---|
| `:WinterWorktrees [winter-args...]` | Open the worktrees picker |
| `:Winter [worktrees] [winter-args...]` | Umbrella dispatcher; no args defaults to worktrees |

### Optional winter-args pass-through

Both commands accept optional extra arguments that override `config.winter_args` for that single invocation. This is useful for targeting a development CLI build:

```vim
" Use a specific winter-cli source tree (--winter=PATH must be first — the plugin handles ordering):
:WinterWorktrees --winter=/home/me/ws/alpha/winter
:Winter worktrees --winter=/home/me/ws/alpha/winter
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

## How it works

### Workspace root discovery

When the picker is opened, the plugin walks up the directory tree starting from
the current buffer's file directory (falling back to `cwd` if the buffer has no
associated file). The workspace root is the first ancestor directory that
contains **both**:

- `.winter/config.toml` — a readable file
- `tools/winter-cli/` — a directory

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

### Git-status annotations

Press `<c-s>` inside the picker to toggle git-status annotations. When ON, the
picker re-fetches with `winter [global-args] ws worktrees --json --status` (a
slower call that queries each repo's git state) and appends colored indicators
to each row:

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

## Extending / roadmap

winter.nvim uses a feature-module architecture: each integration lives in
`lua/winter/<feature>.lua` with a corresponding `M.<feature>(opts?)` entry
point in `lua/winter/init.lua` and a `:Winter <feature>` subcommand in
`plugin/winter.lua`. Adding a second feature (e.g. a dashboard) is a clean,
obvious addition to each of those three files.

Planned integrations: dashboard equivalent of the winter TUI, and more.

---

## Health check

```vim
:checkhealth winter
```

Reports:

- **snacks.nvim** — whether `require("snacks")` succeeds
- **winter CLI** — whether the configured executable is on PATH and its version

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
- `cli.build_argv()` — argument ordering (global args before subcommand)
- `cli.run()` — injected fake runner (no real process needed)
- `workspace.find_root()` — directory walking with a tmp filesystem fixture
- JSON parsing shape validation
- `session.session_file()` — deterministic slugification
- `worktrees()` — clean notification when outside a workspace

---

## License

MIT — see [LICENSE](LICENSE).
