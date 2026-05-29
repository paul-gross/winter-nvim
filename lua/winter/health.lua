---@mod winter.health Health checks for winter.nvim
---@brief [[
--- Run `:checkhealth winter` to verify that all dependencies are satisfied.
---
--- Checks performed:
---   1. snacks.nvim can be required (folke/snacks.nvim must be installed)
---   2. The `winter` CLI is executable on PATH
---@brief ]]

local M = {}

function M.check()
  vim.health.start("winter.nvim")

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

  -- 2. winter CLI on PATH
  if vim.fn.executable("winter") == 1 then
    local handle = io.popen("winter --version 2>&1")
    if handle then
      local version = handle:read("*l") or "(unknown version)"
      handle:close()
      vim.health.ok("winter CLI found: " .. version)
    else
      vim.health.ok("winter CLI is on PATH")
    end
  else
    vim.health.error(
      "winter CLI not found on PATH",
      "Install winter from https://github.com/paul-gross/winter and ensure it is on your PATH"
    )
  end
end

return M
