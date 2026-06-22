---@mod winter.health Health checks for winter.nvim
---@brief [[
--- Run `:checkhealth winter` to verify that all dependencies are satisfied.
---
--- Checks performed:
---   1. snacks.nvim can be required (folke/snacks.nvim must be installed)
---   2. The configured winter CLI executable is on PATH
---   3. codediff.nvim can be required and its expected API functions exist
---      (optional; required only for :WinterDiff and dashboard quick-diffs)
---@brief ]]

local M = {}

function M.check()
  vim.health.start("winter.nvim")

  -- Resolve the configured winter_cmd, falling back to the default if setup()
  -- has not been called yet.
  local config_module = require("winter.config")
  local winter_cmd
  local ok_cfg, winter = pcall(require, "winter")
  if ok_cfg and winter.config and type(winter.config.winter_cmd) == "string" then
    winter_cmd = winter.config.winter_cmd
  else
    winter_cmd = config_module.defaults.winter_cmd
  end

  -- 1. snacks.nvim availability
  local ok_snacks, _ = pcall(require, "snacks")
  if ok_snacks then
    vim.health.ok("snacks.nvim is available")
  else
    vim.health.error(
      "snacks.nvim is not available",
      "Install folke/snacks.nvim and ensure it is loaded before winter.nvim"
    )
  end

  -- 2. winter CLI on PATH (using the configured executable)
  if vim.fn.executable(winter_cmd) == 1 then
    local result = vim.system({ winter_cmd, "--version" }):wait()
    local version = vim.trim(result.stdout or result.stderr or ""):match("^([^\n]+)") or "(unknown version)"
    vim.health.ok(("winter CLI found (%s): %s"):format(winter_cmd, version))
  else
    vim.health.error(
      ("winter CLI not found (looked for %q)"):format(winter_cmd),
      "Install winter from https://github.com/paul-gross/winter and ensure it is on PATH, or set winter_cmd in setup()"
    )
  end

  -- 3. codediff.nvim availability and API check (only needed for :WinterDiff and dashboard quick-diffs)
  local ok_codediff, codediff = pcall(require, "codediff")
  if ok_codediff then
    local api_ok = type(codediff.diff_repos) == "function"
      and type(codediff.diff_repos_uncommitted) == "function"
      and type(codediff.next_hunk) == "function"
      and type(codediff.prev_hunk) == "function"
      and type(codediff.next_file) == "function"
      and type(codediff.prev_file) == "function"
    if api_ok then
      vim.health.ok("codediff.nvim is available (:WinterDiff, dashboard quick-diffs) and expected API is present")
    else
      vim.health.warn(
        "codediff.nvim is available but expected API functions are missing",
        "paul-gross/codediff.nvim may have been updated with a breaking change. "
          .. "Check codediff.diff_repos, codediff.diff_repos_uncommitted, codediff.next_hunk, etc."
      )
    end
  else
    vim.health.warn(
      "codediff.nvim is not available",
      "Install paul-gross/codediff.nvim to use :WinterDiff and dashboard quick-diffs"
    )
  end
end

return M
