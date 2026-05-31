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
--- This costs an extra `winter ws worktrees --json --status` call (~1s), but
--- it runs asynchronously via a native snacks finder so the picker stays
--- interactive (with a loading indicator) while the status fetch is in flight.
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

---Parse the JSON stdout of `winter ws worktrees --json [--status]` into a
---WorktreeItem list.
---
--- Pure and synchronously testable: no CLI, no UI, no side effects. The async
--- fetch path and any future sync caller share this helper so JSON shape
--- handling lives in exactly one place.
---
---@param stdout string raw CLI stdout
---@return winter.WorktreeItem[]|nil items, string|nil err
function M.parse_items(stdout)
  stdout = vim.trim(stdout or "")
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

---Asynchronously fetch and parse worktree items from the winter CLI.
---
--- Delegates the CLI round-trip to the non-blocking `cli.run_async`, then parses
--- the raw stdout with the pure `parse_items` helper. `on_done` receives
--- `(items, nil)` on success or `(nil, err)` on CLI / parse failure. It runs in
--- the libuv context where `vim.system` fires `on_exit`; callers doing UI work
--- must wrap it in `vim.schedule()`.
---
--- The optional callback-style `runner` is forwarded to `cli.run_async` for
--- tests (see its docstring).
---
---@param root string workspace root
---@param cfg Winter.Config plugin configuration
---@param effective_global_args string[] global args (possibly overridden per-invocation)
---@param show_status boolean whether to request status fields
---@param on_done fun(items: winter.WorktreeItem[]|nil, err: string|nil)
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: {code: integer, stdout: string, stderr: string}))
function M.fetch_async(root, cfg, effective_global_args, show_status, on_done, runner)
  local cli = require("winter.cli")
  local subcommand_args = M.build_subcommand(show_status)

  cli.run_async(root, cfg, effective_global_args, subcommand_args, function(result, err)
    if not result then
      on_done(nil, err)
      return
    end
    local items, parse_err = M.parse_items(result.stdout)
    on_done(items, parse_err)
  end, runner)
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

  local effective_global_args = opts.winter_args or cfg.winter_args or {}

  -- -------------------------------------------------------------------------
  -- Status-mode toggle state (per-picker)
  -- -------------------------------------------------------------------------
  -- show_status tracks whether the picker is currently showing git-status
  -- annotations. It starts false (fast path). The <c-s> action flips it and
  -- re-runs the finder; the finder reads show_status at run time, so the same
  -- finder serves both modes.
  local show_status = false

  -- -------------------------------------------------------------------------
  -- Helper: build a single snacks picker item from a WorktreeItem
  -- -------------------------------------------------------------------------
  ---@param entry winter.WorktreeItem
  ---@return snacks.picker.finder.Item
  local function make_picker_item(entry)
    return {
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

  -- -------------------------------------------------------------------------
  -- Columnar formatting: label · status, laid out as two columns so rows line
  -- up like a table. The label is padded to the widest label (computed per fetch
  -- by the finder and held in this upvalue) so the status indicators all start
  -- at the same x instead of trailing each variable-length label. The absolute
  -- path is intentionally not shown — the label already identifies the worktree,
  -- and the path is just noise.
  -- -------------------------------------------------------------------------
  local max_label_width = 0

  ---Pad `text` with trailing spaces to `width` display columns (no-op if wider).
  ---@param text string
  ---@param width integer
  ---@return string
  local function pad_right(text, width)
    local tw = vim.api.nvim_strwidth(text)
    return tw < width and (text .. (" "):rep(width - tw)) or text
  end

  -- Build the colored git-status segments for one item. Returns {} when status
  -- has not been loaded (the fast, no-`--status` mode).
  --
  -- Highlight groups: ahead "+N" → DiagnosticOk (green), behind "-N" →
  -- DiagnosticWarn (yellow), dirty "[+N]" → DiagnosticError (red), clean "=" →
  -- SnacksPickerDimmed. Diagnostic* are standard since Neovim 0.9 so they are
  -- unconditionally safe (SnacksPickerGit* would be more semantic but may be
  -- absent in some snacks versions).
  ---@param ahead integer|nil
  ---@param behind integer|nil
  ---@param dirty integer|nil
  ---@return snacks.picker.Highlight[] segments
  local function status_segments(ahead, behind, dirty)
    if ahead == nil and behind == nil and dirty == nil then
      return {}
    end
    local parts = {} ---@type snacks.picker.Highlight[]
    if (ahead and ahead > 0) or (behind and behind > 0) or (dirty and dirty > 0) then
      if ahead and ahead > 0 then
        parts[#parts + 1] = { ("+%d"):format(ahead), "DiagnosticOk" }
      end
      if behind and behind > 0 then
        parts[#parts + 1] = { ("-%d"):format(behind), "DiagnosticWarn" }
      end
      if dirty and dirty > 0 then
        parts[#parts + 1] = { ("[+%d]"):format(dirty), "DiagnosticError" }
      end
    else
      parts[#parts + 1] = { "=", "SnacksPickerDimmed" }
    end
    -- Join parts with single spaces.
    local segments = {} ---@type snacks.picker.Highlight[]
    for i, part in ipairs(parts) do
      if i > 1 then
        segments[#segments + 1] = { " " }
      end
      segments[#segments + 1] = part
    end
    return segments
  end

  ---@param item snacks.picker.Item
  ---@param _picker snacks.Picker
  ---@return snacks.picker.Highlight[]
  local function format_item(item, _picker)
    ---@type snacks.picker.Highlight[]
    local ret = {}

    local segments = status_segments(item.winter_ahead, item.winter_behind, item.winter_dirty)

    -- Column 1: label. Pad to the widest label only when a status column
    -- follows, so the status indicators align; otherwise show the bare label.
    local label = item.winter_label or item.text or ""
    ret[#ret + 1] = { #segments > 0 and pad_right(label, max_label_width) or label, "SnacksPickerFile" }

    -- Column 2: git-status indicators (only present once status is loaded).
    if #segments > 0 then
      ret[#ret + 1] = { "  " }
      for _, seg in ipairs(segments) do
        ret[#ret + 1] = seg
      end
    end

    return ret
  end

  local session = require("winter.session")

  -- -------------------------------------------------------------------------
  -- Native async snacks finder
  -- -------------------------------------------------------------------------
  -- Instead of a static `items` array, the picker is driven by a finder
  -- function that runs the winter CLI off the UI thread and feeds items to the
  -- picker via snacks' callback contract. The picker window opens immediately
  -- with a loading indicator and populates when the CLI returns — the editor is
  -- never frozen.
  --
  -- The finder runs inside a snacks coroutine (`ctx.async`). We launch the CLI
  -- via the callback-based `fetch_async`, then suspend the coroutine until the
  -- CLI's `on_exit` resumes it. Delegating to snacks gives us three behaviours
  -- for free, rather than reimplementing them:
  --   * cancellation when the picker closes (snacks aborts the coroutine at the
  --     suspend point, so nothing below runs — no operations on a closed picker);
  --   * stale-result suppression on re-run: the <c-s> toggle calls
  --     `picker:find()`, which aborts any in-flight finder before starting a new
  --     one, so a rapid double <c-s> cannot render an out-of-date result.
  --
  -- For loading feedback, snacks renders a spinner + count in the input line
  -- while the finder is active. We additionally surface a "— loading…" suffix in
  -- the picker title (see set_title), since the `--status` re-fetch does ~1s of
  -- git work and the input-line spinner alone is easy to miss.

  -- Set the picker's displayed title. snacks renders `picker.title` (captured
  -- once at construction), NOT `picker.opts.title`, so we mutate that field and
  -- call update_titles(). Touches windows, so callers schedule onto the main loop.
  ---@param picker snacks.Picker
  ---@param status boolean whether status-mode is active
  ---@param loading boolean whether a CLI fetch is in flight
  local function set_title(picker, status, loading)
    if picker.closed then
      return
    end
    local base = status and "Winter Worktrees (status)" or "Winter Worktrees"
    picker.title = loading and (base .. " — loading…") or base
    picker:update_titles()
  end

  ---@param _finder_opts snacks.picker.Config
  ---@param ctx snacks.picker.finder.ctx
  local function finder(_finder_opts, ctx)
    -- Read the toggle state at run time so the same finder serves both modes.
    local current_status = show_status
    ---@param cb async fun(item: snacks.picker.finder.Item)
    return function(cb)
      -- Announce the in-flight fetch in the title. snacks defers all window
      -- rendering off the finder coroutine, so schedule onto the main loop.
      vim.schedule(function()
        set_title(ctx.picker, current_status, true)
      end)

      local fetched, fetch_err
      M.fetch_async(root, cfg, effective_global_args, current_status, function(items, err)
        fetched, fetch_err = items, err
        -- on_exit fires in a libuv fast-event context; hop to the main loop
        -- before resuming the snacks coroutine.
        vim.schedule(function()
          ctx.async:resume()
        end)
      end)
      -- Suspend until the CLI callback resumes us. If the picker closes or
      -- re-runs the finder while the fetch is in flight, snacks aborts this
      -- coroutine here and the code below never executes (so the title is left
      -- for the new finder / close path to manage).
      ctx.async:suspend()

      -- Fetch complete: clear the loading suffix from the title.
      vim.schedule(function()
        set_title(ctx.picker, current_status, false)
      end)

      if fetch_err then
        vim.schedule(function()
          vim.notify(("winter.nvim: %s"):format(fetch_err), vim.log.levels.ERROR)
        end)
        return
      end
      if not fetched or #fetched == 0 then
        vim.schedule(function()
          vim.notify("winter.nvim: no winter repos found", vim.log.levels.WARN)
        end)
        return
      end
      -- Size the label column from the full result set before feeding items, so
      -- format_item (which reads this upvalue at render time) can pad to it and
      -- the status indicators line up.
      max_label_width = 0
      for _, entry in ipairs(fetched) do
        max_label_width = math.max(max_label_width, vim.api.nvim_strwidth(entry.label or ""))
      end

      for _, entry in ipairs(fetched) do
        cb(make_picker_item(entry))
      end
    end
  end

  local picker_opts = {
    title = "Winter Worktrees",
    finder = finder,
    format = format_item,
    -- Disable the built-in preview — we have no file to preview.
    preview = "none",
    -- Show the picker window immediately rather than waiting for results.
    -- snacks defaults `show_delay` to 5000ms: while a finder is running with no
    -- results yet, it withholds the window for up to that long — which, with our
    -- async CLI finder, means the picker would not appear until the CLI returns
    -- (~1s), defeating the point of the async refactor. With 0 the window opens
    -- right away in a loading state and fills in when the finder yields items.
    show_delay = 0,
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
        -- Re-run the finder with the new mode. The finder reads show_status,
        -- drives the title (loading suffix + mode), and snacks aborts any
        -- in-flight fetch first so a rapid double <c-s> can't render a stale result.
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
  Snacks.picker.pick(picker_opts)
end

return M
