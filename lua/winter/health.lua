---@mod winter.health Health checks for winter.nvim
---@brief [[
--- Run `:checkhealth winter` to verify that all dependencies are satisfied.
---
--- Checks performed:
---   1. snacks.nvim can be required (folke/snacks.nvim must be installed)
---   2. The configured winter CLI executable is on PATH
---   3. delta.lua can be required (optional; required only for :WinterDiff)
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
    local handle = io.popen(winter_cmd .. " --version 2>&1")
    if handle then
      local version = handle:read("*l") or "(unknown version)"
      handle:close()
      vim.health.ok(("winter CLI found (%s): %s"):format(winter_cmd, version))
    else
      vim.health.ok(("winter CLI is on PATH (%s)"):format(winter_cmd))
    end
  else
    vim.health.error(
      ("winter CLI not found (looked for %q)"):format(winter_cmd),
      "Install winter from https://github.com/paul-gross/winter and ensure it is on PATH, or set winter_cmd in setup()"
    )
  end

  -- 3. delta.lua availability (only needed for the :WinterDiff viewer)
  local ok_delta, _ = pcall(require, "delta")
  if ok_delta then
    vim.health.ok("delta.lua is available (:WinterDiff renderer)")
  else
    vim.health.warn(
      "delta.lua is not available",
      "Install kokusenz/delta.lua to use the :WinterDiff cross-repo diff viewer"
    )
  end
end

return M
