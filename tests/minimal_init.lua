-- Minimal init for running tests with mini.test.
-- Bootstrap mini.nvim (test runner) and add this plugin to runtimepath.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Add the plugin root to runtimepath so `require("winter")` resolves
vim.opt.rtp:prepend(root)

-- Bootstrap mini.nvim from the deps directory (downloaded by the Makefile)
local mini_path = root .. "/.tests/mini.nvim"

if not vim.loop.fs_stat(mini_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/echasnovski/mini.nvim",
    mini_path,
  })
end

vim.opt.rtp:prepend(mini_path)

-- Stub out snacks.nvim so health checks and requires don't hard-error
-- in the headless test environment (no snacks installed in CI test isolation)
package.loaded["snacks"] = {}

require("mini.test")
