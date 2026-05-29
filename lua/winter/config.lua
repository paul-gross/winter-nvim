---@class Winter.Config
---@field picker Winter.PickerConfig Configuration for the snacks.nvim picker
---@field winter_cmd string The winter CLI command to invoke (default: "winter")
---@field keymaps Winter.KeymapConfig Optional keymaps registered by setup()

---@class Winter.PickerConfig
---@field layout? string snacks.nvim layout name (e.g. "default", "ivy", "telescope")
---@field preview? boolean Whether to show a file-tree preview in the picker (default: false)

---@class Winter.KeymapConfig
---@field open? string If set, maps this key to :Winter in normal mode (e.g. "<leader>fw")

local M = {}

---@type Winter.Config
M.defaults = {
  picker = {
    layout = nil,
    preview = false,
  },
  winter_cmd = "winter",
  keymaps = {
    open = nil,
  },
}

---Validate user-supplied options and raise errors for invalid values.
---@param opts Winter.Config
function M.validate(opts)
  vim.validate({
    picker = { opts.picker, "table", true },
    winter_cmd = { opts.winter_cmd, "string", true },
    keymaps = { opts.keymaps, "table", true },
  })

  if opts.picker then
    vim.validate({
      layout = { opts.picker.layout, "string", true },
      preview = { opts.picker.preview, "boolean", true },
    })
  end

  if opts.keymaps then
    vim.validate({
      open = { opts.keymaps.open, "string", true },
    })
  end
end

return M
