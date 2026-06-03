---@mod winter.workspace Workspace root discovery
---@brief [[
--- Provides a pure helper used by winter.nvim:
---
---   `find_root(start_path)` — walks up from `start_path` looking for a
---   directory that contains a `.winter/` directory. Returns the path string on
---   success, nil on failure.
---@brief ]]

local M = {}

---Walk up from `start_path` to find the winter workspace root.
---
--- The workspace root is the first ancestor directory that contains a `.winter/`
--- directory. This matches the winter CLI's own root convention (it locates the
--- workspace by walking up for a `.winter/` directory), so the plugin recognises
--- every winter workspace — not just ones that vendor the CLI under `tools/`.
---
--- Returns nil when no such ancestor exists (i.e. cwd is not inside a
--- winter workspace).
---
---@param start_path string absolute path to start searching from (a file path or directory)
---@return string|nil root absolute path to the workspace root, or nil
function M.find_root(start_path)
  -- Normalise: if start_path is a file, begin from its parent directory.
  local dir = start_path
  if vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  -- Walk up, stopping at the filesystem root.
  local prev = nil
  while dir ~= prev do
    if vim.fn.isdirectory(dir .. "/.winter") == 1 then
      return dir
    end
    prev = dir
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  return nil
end

return M
