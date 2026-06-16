---@mod winter winter.nvim — Neovim integration for winter workspaces
---@brief [[
--- winter.nvim provides rich editor integration with winter workspaces.
--- The first integration is a snacks.nvim worktrees picker: fuzzy-find any
--- `<env>/<repo>` feature-environment worktree or standalone repository and
--- jump Neovim's working directory into it, restoring a saved session if one
--- exists. More integrations (e.g. a dashboard) are planned.
---
--- Feature modules live under lua/winter/<feature>.lua. Adding a new feature
--- (e.g. a dashboard) means adding lua/winter/dashboard.lua and a
--- `M.dashboard(opts?)` entry point here — one line each.
---
--- Requires:
---   - Neovim >= 0.10
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
---   use_sessions = true,
---   cd_command = "cd",
---   picker = { layout = "ivy" },
---   keymaps = { open = "<leader>fw" },
---   -- Override global winter args (e.g. to run a dev CLI source tree):
---   winter_args = { "--winter=/home/me/ws/alpha/winter" },
--- })
---@usage ]]
function M.setup(opts)
  opts = opts or {}
  config_module.validate(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(config_module.defaults), opts)

  if M.config.keymaps.open then
    vim.keymap.set("n", M.config.keymaps.open, function()
      M.worktrees()
    end, { desc = "Winter: find workspace worktree" })
  end
end

---Open the winter worktrees picker.
---
--- Discovers the workspace root, fetches `winter [global_args] ws worktrees
--- --json`, and opens a snacks.nvim fuzzy picker. Selecting an item calls
--- `switch_to`.
---
---@param opts? winter.worktrees.OpenOpts per-invocation overrides (e.g. winter_args)
function M.worktrees(opts)
  require("winter.worktrees").open(M.config, opts)
end

---Open the cross-repo feature diff viewer for an environment.
---
--- Fetches the aggregated `winter ws diff <env>` stream and renders every repo's
--- changes in one delta-rendered buffer. See |winter.diff|.
---
---@param opts? { env?: string, mode?: string } env (default "alpha") and mode ("branch"|"uncommitted"|"staged")
function M.diff(opts)
  require("winter.diff").open(M.config, opts)
end

---Switch Neovim into `path`, loading an existing session or creating a new one.
---
--- This function is exposed on the public API so it can be called from scripts
--- or other plugins without going through the picker.
---
---@param path string absolute path to the target worktree / repo
---@param label? string human-readable label for notifications (defaults to path)
function M.switch_to(path, label)
  label = label or path
  local session = require("winter.session")
  session.switch_to(path, label, {
    use_sessions = M.config.use_sessions,
    create_sessions = M.config.create_sessions,
    session_dir = M.config.session_dir,
    cd_command = M.config.cd_command,
  })
end

---@deprecated Use `worktrees()` instead.
---Open the winter workspace picker (deprecated alias for `worktrees()`).
---@param opts? winter.worktrees.OpenOpts
function M.open(opts)
  M.worktrees(opts)
end

return M
