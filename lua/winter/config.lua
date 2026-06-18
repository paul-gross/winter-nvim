---@class Winter.Config
---@field picker Winter.PickerConfig Configuration for the snacks.nvim picker
---@field winter_cmd string The winter CLI command to invoke (default: "winter")
---@field winter_args string[] Global args inserted after winter_cmd and before the subcommand on every invocation (default: {}). Documented use: pass { "--winter=/abs/path/to/winter-source" } to run a specific winter-cli source tree. NOTE: --winter=PATH must be the first argument after the executable; the plugin guarantees ordering.
---@field keymaps Winter.KeymapConfig Optional keymaps registered by setup()
---@field use_sessions boolean Load / create Neovim sessions on directory switch (default: true)
---@field create_sessions boolean Save a Neovim session on switch so future visits restore your layout. When false (default), winter only LOADS sessions that already exist and otherwise just :cd's.
---@field session_dir string Directory where session files are stored
---@field cd_command string Vim cd command scope: "cd" | "tcd" | "lcd" (default: "cd")
---@field diff Winter.DiffConfig Cross-repo feature diff viewer (see winter.diff)

---@class Winter.PickerConfig
---@field layout? string snacks.nvim layout name (e.g. "default", "ivy", "telescope")

---@class Winter.DiffConfig
---@field mode string Default mode for :WinterDiff: "branch" | "uncommitted" | "staged" (default: "branch")
---@field drawer boolean Auto-open the location-list file drawer on open (default: false; it is a window split — summon on demand with :WinterDiffDrawer)
---@field yank_registers string[] Registers :WinterDiffYank writes to (default: { "+", '"' })
---@field yank_format? fun(ctx: { path: string, lines: string, language: string, content: string }): string Optional override for the yank text; nil uses the built-in Claude xml format

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
  diff = {
    mode = "branch",
    drawer = false,
    yank_registers = { "+", '"' },
    yank_format = nil,
  },
}

---Validate user-supplied options and raise errors for invalid values.
---@param opts Winter.Config
function M.validate(opts)
  -- Dispatch helper: use the per-field form on Neovim >= 0.11 (silences the
  -- 0.11 deprecation warning on the table form) and fall back to the table
  -- form on 0.10, where the per-field signature does not exist.
  local _has_new_validate = vim.fn.has("nvim-0.11") == 1
  local function _validate(name, value, vtype, optional)
    if _has_new_validate then
      vim.validate(name, value, vtype, optional)
    else
      vim.validate({ [name] = { value, vtype, optional } })
    end
  end

  _validate("picker", opts.picker, "table", true)
  _validate("winter_cmd", opts.winter_cmd, "string", true)
  _validate("winter_args", opts.winter_args, "table", true)
  _validate("keymaps", opts.keymaps, "table", true)
  _validate("use_sessions", opts.use_sessions, "boolean", true)
  _validate("create_sessions", opts.create_sessions, "boolean", true)
  _validate("session_dir", opts.session_dir, "string", true)
  _validate("cd_command", opts.cd_command, "string", true)
  _validate("diff", opts.diff, "table", true)

  if opts.diff then
    _validate("diff.mode", opts.diff.mode, "string", true)
    _validate("diff.drawer", opts.diff.drawer, "boolean", true)
    _validate("diff.yank_registers", opts.diff.yank_registers, "table", true)
    _validate("diff.yank_format", opts.diff.yank_format, "function", true)

    if opts.diff.mode ~= nil then
      local valid = { branch = true, uncommitted = true, staged = true }
      if not valid[opts.diff.mode] then
        error(("winter.nvim: diff.mode must be one of branch|uncommitted|staged, got %q"):format(opts.diff.mode), 2)
      end
    end
  end

  if opts.winter_args ~= nil then
    for i, v in ipairs(opts.winter_args) do
      if type(v) ~= "string" then
        error(("winter.nvim: winter_args[%d] must be a string, got %s"):format(i, type(v)), 2)
      end
    end
  end

  if opts.picker then
    _validate("picker.layout", opts.picker.layout, "string", true)
  end

  if opts.keymaps then
    _validate("keymaps.open", opts.keymaps.open, "string", true)
  end
end

return M
