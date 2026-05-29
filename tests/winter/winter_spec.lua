-- Tests for the winter.nvim scaffold.
-- Run via: make test (uses mini.test)

local T = MiniTest.new_set()

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------

T["module loads without error"] = function()
  local ok, winter = pcall(require, "winter")
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(winter), "table")
end

T["module exposes setup() function"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.setup), "function")
end

T["module exposes open() function"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.open), "function")
end

-- ---------------------------------------------------------------------------
-- Config / setup()
-- ---------------------------------------------------------------------------

T["setup() with no args applies defaults"] = function()
  local winter = require("winter")
  winter.setup()

  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
  MiniTest.expect.equality(winter.config.picker.preview, false)
  MiniTest.expect.equality(winter.config.picker.layout, nil)
  MiniTest.expect.equality(winter.config.keymaps.open, nil)
end

T["setup() merges opts over defaults"] = function()
  local winter = require("winter")
  winter.setup({
    winter_cmd = "winter2",
    picker = { preview = true },
  })

  MiniTest.expect.equality(winter.config.winter_cmd, "winter2")
  MiniTest.expect.equality(winter.config.picker.preview, true)
  -- unset key still gets default
  MiniTest.expect.equality(winter.config.picker.layout, nil)
end

T["setup() does not mutate defaults when called twice"] = function()
  local config_module = require("winter.config")
  local winter = require("winter")

  winter.setup({ winter_cmd = "custom" })
  -- Reset to defaults
  winter.setup({})

  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
  -- Ensure the module-level defaults table itself was not mutated
  MiniTest.expect.equality(config_module.defaults.winter_cmd, "winter")
end

-- ---------------------------------------------------------------------------
-- User commands (registered by plugin/winter.lua)
-- ---------------------------------------------------------------------------

T[":Winter command is registered after plugin file runs"] = function()
  -- Source the plugin file (guards against double-load)
  -- Reset the guard so we can source it in isolation
  vim.g.loaded_winter = nil
  local plugin_path = vim.fn.fnamemodify(
    debug.getinfo(1, "S").source:sub(2),
    ":p:h:h:h"
  ) .. "/plugin/winter.lua"
  vim.cmd("source " .. plugin_path)

  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(type(cmds["Winter"]), "table")
end

T[":WinterRepos command is registered after plugin file runs"] = function()
  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(type(cmds["WinterRepos"]), "table")
end

-- ---------------------------------------------------------------------------
-- open() stub
-- ---------------------------------------------------------------------------

T["open() emits a WARN notification (stub behaviour)"] = function()
  local winter = require("winter")
  winter.setup()

  local notified = false
  local orig_notify = vim.notify
  vim.notify = function(msg, level, _opts)
    if level == vim.log.levels.WARN and msg:find("not yet implemented") then
      notified = true
    end
  end

  winter.open()

  vim.notify = orig_notify
  MiniTest.expect.equality(notified, true)
end

return T
