---@mod winter winter.nvim
---@brief [[
--- A Neovim plugin that surfaces a winter workspace's layout as a snacks.nvim
--- picker. Fuzzy-find any <env>/<repo> feature-environment worktree or
--- standalone repo and switch Neovim's working directory into it.
---
--- Requires:
---   - Neovim >= 0.9
---   - folke/snacks.nvim
---   - winter CLI on PATH (https://github.com/paul-gross/winter)
---@brief ]]

local config_module = require("winter.config")

---@class Winter
local M = {}

---@type Winter.Config
M.config = vim.deepcopy(config_module.defaults)

---Set up winter.nvim with user options.
---
--- Options are deep-merged with the defaults; you only need to specify
--- the fields you want to override.
---
---@param opts? Winter.Config
---@usage [[
--- require("winter").setup({
---   picker = { layout = "ivy" },
---   keymaps = { open = "<leader>fw" },
--- })
---@usage ]]
function M.setup(opts)
  opts = opts or {}
  config_module.validate(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(config_module.defaults), opts)

  if M.config.keymaps.open then
    vim.keymap.set("n", M.config.keymaps.open, function()
      M.open()
    end, { desc = "Winter: open workspace picker" })
  end
end

---Open the winter workspace picker.
---
--- Shells out to `winter ws worktrees --json` to discover all
--- feature-environment worktrees and standalone repos, then presents them
--- in a snacks.nvim fuzzy picker. Selecting an entry changes Neovim's
--- working directory to that worktree root.
---
--- NOTE: The picker implementation is not yet available in this release.
--- Watch https://github.com/paul-gross/winter-nvim for updates.
function M.open()
  -- TODO(feature): implement snacks.nvim picker over `winter ws worktrees --json`
  --
  -- Planned implementation outline:
  --   1. Run: vim.system({ config.winter_cmd, "ws", "worktrees", "--json" }, ...)
  --   2. Parse JSON output into a list of { env, repo, path } entries
  --   3. Feed list to Snacks.picker() with a custom formatter and action that
  --      calls vim.cmd.cd(entry.path)
  --   4. Fall back gracefully when not inside a winter workspace (non-zero exit)
  vim.notify("winter.nvim: picker not yet implemented", vim.log.levels.WARN)
end

return M
