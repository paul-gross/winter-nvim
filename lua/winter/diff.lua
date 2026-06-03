---@mod winter.diff Cross-repo feature diff viewer
---@brief [[
--- Renders the aggregated `winter ws diff <env>` stream — every repo's changes
--- in one repo-prefixed unified diff — into a single read-only buffer using
--- delta.lua (https://github.com/kokusenz/delta.lua) as the renderer.
---
--- delta.lua's `patch_diff` accepts an arbitrary unified-diff STRING, which is
--- exactly what `winter ws diff --no-headers` emits, so the whole feature shows
--- in one delta-styled buffer (per-file titles, gutter source line numbers,
--- word-level highlighting) — something git-ref-bound viewers cannot do.
---
--- The plugin exposes a verb surface as BUFFER-LOCAL commands (and matching Lua
--- functions); keybindings live in the user's own config. On open the module
--- fires a `User WinterDiffOpened` autocmd (data = { buf, env }) so callers can
--- bind buffer-local keys without the plugin imposing any.
---
---   :WinterDiff[!] [env]      open (! = uncommitted working tree, else --branch)
---   :WinterDiffNextHunk       cursor → next hunk      (also M.next_hunk)
---   :WinterDiffPrevHunk       cursor → prev hunk      (also M.prev_hunk)
---   :WinterDiffNextFile       cursor → next file      (also M.next_file)
---   :WinterDiffPrevFile       cursor → prev file      (also M.prev_file)
---   :WinterDiffClose          close diff + its loclist (also M.close)
---   :WinterDiffYank           yank selection as Claude context (also M.yank)
---
--- Requires `kokusenz/delta.lua` on the runtimepath.
---@brief ]]

local cli = require("winter.cli")
local workspace = require("winter.workspace")

local M = {}

-- Buffer-local state key. Holds { env, files = {rows}, hunks = {rows} } where
-- rows are 1-based buffer lines of file titles and hunk starts respectively.
local STATE = "winter_diff"

---Resolve the winter renderer (delta.lua), or notify and return nil.
---@return table|nil delta
local function load_delta()
  local ok, delta = pcall(require, "delta")
  if not ok then
    vim.notify(
      "winter.diff: delta.lua not found. Install kokusenz/delta.lua to use :WinterDiff.",
      vim.log.levels.ERROR
    )
    return nil
  end
  return delta
end

-- The diff modes :WinterDiff understands. "uncommitted" is the no-flag default.
local VALID_MODES = { branch = true, uncommitted = true, staged = true }

---Build the `ws diff` subcommand argv tail for a mode (pure; unit-tested).
---@param env string
---@param mode string "branch" | "uncommitted" | "staged"
---@return string[]
function M.diff_args(env, mode)
  local args = { "ws", "diff", env, "--no-headers" }
  if mode == "branch" then
    args[#args + 1] = "--branch"
  elseif mode == "staged" then
    args[#args + 1] = "--staged"
  end
  return args
end

---Derive file-title rows and hunk-start rows from delta.lua's buffer metadata.
---File titles come from `b:delta_artifacts` (type "title", excluding the
---"Line N" multi-hunk headers). Hunk starts come from `b:delta_diff_data_set`,
---each hunk's first line carrying its rendered row in `formatted_diff_line_num`
---(0-based; +1 for the 1-based buffer line).
---@param bufnr integer
---@return integer[] files, integer[] hunks
local function compute_nav(bufnr)
  local files, hunks = {}, {}

  for _, a in ipairs(vim.b[bufnr].delta_artifacts or {}) do
    if a.type == "title" and not tostring(a.content):match("^Line %d") then
      files[#files + 1] = a.row_number + 1
    end
  end

  for _, file in ipairs(vim.b[bufnr].delta_diff_data_set or {}) do
    for _, hunk in ipairs(file.hunks or {}) do
      -- Land on the first *changed* line (added/removed), not the leading
      -- context lines git includes at the top of each hunk.
      local row
      for _, line in ipairs(hunk.lines or {}) do
        if line.line_type ~= "context" and line.formatted_diff_line_num then
          row = line.formatted_diff_line_num + 1
          break
        end
      end
      if not row then
        local first = hunk.lines and hunk.lines[1]
        row = first and first.formatted_diff_line_num and (first.formatted_diff_line_num + 1)
      end
      if row then
        hunks[#hunks + 1] = row
      end
    end
  end

  table.sort(files)
  table.sort(hunks)
  return files, hunks
end

---Jump the cursor to the next/prev row in a sorted row list (cursor-based, so
---it is independent of the loclist pointer).
---@param which "files" | "hunks"
---@param dir 1 | -1
local function jump(which, dir)
  local state = vim.b[STATE]
  if not state then
    return
  end
  local rows = state[which] or {}
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > cur then
        target = r
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.next_hunk()
  jump("hunks", 1)
end
function M.prev_hunk()
  jump("hunks", -1)
end
function M.next_file()
  jump("files", 1)
end
function M.prev_file()
  jump("files", -1)
end

---Close the diff buffer and its location-list drawer.
function M.close()
  pcall(vim.cmd, "lclose")
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[STATE] then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

---Populate and open the location-list file drawer for the current diff buffer.
---Opt-in (it is a window split): bound to a key or run :WinterDiffDrawer.
function M.drawer()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = vim.b[STATE]
  if not state then
    return
  end
  local items = {}
  for _, a in ipairs(vim.b[bufnr].delta_artifacts or {}) do
    if a.type == "title" and not tostring(a.content):match("^Line %d") then
      items[#items + 1] = { bufnr = bufnr, lnum = a.row_number + 1, col = 1, text = a.content }
    end
  end
  if #items == 0 then
    return
  end
  vim.fn.setloclist(0, items, " ")
  vim.fn.setloclist(0, {}, "a", { title = "winter diff: " .. state.env })
  vim.cmd("botright lopen")
end

---Re-run the diff that produced the current buffer (same env + mode), replacing
---it in place. Cursor restoration across a refresh is intentionally not done yet.
function M.refresh()
  local state = vim.b[STATE]
  if not state then
    return
  end
  -- Capture cursor line/col + topline (scroll) so the re-rendered diff restores
  -- both the cursor position and the top of the buffer by line number.
  local view = vim.fn.winsaveview()
  M.open(require("winter").config, { env = state.env, mode = state.mode, restore_view = view })
end

---Default Claude-context formatter (matches prompt-yank's "claude" xml preset).
---@param ctx { path: string, lines: string, language: string, content: string }
---@return string
local function default_format(ctx)
  return ('<file path="%s" lines="%s" language="%s">\n%s\n</file>'):format(
    ctx.path,
    ctx.lines,
    ctx.language,
    ctx.content
  )
end

---Find the file path (repo-prefixed) governing a buffer row by walking up to
---the nearest file-title artifact.
---@param bufnr integer
---@param row integer 1-based
---@return string|nil
local function file_at(bufnr, row)
  local titles = {}
  for _, a in ipairs(vim.b[bufnr].delta_artifacts or {}) do
    if a.type == "title" and not tostring(a.content):match("^Line %d") then
      titles[#titles + 1] = { row = a.row_number + 1, path = a.content }
    end
  end
  local path
  for _, t in ipairs(titles) do
    if t.row <= row then
      path = t.path
    else
      break
    end
  end
  return path
end

---Resolve the source line range (in the new file) for a buffer row range using
---`b:delta_line_map`. Removed lines fall back to their old line number.
---@param bufnr integer
---@param l1 integer
---@param l2 integer
---@return integer|nil lo, integer|nil hi
local function source_lines(bufnr, l1, l2)
  local map = vim.b[bufnr].delta_line_map or {}
  local lo, hi
  for r = l1, l2 do
    local e = map[r]
    local n = e and (e.new or e.old)
    if n then
      lo = lo and math.min(lo, n) or n
      hi = hi and math.max(hi, n) or n
    end
  end
  return lo, hi
end

---Yank the current line (or a visual/range selection) as LLM context, with the
---real repo-prefixed path and source line numbers recovered from delta.lua's
---metadata. Copies to the configured registers.
---@param opts? { line1?: integer, line2?: integer }
function M.yank(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local state = vim.b[STATE]
  if not state then
    vim.notify("winter.diff: not a winter diff buffer", vim.log.levels.WARN)
    return
  end
  local l1 = opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
  local l2 = opts.line2 or l1

  local path = file_at(bufnr, l1) or "?"
  local lo, hi = source_lines(bufnr, l1, l2)
  local span = lo and (lo == hi and tostring(lo) or (lo .. "-" .. hi)) or "?"
  local language = vim.filetype.match({ filename = path }) or vim.fn.fnamemodify(path, ":e")
  local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false), "\n")

  local cfg = require("winter").config.diff or {}
  local formatter = cfg.yank_format or default_format
  local text = formatter({ path = path, lines = span, language = language, content = content })

  for _, reg in ipairs(cfg.yank_registers or { "+", '"' }) do
    vim.fn.setreg(reg, text)
  end
  vim.notify(("winter.diff: yanked %s:%s"):format(path, span))
end

---Open the real source file under the cursor at the matching line, centered.
---
--- Resolves the repo-prefixed diff path to `<root>/<env>/<path>`, opens it via
--- `open` ("edit" | "split" | "vsplit" | "tabedit"), places the cursor on the
--- source line recovered from `delta_line_map`, and centers with `zz`.
---@param open? string "edit" (default) | "split" | "vsplit" | "tabedit"
function M.goto_file(open)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = vim.b[STATE]
  if not state then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path = file_at(bufnr, row)
  if not path then
    vim.notify("winter.diff: no file at cursor", vim.log.levels.WARN)
    return
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  local target = source_lines(bufnr, row, math.min(row + 40, last)) or 1
  local abs = ("%s/%s/%s"):format(state.root, state.env, path)
  local opener = ({ edit = "edit", split = "split", vsplit = "vsplit", tabedit = "tabedit" })[open] or "edit"
  vim.cmd(opener .. " " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
  vim.cmd("normal! zz")
end

---Register the buffer-local verb surface on the diff buffer.
---@param bufnr integer
local function register_commands(bufnr)
  local cmd = function(name, fn, o)
    vim.api.nvim_buf_create_user_command(bufnr, name, fn, o or {})
  end
  cmd("WinterDiffNextHunk", M.next_hunk)
  cmd("WinterDiffPrevHunk", M.prev_hunk)
  cmd("WinterDiffNextFile", M.next_file)
  cmd("WinterDiffPrevFile", M.prev_file)
  cmd("WinterDiffClose", M.close)
  cmd("WinterDiffDrawer", M.drawer)
  cmd("WinterDiffRefresh", M.refresh)
  cmd("WinterDiffGotoFile", function()
    M.goto_file("edit")
  end)
  cmd("WinterDiffGotoFileSplit", function()
    M.goto_file("split")
  end)
  cmd("WinterDiffGotoFileVSplit", function()
    M.goto_file("vsplit")
  end)
  cmd("WinterDiffGotoFileTab", function()
    M.goto_file("tabedit")
  end)
  cmd("WinterDiffYank", function(o)
    M.yank({ line1 = o.line1, line2 = o.line2 })
  end, { range = true })
end

---Render a diff string into a new tab and wire up the buffer.
---@param diffstring string
---@param env string
---@param cfg Winter.Config
---@param mode string the diff mode used (stored so :WinterDiffRefresh can replay it)
---@param root string workspace root (used to resolve <root>/<env>/<path> for goto_file)
---@param restore_view? table a vim.fn.winsaveview() table to reapply after render (refresh)
local function render(diffstring, env, mode, cfg, root, restore_view)
  local delta = load_delta()
  if not delta then
    return
  end
  local bufnr = delta.patch_diff(diffstring, true, nil, {})
  if not bufnr then
    return
  end

  -- Open in the CURRENT window — it is just a buffer (no drawer, no side-by-side,
  -- no file tree), so it needs no tab or special layout. Open a tab first
  -- yourself if you want one.
  local win = vim.api.nvim_get_current_win()
  local prev = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, bufnr)

  -- If we replaced a previous winter diff buffer (e.g. on refresh) and it is no
  -- longer displayed anywhere, wipe it so refreshes do not accumulate buffers.
  if prev ~= bufnr and vim.api.nvim_buf_is_valid(prev) and vim.b[prev][STATE] and #vim.fn.win_findbuf(prev) == 0 then
    pcall(vim.api.nvim_buf_delete, prev, { force = true })
  end

  -- Promote delta's scratch buffer (nofile/unlisted/wipe) to a normal, listed
  -- buffer so it participates in the user's window/MRU model like any file.
  -- Guard :w on the synthetic name with a no-op BufWriteCmd.
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  local name = "WinterDiff " .. env
  if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
    pcall(vim.api.nvim_buf_set_name, bufnr, name .. " #" .. bufnr)
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      vim.notify("winter.diff: read-only diff buffer (not written)", vim.log.levels.INFO)
    end,
  })

  pcall(delta.highlight_delta_artifacts, bufnr)
  pcall(delta.syntax_highlight_diff_set, bufnr)
  pcall(delta.diff_highlight_diff, bufnr)
  pcall(delta.setup_delta_statuscolumn, bufnr, win)
  -- Read-only, but NOT shown as edited: keep buftype='' so the user's
  -- main-window logic counts it as a real buffer, while clearing the modified
  -- flag that delta's nvim_buf_set_lines left behind.
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false

  local files, hunks = compute_nav(bufnr)
  vim.b[bufnr][STATE] = { env = env, mode = mode, root = root, files = files, hunks = hunks }
  register_commands(bufnr)

  -- The drawer is a window split, so it is opt-in (config.diff.drawer or the
  -- :WinterDiffDrawer command); the diff itself stays just a buffer.
  if (cfg.diff or {}).drawer then
    M.drawer()
    pcall(vim.api.nvim_set_current_win, win)
  end

  -- Restore the pre-refresh view (cursor + scroll) by line number.
  if restore_view then
    pcall(vim.fn.winrestview, restore_view)
  end

  vim.api.nvim_exec_autocmds("User", { pattern = "WinterDiffOpened", data = { buf = bufnr, env = env } })
end

---Open the cross-repo diff for a feature environment.
---
--- Fetches `winter [global_args] ws diff <env> --no-headers [--branch]`
--- asynchronously and renders it via delta.lua in a new tab.
---
---@param cfg Winter.Config plugin configuration
---@param opts? { env?: string, mode?: string, restore_view?: table } env (default "alpha"); mode ("branch"|"uncommitted"|"staged", default cfg.diff.mode); restore_view is an internal winsaveview() table reapplied after render (used by refresh)
function M.open(cfg, opts)
  opts = opts or {}
  local env = opts.env or "alpha"
  -- Single source of truth for the mode default, so :WinterDiff, :Winter diff,
  -- and require("winter").diff{} all honour cfg.diff.mode identically.
  local mode = opts.mode or (cfg.diff and cfg.diff.mode) or "branch"
  if not VALID_MODES[mode] then
    vim.notify(
      ("winter.diff: invalid mode %q (use branch|uncommitted|staged)"):format(mode),
      vim.log.levels.ERROR
    )
    return
  end

  local root = workspace.find_root(vim.fn.getcwd()) or workspace.find_root(vim.fn.expand("%:p"))
  if not root then
    vim.notify("winter.diff: not inside a winter workspace", vim.log.levels.ERROR)
    return
  end

  cli.run_async(root, cfg, cfg.winter_args, M.diff_args(env, mode), function(result, err)
    vim.schedule(function()
      if err then
        vim.notify("winter.diff: " .. err, vim.log.levels.ERROR)
        return
      end
      local diffstring = result.stdout or ""
      if vim.trim(diffstring) == "" then
        vim.notify(("winter.diff: %s has no changes (%s)"):format(env, mode), vim.log.levels.INFO)
        return
      end
      render(diffstring, env, mode, cfg, root, opts.restore_view)
    end)
  end)
end

return M
