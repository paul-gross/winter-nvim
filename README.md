# winter.nvim

[![CI](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/paul-gross/winter-nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Neovim plugin that surfaces a [winter](https://github.com/paul-gross/winter) workspace's layout as a [snacks.nvim](https://github.com/folke/snacks.nvim) picker. Fuzzy-find any `<env>/<repo>` feature-environment worktree or standalone repository and jump Neovim's working directory directly into it.

> **Note:** The picker UI is not yet implemented in this release. The plugin scaffold is in place — commands, configuration, health checks, and tests all work. The picker lands in the next feature release.

<!-- Screenshot placeholder: add a GIF or PNG of the picker in action -->
<!-- ![winter.nvim picker](https://github.com/paul-gross/winter-nvim/assets/screenshot.gif) -->

---

## Requirements

| Dependency | Minimum version |
|---|---|
| Neovim | 0.9+ |
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
  --   { "<leader>fw", "<cmd>Winter<cr>", desc = "Winter workspace picker" },
  -- },
}
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
  -- Options for the snacks.nvim picker window
  picker = {
    -- snacks.nvim layout name (e.g. "default", "ivy", "telescope").
    -- nil uses the snacks default layout.
    layout = nil,        -- string | nil

    -- Whether to show a file-tree preview panel in the picker.
    preview = false,     -- boolean
  },

  -- The winter CLI executable name, or a full path if not on PATH.
  winter_cmd = "winter", -- string

  -- Optional keymaps registered during setup().
  keymaps = {
    -- If set, maps this key in normal mode to open the picker.
    open = nil,          -- string | nil  e.g. "<leader>fw"
  },
})
```

---

## Usage

### Commands

| Command | Description |
|---|---|
| `:Winter` | Open the workspace picker |
| `:WinterRepos` | Alias for `:Winter` (may narrow to repos-only in future) |

### Lua API

```lua
-- Open the picker programmatically
require("winter").open()
```

### Key mapping example

```lua
vim.keymap.set("n", "<leader>fw", "<cmd>Winter<cr>", { desc = "Winter workspace picker" })
```

---

## How it sources data

When the picker opens, winter.nvim calls:

```
winter ws worktrees --json
```

and parses the JSON output into a list of entries, each with `env`, `repo`, and `path` fields. Selecting an entry calls `vim.cmd.cd(entry.path)` to switch Neovim's working directory.

If `winter` is not on `$PATH`, or the command exits non-zero (e.g. you are outside a winter workspace), the plugin emits a clear error message rather than crashing.

---

## Health check

```vim
:checkhealth winter
```

Reports:

- **snacks.nvim** — whether `require("snacks")` succeeds
- **winter CLI** — whether `winter` is executable on PATH, and its version

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

### Adding the picker implementation

The stub is in `lua/winter/init.lua` at `M.open()`. The TODO comment outlines the planned implementation. The relevant winter CLI command is:

```
winter ws worktrees --json
```

---

## License

MIT — see [LICENSE](LICENSE).
