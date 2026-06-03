---@mod winter.session Session-aware directory switching
---@brief [[
--- Switches Neovim's working directory into a winter workspace location,
--- preferring a saved Neovim session over a bare `:cd`.
---
--- The issue that motivated this asked: load a session for the target if one
--- exists, otherwise just `cd`. So by default winter.nvim NEVER creates session
--- files on its own — it only loads ones that already exist (whether created by
--- a previous opt-in switch, or by another session manager that uses the same
--- naming scheme). Set `create_sessions = true` to have winter save a session
--- on switch so future visits restore your layout.
---
--- Session files live under `session_dir` (default
--- `vim.fn.stdpath("state") .. "/winter-nvim/sessions"`). Each target path maps
--- to a deterministic filename: the absolute path with every non-alphanumeric
--- character replaced by `_`, with `.vim` appended. `_` is used (not `%`) on
--- purpose: `%` and `#` are special in Vim Ex-command arguments and break
--- `:mksession` / `:source`.
---
--- Behaviour of `switch_to(path, label, opts)`:
---   1. If `create_sessions`, save the CURRENT session first, but only if a
---      session file for the current cwd already exists (conservative — never
---      litter sessions for arbitrary directories).
---   2. `cd` into `path` (scope from `cd_command`: cd / tcd / lcd).
---   3. If a session file for `path` exists, `source` it.
---   4. Otherwise, if `create_sessions`, write a new session for next time.
---   All session I/O is pcall-wrapped; failures degrade to the plain `cd` and
---   surface a single WARN. Routine switches are silent.
---@brief ]]

local M = {}

---Build a deterministic session filename for an absolute path.
---
--- The readable part of the filename replaces every non-alphanumeric character
--- with `_`. We avoid `%`/`#` (and other punctuation) because Vim expands them in
--- Ex-command file arguments, which corrupts `:mksession` / `:source` targets.
---
--- Because that slug is lossy — `/a/b`, `/a.b`, and `/a-b` all collapse to the
--- same `_a_b` — an 8-hex-char prefix of the path's sha256 is appended to
--- guarantee distinct paths map to distinct files. The slug stays for human
--- legibility; the hash is what makes the mapping injective.
---
---@param path string absolute target path
---@param session_dir string directory in which session files live
---@return string session_file absolute path to the session file
function M.session_file(path, session_dir)
  -- Canonicalise: drop any trailing slash so a directory passed as either
  -- "/a/b" or "/a/b/" (e.g. after fnamemodify(..., ":p")) maps to one file.
  local normalized = path:gsub("/+$", "")
  local slug = normalized:gsub("[^%w]", "_")
  local hash = vim.fn.sha256(normalized):sub(1, 8)
  return session_dir .. "/" .. slug .. "_" .. hash .. ".vim"
end

---Switch Neovim's working directory to `path`, loading or creating a session.
---
---@param path string absolute target path
---@param label string human-readable label for notifications
---@param opts table options table (subset of Winter.Config)
---@field opts.use_sessions boolean load an existing session for the target
---@field opts.create_sessions boolean save a session on switch (default false)
---@field opts.session_dir string
---@field opts.cd_command string "cd" | "tcd" | "lcd"
function M.switch_to(path, label, opts)
  local use_sessions = opts.use_sessions
  local create_sessions = opts.create_sessions
  local session_dir = opts.session_dir
  local cd_command = opts.cd_command or "cd"
  local abs = vim.fn.fnamemodify(path, ":p")

  if (use_sessions or create_sessions) and session_dir then
    vim.fn.mkdir(session_dir, "p")
  end

  -- 1. Save the current session before leaving, but only when the user opted
  --    into session creation AND a session file for cwd already exists.
  if create_sessions and session_dir then
    local current_sf = M.session_file(vim.fn.getcwd(), session_dir)
    if vim.fn.filereadable(current_sf) == 1 then
      pcall(function()
        vim.cmd.mksession({ current_sf, bang = true })
      end)
    end
  end

  -- 2. Change directory (global cd by default).
  local ok_cd = pcall(function()
    vim.cmd[cd_command]({ abs })
  end)
  if not ok_cd then
    vim.notify(("winter.nvim: could not cd to %s"):format(path), vim.log.levels.WARN)
    return
  end

  if not (use_sessions or create_sessions) or not session_dir then
    return
  end

  local sf = M.session_file(abs, session_dir)

  -- 3. Load an existing session for the target, if present.
  if use_sessions and vim.fn.filereadable(sf) == 1 then
    local ok, err = pcall(function()
      vim.cmd.source({ sf })
    end)
    if not ok then
      vim.notify(("winter.nvim: session load failed for %s (%s)"):format(label, tostring(err)), vim.log.levels.WARN)
    end
    return
  end

  -- 4. No session yet — create one only if the user opted in.
  if create_sessions then
    local ok, err = pcall(function()
      vim.cmd.mksession({ sf, bang = true })
    end)
    if not ok then
      vim.notify(("winter.nvim: session save failed for %s (%s)"):format(label, tostring(err)), vim.log.levels.WARN)
    end
  end
end

return M
