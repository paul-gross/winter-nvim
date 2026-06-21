---@mod winter.health Health checks for winter.nvim
---@brief [[
--- Run `:checkhealth winter` to verify that all dependencies are satisfied.
---
--- Checks performed:
---   1. snacks.nvim can be required (folke/snacks.nvim must be installed)
---   2. The configured winter CLI executable is on PATH
---   3. the `delta` renderer can be required (optional; required only for :WinterDiff)
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

  -- 3. delta renderer availability and schema check (only needed for :WinterDiff)
  local ok_delta, delta = pcall(require, "delta")
  if ok_delta then
    -- Probe the private fields that diff.lua reads. A schema change (field
    -- rename / removal) in deltaview.nvim would silently break navigation and
    -- yank; surface it here instead.
    local schema_ok = type(delta.patch_diff) == "function"
      and type(delta.highlight_delta_artifacts) == "function"
      and type(delta.syntax_highlight_diff_set) == "function"
      and type(delta.diff_highlight_diff) == "function"
      and type(delta.setup_delta_statuscolumn) == "function"
    if schema_ok then
      vim.health.ok("delta renderer is available (:WinterDiff) and expected API is present")
    else
      vim.health.warn(
        "delta renderer is available but expected API functions are missing",
        "deltaview.nvim may have been updated with a breaking schema change. "
          .. "Navigation and yank in :WinterDiff may not work. "
          .. "Check delta.patch_diff, delta.highlight_delta_artifacts, delta.setup_delta_statuscolumn."
      )
    end
  else
    vim.health.warn(
      "delta renderer is not available",
      "Install kokusenz/deltaview.nvim (it ships the `delta` module) to use the :WinterDiff cross-repo diff viewer"
    )
  end
end

return M
