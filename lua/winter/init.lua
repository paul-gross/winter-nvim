---@mod winter winter.nvim — Neovim integration for winter workspaces
---@brief [[
--- winter.nvim provides rich editor integration with winter workspaces.
--- Three integrated features:
---   - Worktrees picker: snacks.nvim fuzzy-find over every env/repo worktree
---     and standalone repository; jump Neovim into it, restoring a session.
---   - Workspace status dashboard: persistent toggle-able panel with
---     env×repo git state, hjkl navigation, and quick-diffs via codediff.
---   - Cross-repo diff viewer: aggregated multi-repo feature diff via
---     codediff.nvim (branch/uncommitted/staged variants).
---
--- Feature modules live under lua/winter/<feature>.lua. Adding a new feature
--- means adding lua/winter/<feature>.lua and a `M.<feature>(opts?)` entry
--- point here — one line each.
---
--- Requires:
---   - Neovim >= 0.10
---   - folke/snacks.nvim (required)
---   - winter CLI on PATH (https://github.com/paul-gross/winter)
---   - paul-gross/codediff.nvim (optional — diff features)
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

---Open the cross-repo feature diff viewer for an environment via codediff.nvim.
---
--- Resolves worktree roots and git revisions from `winter ws status --json`,
--- then opens codediff's multi-repo explorer in a new tab. See |winter.diff|.
---
---@param opts? { env?: string, repo?: string, mode?: string, winter_args?: string[], status?: table } env (default "alpha"); repo (optional single-repo scope); mode ("branch"|"uncommitted"|"staged")
function M.diff(opts)
  require("winter.diff").open(M.config, opts)
end

---Toggle the persistent workspace status dashboard.
---
--- Opens the dashboard in a window when hidden; closes the window (buffer stays
--- alive in the background) when visible. Refreshes asynchronously via
--- `winter ws status --json` on open and periodically thereafter.
---
---@param opts? { winter_args?: string[] } per-invocation overrides
function M.dashboard(opts)
  require("winter.dashboard").open(M.config, opts)
end

---Refresh the dashboard immediately if it is currently open.
---
--- Triggers an async `winter ws status --json` fetch and re-renders the
--- dashboard buffer. If the dashboard is not open this is a no-op (the
--- module-level guard in dashboard.refresh handles it silently).
--- Fires `User WinterDashboardRefreshed` after the render completes.
function M.dashboard_refresh()
  require("winter.dashboard").refresh(M.config)
end

---Return the current dashboard selection, or nil if the dashboard has not been
--- rendered or has no navigable cells.
---
--- The returned table contains the same fields as `dashboard.get_selection`:
--- `kind`, `env`, `repo`, `row`, `col` (row/col are 1-based grid indices).
---
---@return { kind: string, env: string|nil, repo: string|nil, row: integer, col: integer }|nil
function M.dashboard_selection()
  return require("winter.dashboard").get_selection()
end

---Open a diff for the current dashboard selection using codediff.nvim.
---
--- Resolves the env (and optionally the repo) from the dashboard's current
--- selection, then opens the diff in a new codediff tab.
---
---@param opts? { scope?: "repo"|"env", mode?: "branch"|"uncommitted"|"staged" } scope (default "repo"), mode (default "branch")
function M.dashboard_diff(opts)
  opts = opts or {}
  local scope = opts.scope or "repo"
  local mode = opts.mode or "branch"

  local sel = M.dashboard_selection()
  if not sel then
    vim.notify("winter.nvim: no dashboard selection", vim.log.levels.WARN)
    return
  end

  local diff_opts = {
    env = sel.env,
    mode = mode,
  }
  if scope == "repo" and sel.repo then
    diff_opts.repo = sel.repo
  end

  require("winter.diff").open(M.config, diff_opts)
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
