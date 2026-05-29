---@mod winter.worktrees Worktrees picker feature module
---@brief [[
--- Provides the worktrees picker: fuzzy-find any `<env>/<repo>` feature-
--- environment worktree or standalone repository and switch Neovim's working
--- directory into it, preferring a saved session for the target over a bare
--- `:cd`.
---
--- Entry point: `M.open(cfg, opts?)`.
---
--- Inside the picker, press `<c-s>` to toggle git-status annotations.
--- When annotations are ON, each row shows:
---   +N (green)    — N commits ahead of upstream
---   -N (yellow)   — N commits behind upstream
---   [+N] (red)    — N uncommitted changes (dirty)
---   = (dim)       — clean, zero ahead/behind
--- This costs an extra `winter ws worktrees --json --status` call (~1s).
---@brief ]]

local M = {}

---@class winter.worktrees.OpenOpts
---@field winter_args? string[] Override the configured global winter_args for this invocation only.

---@class winter.WorktreeItem
---@field kind string "worktree" or "standalone"
---@field env string|nil env name (e.g. "alpha"), nil for standalones
---@field repo string|nil repo name (e.g. "winter"), nil for standalones
---@field name string|nil standalone name, nil for worktrees
---@field label string display label used for fuzzy matching (e.g. "alpha/winter")
---@field path string absolute path to the worktree / standalone checkout
---@field ahead integer|nil commits ahead of upstream (nil when status not loaded)
---@field behind integer|nil commits behind upstream (nil when status not loaded)
---@field dirty integer|nil count of dirty files (nil when status not loaded)

