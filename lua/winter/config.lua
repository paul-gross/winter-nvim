---@class Winter.Config
---@field picker Winter.PickerConfig Configuration for the snacks.nvim picker
---@field winter_cmd string The winter CLI command to invoke (default: "winter")
---@field winter_args string[] Global args inserted after winter_cmd and before the subcommand on every invocation (default: {}). Documented use: pass { "--winter=/abs/path/to/winter-source" } to run a specific winter-cli source tree. NOTE: --winter=PATH must be the first argument after the executable; the plugin guarantees ordering.
---@field keymaps Winter.KeymapConfig Optional keymaps registered by setup()
---@field use_sessions boolean Load / create Neovim sessions on directory switch (default: true)
---@field create_sessions boolean Save a Neovim session on switch so future visits restore your layout. When false (default), winter only LOADS sessions that already exist and otherwise just :cd's.
---@field session_dir string Directory where session files are stored
---@field cd_command string Vim cd command scope: "cd" | "tcd" | "lcd" (default: "cd")

---@class Winter.PickerConfig
---@field layout? string snacks.nvim layout name (e.g. "default", "ivy", "telescope")

---@class Winter.KeymapConfig
---@field open? string If set, maps this key to :WinterWorktrees in normal mode (e.g. "<leader>fw")

local M = {}

---@type Winter.Config
M.defaults = {
  picker = {
    layout = nil,
  },
  winter_cmd = "winter",
  winter_args = {},
  keymaps = {
    open = nil,
  },
  use_sessions = true,
  create_sessions = false,
  session_dir = vim.fn.stdpath("state") .. "/winter-nvim/sessions",
  cd_command = "cd",
}

---Validate user-supplied options and raise errors for invalid values.
---@param opts Winter.Config
function M.validate(opts)
  vim.validate({
    picker = { opts.picker, "table", true },
    winter_cmd = { opts.winter_cmd, "string", true },
    winter_args = { opts.winter_args, "table", true },
    keymaps = { opts.keymaps, "table", true },
    use_sessions = { opts.use_sessions, "boolean", true },
    create_sessions = { opts.create_sessions, "boolean", true },
    session_dir = { opts.session_dir, "string", true },
    cd_command = { opts.cd_command, "string", true },
  })

  if opts.winter_args ~= nil then
    for i, v in ipairs(opts.winter_args) do
      if type(v) ~= "string" then
        error(("winter.nvim: winter_args[%d] must be a string, got %s"):format(i, type(v)), 2)
      end
    end
  end

  if opts.picker then
    vim.validate({
      layout = { opts.picker.layout, "string", true },
    })
  end

  if opts.keymaps then
    vim.validate({
      open = { opts.keymaps.open, "string", true },
    })
  end
end

return M
