---@mod winter.workspace Workspace root discovery
---@brief [[
--- Provides helpers used by winter.nvim:
---
---   `find_root(start_path)` — walks up from `start_path` looking for a
---   directory that contains a `.winter/` directory. Returns the path string on
---   success, nil on failure.
---
---   `find_root_from_context()` — resolves the workspace root from the current
---   Neovim context: tries the current buffer's directory first (so a file open
---   inside a worktree always wins), then falls back to `cwd`. Both features
---   (worktrees and diff) use this shared helper so root-discovery is consistent.
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

---Discover the workspace root from the current Neovim editor context.
---
--- Tries the current buffer's file directory first — so a buffer open inside a
--- feature-environment worktree always resolves the correct root even when cwd
--- happens to be somewhere else. Falls back to `vim.fn.getcwd()` when the
--- buffer has no associated path (e.g. an unnamed scratch buffer).
---
--- Both the worktrees and diff features call this so root-discovery is
--- consistent across the plugin.
---
---@return string|nil root absolute path to the workspace root, or nil
function M.find_root_from_context()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= "" then
    local root = M.find_root(vim.fn.fnamemodify(buf_name, ":p:h"))
    if root then
      return root
    end
  end
  return M.find_root(vim.fn.getcwd())
end

return M