---Build the subcommand args for `winter ws worktrees --json [--status]`.
---
---@param show_status boolean whether to include --status flag
---@return string[] subcommand_args
function M.build_subcommand(show_status)
  local args = { "ws", "worktrees", "--json" }
  if show_status then
    args[#args + 1] = "--status"
  end
  return args
end

---Fetch and parse worktree items from the winter CLI.
---
---@param root string workspace root
---@param cfg Winter.Config plugin configuration
---@param effective_global_args string[] global args (possibly overridden per-invocation)
---@param show_status boolean whether to request status fields
---@param runner? fun(argv: string[], cwd: string): {code: integer, stdout: string, stderr: string}
---@return winter.WorktreeItem[]|nil items, string|nil err
function M.fetch(root, cfg, effective_global_args, show_status, runner)
  local cli = require("winter.cli")
  local subcommand_args = M.build_subcommand(show_status)

  local result, err = cli.run(root, cfg, effective_global_args, subcommand_args, runner)
  if not result then
    return nil, err
  end

  local stdout = vim.trim(result.stdout or "")
  if stdout == "" then
    return nil, "winter CLI returned empty output"
  end

  local ok_json, decoded = pcall(vim.json.decode, stdout)
  if not ok_json then
    return nil, ("failed to parse winter CLI JSON: %s"):format(tostring(decoded))
  end

  if type(decoded) ~= "table" then
    return nil, "winter CLI JSON is not an array"
  end

  ---@type winter.WorktreeItem[]
  local items = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and type(entry.label) == "string" and type(entry.path) == "string" then
      local item = {
        kind = entry.kind or "worktree",
        env = entry.env,
        repo = entry.repo,
        name = entry.name,
        label = entry.label,
        path = entry.path,
        -- Status fields: present only when fetched with --status.
        -- vim.json.decode maps JSON null → vim.NIL, so normalise to nil.
        ahead = (type(entry.ahead) == "number") and entry.ahead or nil,
        behind = (type(entry.behind) == "number") and entry.behind or nil,
        dirty = (type(entry.dirty) == "number") and entry.dirty or nil,
      }
      items[#items + 1] = item
    end
  end

  return items, nil
end

---Open the winter worktrees picker.
---
--- 1. Discovers the workspace root by walking up from the current buffer's
---    directory (falls back to cwd) looking for `.winter/config.toml` and
---    `tools/winter-cli/`. Notifies and returns if no root is found.
--- 2. Checks that the configured winter CLI and snacks.nvim are available.
--- 3. Runs `winter [global_args] ws worktrees --json` and parses the output.
--- 4. Opens a snacks.nvim fuzzy picker; selecting an item calls switch_to.
---    Press `<c-s>` inside the picker to toggle git-status annotations.
---
---@param cfg Winter.Config plugin configuration
---@param opts? winter.worktrees.OpenOpts per-invocation overrides
function M.open(cfg, opts)
  opts = opts or {}

  -- -------------------------------------------------------------------------
  -- Workspace root discovery
  -- -------------------------------------------------------------------------
  local workspace = require("winter.workspace")

  local buf_name = vim.api.nvim_buf_get_name(0)
  local start_path
  if buf_name ~= "" then
    start_path = vim.fn.fnamemodify(buf_name, ":p:h")
  else
    start_path = vim.fn.getcwd()
  end

  local root = workspace.find_root(start_path)
  if not root then
    vim.notify("winter.nvim: not inside a winter workspace", vim.log.levels.WARN)
    return
  end

  -- -------------------------------------------------------------------------
  -- Dependency checks
  -- -------------------------------------------------------------------------
  if vim.fn.executable(cfg.winter_cmd) == 0 then
    vim.notify(
      ("winter.nvim: winter CLI not found on PATH (looked for %q)"):format(cfg.winter_cmd),
      vim.log.levels.ERROR
    )
    return
  end

  -- NOTE: snacks is checked lazily so the plugin can load without snacks
  -- present (e.g. during unit tests that stub package.loaded["snacks"]).
  local ok_snacks, Snacks = pcall(require, "snacks")
  if not ok_snacks or type(Snacks) ~= "table" or not Snacks.picker then
    vim.notify("winter.nvim: snacks.nvim is required (folke/snacks.nvim)", vim.log.levels.ERROR)
    return
  end

  -- -------------------------------------------------------------------------
  -- Data fetch (initial, no status)
  -- -------------------------------------------------------------------------
  local effective_global_args = opts.winter_args or cfg.winter_args or {}

  local items, fetch_err = M.fetch(root, cfg, effective_global_args, false)
  if not items then
    vim.notify(("winter.nvim: %s"):format(fetch_err), vim.log.levels.ERROR)
    return
  end

  if #items == 0 then
    vim.notify("winter.nvim: no winter repos found", vim.log.levels.WARN)
    return
  end

  -- -------------------------------------------------------------------------
  -- Status-mode toggle state (per-picker)
  -- -------------------------------------------------------------------------
  -- show_status tracks whether the picker is currently showing git-status
  -- annotations. It starts false (fast path). The <c-s> action flips it,
  -- re-fetches with/without --status, and rebuilds the item list.
  local show_status = false

  -- -------------------------------------------------------------------------
  -- Helper: build snacks picker items from WorktreeItem list
  -- -------------------------------------------------------------------------
  ---@param worktree_items winter.WorktreeItem[]
  ---@return snacks.picker.finder.Item[]
  local function make_picker_items(worktree_items)
    local result = {}
    for _, entry in ipairs(worktree_items) do
      result[#result + 1] = {
        text = entry.label,
        -- Carry the full record through so confirm and format can act on it.
        winter_label = entry.label,
        winter_path = entry.path,
        winter_kind = entry.kind,
        winter_ahead = entry.ahead,
        winter_behind = entry.behind,
        winter_dirty = entry.dirty,
      }
    end
    return result
  end

  -- -------------------------------------------------------------------------
  -- Format function: show the label prominently, dim the path as a hint.
  -- When status is loaded (ahead/behind/dirty present), append colored segments.
  --
  -- Highlight group choices:
  --   ahead  (+N, green)   : "DiagnosticOk"         — always available, maps to green
  --   behind (-N, yellow)  : "DiagnosticWarn"        — always available, maps to yellow
  --   dirty  ([+N], red)   : "DiagnosticError"       — always available, maps to red
  --   clean  (=, dim)      : "SnacksPickerDimmed"    — already used for path hint
  -- DiagnosticOk/Warn/Error are standard Neovim groups guaranteed present since
  -- Neovim 0.9. SnacksPickerGitAdded/Modified/Deleted would be more semantic
  -- but may not exist in all snacks versions; Diagnostic* are unconditionally safe.
  -- -------------------------------------------------------------------------
  ---@param item snacks.picker.Item
  ---@param _picker snacks.Picker
  ---@return snacks.picker.Highlight[]
  local function format_item(item, _picker)
    ---@type snacks.picker.Highlight[]
    local ret = {}
    ret[#ret + 1] = { item.winter_label or item.text, "SnacksPickerFile" }

    -- Status annotation segments (only when status has been loaded).
    local ahead = item.winter_ahead
    local behind = item.winter_behind
    local dirty = item.winter_dirty

    if ahead ~= nil or behind ~= nil or dirty ~= nil then
      -- At least one status field present — render annotation.
      local has_any = (ahead and ahead > 0) or (behind and behind > 0) or (dirty and dirty > 0)
      if has_any then
        if ahead and ahead > 0 then
          ret[#ret + 1] = { ("  +%d"):format(ahead), "DiagnosticOk" }
        end
        if behind and behind > 0 then
          ret[#ret + 1] = { ("  -%d"):format(behind), "DiagnosticWarn" }
        end
        if dirty and dirty > 0 then
          ret[#ret + 1] = { ("  [+%d]"):format(dirty), "DiagnosticError" }
        end
      else
        -- Clean: zero ahead, zero behind, zero dirty.
        ret[#ret + 1] = { "  =", "SnacksPickerDimmed" }
      end
    end

    -- Dim path hint (always shown, after status).
    local path_hint = ("  %s"):format(item.winter_path or "")
    ret[#ret + 1] = { path_hint, "SnacksPickerDimmed" }
    return ret
  end

  local session = require("winter.session")

  -- Picker opts are built once; the items list is replaced on toggle.
  local picker_ref = nil

  local picker_opts = {
    title = "Winter Worktrees",
    items = make_picker_items(items),
    format = format_item,
    -- Disable the built-in preview — we have no file to preview.
    preview = "none",
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          session.switch_to(item.winter_path, item.winter_label, {
            use_sessions = cfg.use_sessions,
            create_sessions = cfg.create_sessions,
            session_dir = cfg.session_dir,
            cd_command = cfg.cd_command,
          })
        end)
      end
    end,
    -- <c-s>: toggle git-status annotations. Bound in both insert (i) and normal
    -- (n) modes so it works from the picker input field and the list pane.
    actions = {
      winter_toggle_status = function(picker)
        show_status = not show_status
        -- Re-fetch with or without --status.
        local new_items, ref_err = M.fetch(root, cfg, effective_global_args, show_status)
        if not new_items then
          vim.notify(("winter.nvim: status fetch failed: %s"):format(ref_err), vim.log.levels.WARN)
          show_status = not show_status -- revert
          return
        end
        -- Update picker title to hint at the current mode.
        local new_title = show_status and "Winter Worktrees (status)" or "Winter Worktrees"
        -- Rebuild items and refresh.
        picker.opts.title = new_title
        picker.opts.items = make_picker_items(new_items)
        -- Snacks picker exposes a refresh method; call it to re-render.
        picker:find()
      end,
    },
    win = {
      input = {
        keys = {
          ["<c-s>"] = { "winter_toggle_status", mode = { "i", "n" }, desc = "Toggle git-status annotations" },
        },
      },
    },
  }

  -- Pass through optional user picker config.
  if cfg.picker and cfg.picker.layout then
    picker_opts.layout = cfg.picker.layout
  end

  -- Use Snacks.picker.pick() — the canonical entry point for custom pickers.
  picker_ref = Snacks.picker.pick(picker_opts)
end

return M
