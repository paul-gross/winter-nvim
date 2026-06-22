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
---@field dashboard Winter.DashboardConfig Dashboard window layout (see winter.dashboard)

---@class Winter.DashboardConfig
---@field position? string Window position: "bottom"|"top"|"left"|"right"|"float" (default: "bottom")
---@field size? number|table<string,number> Window size. Integer = lines/cols for dock; 0<n<1 = fraction. For "float": {width=n, height=n}. (default: 15)
---@field border? string Border style for "float" position (any snacks border string, e.g. "rounded", "single", "double"). (default: "rounded")
---@field title? string Window title string shown in the border. nil disables. (default: " Winter ")

---@class Winter.PickerConfig
---@field layout? string snacks.nvim layout name (e.g. "default", "ivy", "telescope")

---@class Winter.DiffConfig
---@field mode string Default mode for :WinterDiff: "branch" | "uncommitted" | "staged" (default: "branch"). staged routes to the uncommitted explorer (codediff has no pure staged-only multi-repo API); the explorer shows a "Staged Changes" group within the view.
---@field layout? string Optional codediff layout override: "inline" | "side-by-side". nil uses codediff's default.

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
    layout = nil,
  },
  dashboard = {
    position = "bottom",
    size = 15,
    border = "rounded",
    title = " Winter ",
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
    _validate("diff.layout", opts.diff.layout, "string", true)

    if opts.diff.mode ~= nil then
      local valid = { branch = true, uncommitted = true, staged = true }
      if not valid[opts.diff.mode] then
        error(("winter.nvim: diff.mode must be one of branch|uncommitted|staged, got %q"):format(opts.diff.mode), 2)
      end
    end

    if opts.diff.layout ~= nil then
      local valid_layouts = { inline = true, ["side-by-side"] = true }
      if not valid_layouts[opts.diff.layout] then
        error(("winter.nvim: diff.layout must be one of inline|side-by-side, got %q"):format(opts.diff.layout), 2)
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

  _validate("dashboard", opts.dashboard, "table", true)

  if opts.dashboard then
    local d = opts.dashboard
    _validate("dashboard.position", d.position, "string", true)
    _validate("dashboard.border", d.border, "string", true)
    _validate("dashboard.title", d.title, "string", true)

    if d.position ~= nil then
      local valid_positions = { bottom = true, top = true, left = true, right = true, float = true }
      if not valid_positions[d.position] then
        error(
          ("winter.nvim: dashboard.position must be one of bottom|top|left|right|float, got %q"):format(d.position),
          2
        )
      end
    end

    if d.size ~= nil then
      local size_ok = false
      if type(d.size) == "number" then
        -- integer lines/cols or fraction 0 < n < 1; must be positive
        size_ok = d.size > 0
      elseif type(d.size) == "table" then
        -- float: { width = <number>, height = <number> }
        size_ok = type(d.size.width) == "number"
          and type(d.size.height) == "number"
          and d.size.width > 0
          and d.size.height > 0
      end
      if not size_ok then
        error("winter.nvim: dashboard.size must be a positive number or {width=number, height=number}", 2)
      end
    end
  end
end

return M
