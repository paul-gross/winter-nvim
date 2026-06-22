---@mod winter.dashboard Persistent toggle-able workspace status dashboard
---@brief [[
--- Renders a live workspace status dashboard in a persistent `nofile` buffer
--- named `winter://dashboard`. The buffer is hidden when not visible (never
--- wiped) and reused across toggle invocations. A `vim.uv` repeating timer
--- drives periodic background refresh so the display stays current without
--- blocking the editor.
---
--- Entry point: `M.open(cfg, opts?, runner?)` — toggle open/close.
--- Public refresh: `M.refresh(cfg, opts?, runner?)` — re-fetch on demand.
--- Pure helper: `M.parse_status(json_string)` — decode/normalise status JSON.
--- Pure helper: `M.build_grid(status)` — render lines, cells, highlights.
---
---   :WinterDashboard     toggle the dashboard window
---   :WinterRefresh       refresh the dashboard (no-op if not open)
---   :Winter dashboard    same as :WinterDashboard (via the :Winter umbrella)
---   :Winter refresh      same as :WinterRefresh   (via the :Winter umbrella)
---
--- User autocmd events fired by this module:
---
---   WinterDashboardOpened
---     Fired when the dashboard window is shown (toggled open / first open).
---     data = { buf }   — `buf` is the dashboard buffer number.
---
---   WinterDashboardRefreshed
---     Fired after each async refresh has finished rendering new content.
---     data = { buf }   — `buf` is the dashboard buffer number.
---
---   WinterDashboardSelectionChanged
---     Fired when the virtual selection moves to a new cell.
---     Only fires when the selection actually changes (not on every redraw).
---     data = { buf, selection = { kind, env, repo, row, col } }
---
--- Example: bind buffer-local keys without the plugin imposing any.
---   vim.api.nvim_create_autocmd("User", {
---     pattern = "WinterDashboard*",
---     callback = function(ev)
---       local data = ev.data
---       -- data.buf is always set; data.selection only for SelectionChanged.
---     end,
---   })
---@brief ]]

local cli = require("winter.cli")
local workspace = require("winter.workspace")

local M = {}

-- ---------------------------------------------------------------------------
-- Module-level persistent state
-- ---------------------------------------------------------------------------

-- The buffer number is kept at MODULE level (not buffer-local) so toggle
-- calls can always find and reuse the same buffer across hide/show.
local _bufnr = nil

-- The vim.uv timer handle (non-nil while the dashboard is visible).
local _timer = nil

-- Guard against overlapping in-flight fetches: when a fetch is already in
-- flight we skip the next timer tick rather than stacking another request.
local _fetch_in_flight = false

-- Module-level cfg + opts snapshot used by the timer callback (set on open).
local _cfg = nil
local _opts = nil
local _runner = nil

-- Last successfully parsed status table, stored so dashboard quick-diff can
-- reuse it without a redundant CLI round-trip.
local _last_status = nil

-- Refresh interval in milliseconds (30 s, mirroring the TUI's poll rate).
local REFRESH_INTERVAL_MS = 30000

-- Autocmd id for the WinClosed guard (non-nil while a dashboard window is open).
-- Cleared when the window closes or when the timer is stopped via toggle/q.
local _winclosed_autocmd_id = nil

-- Stable buffer name used to identify the dashboard across sessions.
local BUF_NAME = "winter://dashboard"

-- Extmark namespace for content highlights (created once, reused across renders).
local _ns = nil

-- Extmark namespace for the selection highlight (separate so clearing the
-- selection never touches the content highlights, and vice versa).
local _sel_ns = nil

-- Module-level cell table so Phase 5 (navigation) can read it.
-- Each entry: { row, col_start, col_end, kind, env, repo }
local _cells = {}

-- Per-buffer selection state keyed by bufnr: { row=<1-based>, col=<1-based> }
-- (1-based indices into the nav grid, matching nav_grid.grid[r][c]).
-- MVP: navigation covers ONLY the worktree matrix cells (kind=="worktree").
-- Standalone/source rows do not participate — they are not part of the
-- env × repo matrix and adding them would require a separate linear model.
local _selections = {}

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

---Set up winter dashboard highlight groups (idempotent via `default = true`).
--- Called once before the first render; subsequent calls are no-ops because
--- `default = true` only applies the link when no existing highlight is set.
function M.setup_highlights()
  -- Green — commits ahead of upstream
  vim.api.nvim_set_hl(0, "WinterDashAhead", { link = "DiffAdd", default = true })
  -- Yellow — commits behind upstream
  vim.api.nvim_set_hl(0, "WinterDashBehind", { link = "WarningMsg", default = true })
  -- Red — dirty (uncommitted changes)
  vim.api.nvim_set_hl(0, "WinterDashDirty", { link = "ErrorMsg", default = true })
  -- Cyan — tracking branch diverged from remote feature branch
  vim.api.nvim_set_hl(0, "WinterDashDiverged", { link = "DiagnosticInfo", default = true })
  -- Orange-ish — unborn upstream (no remote tracking ref yet, but local commits)
  vim.api.nvim_set_hl(0, "WinterDashUnborn", { link = "DiagnosticHint", default = true })
  -- Cyan — extension badges
  vim.api.nvim_set_hl(0, "WinterDashBadge", { link = "Special", default = true })
  -- Title — section and column headers
  vim.api.nvim_set_hl(0, "WinterDashHeader", { link = "Title", default = true })
  -- Dim — clean repos, placeholder dots
  vim.api.nvim_set_hl(0, "WinterDashClean", { link = "Comment", default = true })
  -- Selection highlight (dedicated namespace; links to Visual by default)
  vim.api.nvim_set_hl(0, "WinterDashSelection", { link = "Visual", default = true })
end

---Return the current cell-coordinate table produced by the last render.
--- Phase 5 (cell navigation) reads this to map cursor position to env/repo.
---@return Winter.DashCell[]
function M.get_cells()
  return _cells
end

---Return whether the refresh timer is currently active (non-nil and running).
--- Exposed for headless test probes; not part of the public API.
---@return boolean
function M._timer_active()
  return _timer ~= nil
end

---Return whether the WinClosed guard autocmd is currently armed.
--- Exposed for headless test probes; not part of the public API.
---@return boolean
function M._winclosed_guard_active()
  return _winclosed_autocmd_id ~= nil
end

-- ---------------------------------------------------------------------------
-- Navigation helpers — PURE (no vim.api calls, fully unit-testable)
-- ---------------------------------------------------------------------------

---@class Winter.NavGrid
---@field grid table<integer, table<integer, Winter.DashCell>>  grid[row][col] = cell (1-based)
---@field n_rows integer
---@field n_cols integer
---@field index table  cellid (tostring of col_start..":"..row) -> {row,col} 1-based

---Build a logical 2-D navigation grid from the flat cells table.
--- Only cells with kind=="worktree" are included in the navigable matrix.
--- The column index is the env ordinal (order of first appearance) and the
--- row index is the repo ordinal (order of first appearance) — matching the
--- visual repos-as-rows layout produced by build_grid.
---
--- MVP: standalone/source-checkout rows do NOT participate in navigation.
--- They are not part of the env × repo matrix; adding them would require a
--- separate linear model with different wrap semantics. A comment here
--- documents the omission so Phase 6 can address it if desired.
---
---@param cells Winter.DashCell[]
---@return Winter.NavGrid
function M.build_nav_grid(cells)
  -- Collect unique env and repo names in first-appearance order.
  local env_order = {}
  local env_idx = {}
  local repo_order = {}
  local repo_idx = {}

  for _, cell in ipairs(cells) do
    if cell.kind == "worktree" then
      local env = cell.env or "?"
      local repo = cell.repo or "?"
      if not env_idx[env] then
        env_order[#env_order + 1] = env
        env_idx[env] = #env_order
      end
      if not repo_idx[repo] then
        repo_order[#repo_order + 1] = repo
        repo_idx[repo] = #repo_order
      end
    end
  end

  local n_cols = #env_order
  local n_rows = #repo_order

  -- Populate grid[row][col] = cell.
  local grid = {}
  for r = 1, n_rows do
    grid[r] = {}
  end

  local index = {}
  for _, cell in ipairs(cells) do
    if cell.kind == "worktree" then
      local env = cell.env or "?"
      local repo = cell.repo or "?"
      local r = repo_idx[repo]
      local c = env_idx[env]
      if r and c then
        grid[r][c] = cell
        -- key: unique per cell (env+repo combination)
        index[env .. "\0" .. repo] = { row = r, col = c }
      end
    end
  end

  return {
    grid = grid,
    n_rows = n_rows,
    n_cols = n_cols,
    index = index,
  }
end

---Compute the next selection position after moving in direction `dir`,
--- clamping at grid edges (no wrap).
---
--- `nav`  — result of `build_nav_grid`
--- `sel`  — current selection `{ row, col }` (1-based)
--- `dir`  — one of "h"|"j"|"k"|"l"|"left"|"right"|"up"|"down"
---
---@param nav Winter.NavGrid
---@param sel { row: integer, col: integer }
---@param dir string
---@return { row: integer, col: integer }
function M.nav_step(nav, sel, dir)
  if nav.n_rows == 0 or nav.n_cols == 0 then
    return sel
  end

  local r, c = sel.row, sel.col

  if dir == "h" or dir == "left" then
    c = math.max(1, c - 1)
  elseif dir == "l" or dir == "right" then
    c = math.min(nav.n_cols, c + 1)
  elseif dir == "k" or dir == "up" then
    r = math.max(1, r - 1)
  elseif dir == "j" or dir == "down" then
    r = math.min(nav.n_rows, r + 1)
  end

  return { row = r, col = c }
end

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-testable, no UI)
-- ---------------------------------------------------------------------------

---Decode and normalise `winter ws status --json` output.
---
--- Returns the decoded top-level table on success, or nil + an error string
--- on empty / unparseable input.
---
---@param json_string string raw CLI stdout
---@return table|nil status, string|nil err
function M.parse_status(json_string)
  json_string = vim.trim(json_string or "")
  if json_string == "" then
    return nil, "winter CLI returned empty output"
  end

  local ok, decoded = pcall(vim.json.decode, json_string)
  if not ok then
    return nil, ("failed to parse winter CLI JSON: %s"):format(tostring(decoded))
  end

  if type(decoded) ~= "table" then
    return nil, "winter CLI JSON is not an object"
  end

  return decoded, nil
end

-- ---------------------------------------------------------------------------
-- Grid renderer — pure (no vim.api calls except in the caller)
-- ---------------------------------------------------------------------------

---@class Winter.DashCell
---@field row integer   0-based buffer line
---@field col_start integer byte offset (0-based)
---@field col_end integer   byte offset (exclusive)
---@field kind string   "env"|"repo"|"worktree"|"standalone"
---@field env string|nil
---@field repo string|nil

---@class Winter.DashHl
---@field row integer    0-based buffer line
---@field col_start integer byte offset
---@field col_end integer   byte offset (exclusive)
---@field hl_group string

---@class Winter.DashGrid
---@field lines string[]
---@field cells Winter.DashCell[]
---@field highlights Winter.DashHl[]

-- Render a single worktree cell status string and collect highlight spans.
-- Returns: text, list of {col_offset, len, hl_group} relative to the start
-- of the cell text.
--
-- Rules (mirror the Textual TUI `render_repo_cell`, in order):
--   ahead > 0               → "+N"         [WinterDashAhead  / green]
--   behind > 0              → "-N"         [WinterDashBehind / yellow]
--   dirty == 1              → "1 file"     [WinterDashDirty  / red]
--   dirty > 1               → "N files"    [WinterDashDirty  / red]
--   tracking divergence     → " [+A,-B]"   [WinterDashDiverged / cyan]
--     (only nonzero components shown; only when ta>0 or tb>0,
--      AND tracking_differs_from_main)
--   unborn upstream         → " [+]"       [WinterDashUnborn / orange]
--     (when tracking_ref_present==false and ahead>0, and no divergence marker,
--      AND tracking_differs_from_main)
--   nothing applies (clean) → "·"          [WinterDashClean  / dim]
--
-- `tracking_differs_from_main`: the cyan/orange markers are only meaningful
-- when the upstream ref differs from origin/<main_branch> — otherwise the
-- ahead/behind counts above already describe the same fact. When main_branch
-- is absent (older CLI), we fall back to showing the markers (safe degradation).
local function render_worktree_cell(wt)
  local ahead = wt.ahead or 0
  local behind = wt.behind or 0
  local dirty = wt.dirty or 0
  local ta = wt.tracking_ahead or 0
  local tb = wt.tracking_behind or 0
  local trp = wt.tracking_ref_present
  if trp == nil then
    trp = true
  end

  -- Gate cyan/orange on tracking_differs_from_main (mirrors TUI logic).
  -- When main_branch is absent (older CLI), treat as differs=true so the
  -- markers still show (safe degradation to old behaviour).
  local tracking_differs_from_main
  if wt.main_branch ~= nil and wt.upstream ~= nil then
    tracking_differs_from_main = wt.upstream ~= ("origin/" .. tostring(wt.main_branch))
  else
    tracking_differs_from_main = true
  end

  local parts = {} -- { text, hl_group }
  local nothing = true

  if ahead > 0 then
    parts[#parts + 1] = { ("+" .. ahead), "WinterDashAhead" }
    nothing = false
  end
  if behind > 0 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { ("-" .. behind), "WinterDashBehind" }
    nothing = false
  end
  if dirty == 1 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { "1 file", "WinterDashDirty" }
    nothing = false
  elseif dirty > 1 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { (dirty .. " files"), "WinterDashDirty" }
    nothing = false
  end

  -- Tracking divergence: append [+A,-B] (only nonzero components).
  -- Only shown when the upstream differs from origin/<main_branch>.
  if tracking_differs_from_main and (ta > 0 or tb > 0) then
    local div_parts = {}
    if ta > 0 then
      div_parts[#div_parts + 1] = ("+" .. ta)
    end
    if tb > 0 then
      div_parts[#div_parts + 1] = ("-" .. tb)
    end
    local div_text = " [" .. table.concat(div_parts, ",") .. "]"
    parts[#parts + 1] = { div_text, "WinterDashDiverged" }
    nothing = false
  elseif tracking_differs_from_main and not trp and ahead > 0 then
    -- Unborn upstream: no remote tracking ref but local commits exist.
    parts[#parts + 1] = { " [+]", "WinterDashUnborn" }
    nothing = false
  end

  if nothing then
    local dot = "·"
    return dot, { { 0, #dot, "WinterDashClean" } }
  end

  -- Assemble text and compute byte offsets for highlights.
  local text = ""
  local spans = {} -- { col_start, col_end, hl_group }
  for _, part in ipairs(parts) do
    local start = #text -- byte offset before this part
    text = text .. part[1]
    local finish = #text
    if part[2] then
      spans[#spans + 1] = { start, finish, part[2] }
    end
  end

  return text, spans
end

-- Render a source-checkout status cell and collect spans.
local function render_source_cell(sc)
  local behind = sc.behind_origin or 0
  local ahead = sc.ahead_origin or 0
  local dirty = sc.dirty or 0

  local parts = {}
  local nothing = true

  if ahead > 0 then
    parts[#parts + 1] = { ("+" .. ahead), "WinterDashAhead" }
    nothing = false
  end
  if behind > 0 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { ("-" .. behind), "WinterDashBehind" }
    nothing = false
  end
  if dirty == 1 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { "1 file", "WinterDashDirty" }
    nothing = false
  elseif dirty > 1 then
    if #parts > 0 then
      parts[#parts + 1] = { " ", nil }
    end
    parts[#parts + 1] = { (dirty .. " files"), "WinterDashDirty" }
    nothing = false
  end

  if nothing then
    local dot = "·"
    return dot, { { 0, #dot, "WinterDashClean" } }
  end

  local text = ""
  local spans = {}
  for _, part in ipairs(parts) do
    local start = #text
    text = text .. part[1]
    local finish = #text
    if part[2] then
      spans[#spans + 1] = { start, finish, part[2] }
    end
  end

  return text, spans
end

---Build display lines, cell-coordinate table, and highlight spans from a
--- decoded status table.
---
--- Returns a `Winter.DashGrid` with:
---   `.lines`      flat list of strings (for `nvim_buf_set_lines`)
---   `.cells`      list of `Winter.DashCell` (byte ranges, for Phase 5 nav)
---   `.highlights` list of `Winter.DashHl`  (for extmarks)
---
--- This function is PURE — no `vim.api` calls. It is the unit-test surface.
---
--- Layout: `status.dashboard.resolved_layout` controls orientation.
---   "repos-as-rows" (default): col 0 = repo label, one column per env.
---   Other values fall back to repos-as-rows with a comment logged in the
---   output — no crash.
---
---@param status table decoded ws status document
---@return Winter.DashGrid
function M.build_grid(status)
  local lines = {}
  local cells = {} ---@type Winter.DashCell[]
  local highlights = {} ---@type Winter.DashHl[]

  local function add_line(s)
    lines[#lines + 1] = s
  end

  local function add_hl(row, col_start, col_end, hl_group)
    if col_start < col_end then
      highlights[#highlights + 1] = {
        row = row,
        col_start = col_start,
        col_end = col_end,
        hl_group = hl_group,
      }
    end
  end

  local function add_cell(row, col_start, col_end, kind, env_name, repo_name)
    cells[#cells + 1] = {
      row = row,
      col_start = col_start,
      col_end = col_end,
      kind = kind,
      env = env_name,
      repo = repo_name,
    }
  end

  local envs = status.environments or {}
  local source_checkouts = status.source_checkouts or {}

  -- -------------------------------------------------------------------------
  -- Determine resolved layout
  -- -------------------------------------------------------------------------
  local resolved_layout = (status.dashboard and status.dashboard.resolved_layout) or "repos-as-rows"
  -- MVP: only repos-as-rows is fully rendered. Other layouts fall back with
  -- a visible note (avoids silent degradation).
  local layout_fallback = false
  if resolved_layout ~= "repos-as-rows" then
    layout_fallback = true
    -- resolved_layout is preserved for display in the fallback note.
  end

  -- -------------------------------------------------------------------------
  -- Section 1: env × repo matrix
  -- -------------------------------------------------------------------------

  if #envs == 0 then
    add_line("Winter Dashboard")
    local row0 = #lines - 1
    add_hl(row0, 0, #lines[row0 + 1], "WinterDashHeader")
    add_line("")
    add_line("(no environments)")
  else
    -- Build the union of all repos across all envs (ordered by first appearance).
    local repo_order = {}
    local repo_set = {}
    for _, env in ipairs(envs) do
      for _, wt in ipairs(env.worktrees or {}) do
        local repo = wt.repo or "?"
        if not repo_set[repo] then
          repo_set[repo] = true
          repo_order[#repo_order + 1] = repo
        end
      end
    end

    -- Build lookup: env_name → { repo → worktree }
    local env_map = {}
    for _, env in ipairs(envs) do
      local m = {}
      for _, wt in ipairs(env.worktrees or {}) do
        m[wt.repo or "?"] = wt
      end
      env_map[env.name or "?"] = m
    end

    -- Compute column widths (geometry-agnostic; size to content).
    -- Repo label column width: longest repo name + pin glyph room.
    -- Pin glyph: we use ">" for pinned (ASCII-safe); unpinned uses " ".
    local PIN_GLYPH = ">"
    local PIN_PAD = " " -- same byte width, for alignment

    -- Minimum repo-label column width: 40, matching the TUI's
    -- `f"{'Repositories':<40}"` header floor (feature_worktrees.py) so the
    -- Neovim grid lines up with the Textual dashboard. Grows past 40 to fit
    -- any longer repo label.
    local repo_col_w = 40 -- minimum (TUI parity)
    for _, repo in ipairs(repo_order) do
      local w = #repo + 2 -- 2 = pin glyph + space
      if w > repo_col_w then
        repo_col_w = w
      end
    end

    -- Env column width: size to the wider of the header or any cell content.
    -- Pre-compute cell texts so we can measure them.
    local env_cell_texts = {} -- env_name → { repo → text }
    for _, env in ipairs(envs) do
      local ename = env.name or "?"
      env_cell_texts[ename] = {}
      for _, repo in ipairs(repo_order) do
        local wt = env_map[ename] and env_map[ename][repo]
        if wt then
          local txt, _ = render_worktree_cell(wt)
          env_cell_texts[ename][repo] = txt
        else
          env_cell_texts[ename][repo] = "--"
        end
      end
    end

    -- Header: env name (title-cased) + badges + feature branch
    -- Col header width = max(env_name_+_badges, cell_text_widths)
    local env_col_w = {} -- env_name → integer
    for _, env in ipairs(envs) do
      local ename = env.name or "?"
      local badges = {}
      if type(env.extensions) == "table" then
        for _, v in pairs(env.extensions) do
          badges[#badges + 1] = v
        end
      end
      local badge_str = #badges > 0 and (" " .. table.concat(badges, " ")) or ""
      local header_text = ename:sub(1, 1):upper() .. ename:sub(2) .. badge_str
      local w = #header_text
      -- Also check cell content widths.
      for _, repo in ipairs(repo_order) do
        local ct = env_cell_texts[ename][repo] or "--"
        if #ct > w then
          w = #ct
        end
      end
      -- Minimum env column width: 12, matching the TUI's `{title:<12}`
      -- column-header floor (feature_worktrees.py) for visual parity.
      if w < 12 then
        w = 12
      end
      env_col_w[ename] = w
    end

    -- Separator character.
    local SEP = "  " -- two spaces between columns

    -- Build header lines.
    -- Line 1: col labels (env names + badges).
    -- Line 2: feature branch for each env.
    local header1 = string.rep(" ", repo_col_w) .. SEP
    local header2 = string.rep(" ", repo_col_w) .. SEP
    local env_col_starts = {} -- env_name → byte start within the line
    local cur = repo_col_w + #SEP
    for i, env in ipairs(envs) do
      local ename = env.name or "?"
      local badges = {}
      if type(env.extensions) == "table" then
        -- Sort badge values for determinism.
        local bkeys = {}
        for k, _ in pairs(env.extensions) do
          bkeys[#bkeys + 1] = k
        end
        table.sort(bkeys)
        for _, k in ipairs(bkeys) do
          badges[#badges + 1] = env.extensions[k]
        end
      end
      local badge_str = #badges > 0 and (" " .. table.concat(badges, " ")) or ""
      local env_display = ename:sub(1, 1):upper() .. ename:sub(2)
      local header_text = env_display .. badge_str

      local w = env_col_w[ename]
      -- Pad the header text to column width.
      local padded = header_text .. string.rep(" ", w - #header_text)
      env_col_starts[ename] = cur
      header1 = header1 .. padded
      if i < #envs then
        header1 = header1 .. SEP
      end

      local fb = (env.feature_branch or "?")
      local fb_padded = fb .. string.rep(" ", w - #fb)
      header2 = header2 .. fb_padded
      if i < #envs then
        header2 = header2 .. SEP
      end

      cur = cur + w + (i < #envs and #SEP or 0)
    end

    -- Layout fallback note (if applicable).
    if layout_fallback then
      add_line(("-- layout '%s' not yet supported; rendering repos-as-rows --"):format(resolved_layout))
    end

    -- Emit header lines.
    add_line(header1)
    local h1_row = #lines - 1
    -- Highlight each env name span in the header.
    for _, env in ipairs(envs) do
      local ename = env.name or "?"
      local cs = env_col_starts[ename]
      local env_display = ename:sub(1, 1):upper() .. ename:sub(2)
      -- Highlight env name portion (before badge).
      add_hl(h1_row, cs, cs + #env_display, "WinterDashHeader")
      -- Highlight badge portion if any.
      local badges = {}
      if type(env.extensions) == "table" then
        local bkeys = {}
        for k, _ in pairs(env.extensions) do
          bkeys[#bkeys + 1] = k
        end
        table.sort(bkeys)
        for _, k in ipairs(bkeys) do
          badges[#badges + 1] = env.extensions[k]
        end
      end
      if #badges > 0 then
        local badge_str = " " .. table.concat(badges, " ")
        add_hl(h1_row, cs + #env_display, cs + #env_display + #badge_str, "WinterDashBadge")
      end
      -- Record env header cell for navigation.
      add_cell(h1_row, cs, cs + env_col_w[ename], "env", ename, nil)
    end

    add_line(header2)
    -- (feature branch line: no special highlight needed)

    add_line(string.rep("─", #header1))
    local sep_row = #lines - 1
    add_hl(sep_row, 0, #lines[sep_row + 1], "WinterDashClean")

    -- Repo rows.
    for _, repo in ipairs(repo_order) do
      -- Determine whether any env marks this repo as pinned.
      local is_pinned = false
      for _, env in ipairs(envs) do
        local ename = env.name or "?"
        local wt = env_map[ename] and env_map[ename][repo]
        if wt and wt.pinned then
          is_pinned = true
          break
        end
      end

      local pin = is_pinned and (PIN_GLYPH .. " ") or (PIN_PAD .. " ")
      local label = pin .. repo
      -- Pad label to repo_col_w.
      local row_prefix = label .. string.rep(" ", repo_col_w - #label)
      local row_line = row_prefix .. SEP

      local col_cursor = repo_col_w + #SEP

      local row_cells = {} -- collect cell info before emitting
      local row_spans = {} -- { col_start, col_end, hl_group }

      -- Repo label cell.
      local repo_cell_start = 0
      local repo_cell_end = #row_prefix

      for i, env in ipairs(envs) do
        local ename = env.name or "?"
        local wt = env_map[ename] and env_map[ename][repo]
        local cell_text, spans
        if wt then
          cell_text, spans = render_worktree_cell(wt)
        else
          cell_text = "--"
          spans = {}
        end

        local w = env_col_w[ename]
        local cell_col_start = col_cursor

        -- Record worktree cell for navigation.
        row_cells[#row_cells + 1] = {
          col_start = cell_col_start,
          col_end = cell_col_start + w,
          kind = "worktree",
          env = ename,
          repo = repo,
        }

        -- Translate cell-local spans to line-absolute offsets.
        for _, sp in ipairs(spans) do
          row_spans[#row_spans + 1] = {
            cell_col_start + sp[1],
            cell_col_start + sp[2],
            sp[3],
          }
        end

        local padded = cell_text .. string.rep(" ", w - #cell_text)
        row_line = row_line .. padded
        if i < #envs then
          row_line = row_line .. SEP
          col_cursor = col_cursor + w + #SEP
        else
          col_cursor = col_cursor + w
        end
      end

      add_line(row_line)
      local this_row = #lines - 1

      -- Emit repo label cell.
      add_cell(this_row, repo_cell_start, repo_cell_end, "repo", nil, repo)
      -- Highlight pin glyph for pinned repos.
      if is_pinned then
        add_hl(this_row, 0, #pin, "WinterDashBadge")
      end

      -- Emit worktree cells and their highlights.
      for _, rc in ipairs(row_cells) do
        add_cell(this_row, rc.col_start, rc.col_end, rc.kind, rc.env, rc.repo)
      end
      for _, sp in ipairs(row_spans) do
        add_hl(this_row, sp[1], sp[2], sp[3])
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Section 2: standalone / source-checkout table
  -- -------------------------------------------------------------------------

  add_line("")
  add_line("Standalone / Source Checkouts")
  local sc_header_row = #lines - 1
  add_hl(sc_header_row, 0, #lines[sc_header_row + 1], "WinterDashHeader")
  local sc_sep = string.rep("─", 40)
  add_line(sc_sep)
  add_hl(#lines - 1, 0, #sc_sep, "WinterDashClean")

  if #source_checkouts == 0 then
    add_line("(none)")
  else
    -- Compute repo label width for alignment.
    local sc_label_w = 4
    for _, sc in ipairs(source_checkouts) do
      local w = #(sc.repo or "?")
      if w > sc_label_w then
        sc_label_w = w
      end
    end
    sc_label_w = sc_label_w + 2 -- padding

    for _, sc in ipairs(source_checkouts) do
      local repo = sc.repo or "?"
      local branch = sc.branch or "?"
      local cell_text, spans = render_source_cell(sc)

      -- Build: "  <repo padded>  <branch>  <cell_text>"
      local label_pad = repo .. string.rep(" ", sc_label_w - #repo)
      local prefix = "  " .. label_pad .. "  " .. branch .. "  "
      local sc_line = prefix .. cell_text

      add_line(sc_line)
      local sc_row = #lines - 1

      -- Record standalone cell.
      local sc_cell_start = #prefix
      local sc_cell_end = #sc_line
      add_cell(sc_row, sc_cell_start, sc_cell_end, "standalone", nil, repo)

      -- Translate spans to line-absolute positions.
      for _, sp in ipairs(spans) do
        add_hl(sc_row, sc_cell_start + sp[1], sc_cell_start + sp[2], sp[3])
      end
    end
  end

  return { lines = lines, cells = cells, highlights = highlights }
end

---Build display lines from a decoded status table.
---
--- Backward-compatible wrapper around `M.build_grid` used by pre-Phase-4
--- callers (including the Phase 2/3 tests). Phase 4 and later consumers
--- should call `M.build_grid` directly to also receive cell coordinates and
--- highlight spans.
---
---@param status table decoded ws status document
---@return string[]
function M.build_lines(status)
  local grid = M.build_grid(status)
  return grid.lines
end

-- ---------------------------------------------------------------------------
-- Buffer management
-- ---------------------------------------------------------------------------

---Return a valid dashboard bufnr, (re)creating it if needed.
---@return integer bufnr
local function ensure_buf()
  -- Reuse if valid.
  if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then
    return _bufnr
  end

  -- Create a new scratch buffer.
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Give it the stable name; if another buffer already holds that name this
  -- pcall fails silently and we keep the numeric fallback.
  if not pcall(vim.api.nvim_buf_set_name, bufnr, BUF_NAME) then
    pcall(vim.api.nvim_buf_set_name, bufnr, BUF_NAME .. "#" .. bufnr)
  end

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"

  _bufnr = bufnr
  return bufnr
end

---Return (or lazily create) the content extmark namespace.
---@return integer ns
local function get_ns()
  if not _ns then
    _ns = vim.api.nvim_create_namespace("winter_dashboard")
  end
  return _ns
end

---Return (or lazily create) the selection extmark namespace.
--- Kept separate from the content namespace so clearing the selection highlight
--- never accidentally wipes the content highlights, and vice versa.
---@return integer ns
local function get_sel_ns()
  if not _sel_ns then
    _sel_ns = vim.api.nvim_create_namespace("winter_dashboard_sel")
  end
  return _sel_ns
end

---Return the selected cell for `bufnr` (defaults to the module-level _bufnr),
--- or nil when the dashboard has never been rendered / has no worktree cells.
--- The returned table includes the cell fields plus the virtual {row,col}.
---
---@param bufnr? integer  dashboard buffer number (defaults to module _bufnr)
---@return { kind: string, env: string|nil, repo: string|nil, row: integer, col: integer }|nil
function M.get_selection(bufnr)
  bufnr = bufnr or _bufnr
  if not bufnr then
    return nil
  end
  local sel = _selections[bufnr]
  if not sel then
    return nil
  end
  local nav = M.build_nav_grid(_cells)
  if nav.n_rows == 0 or nav.n_cols == 0 then
    return nil
  end
  local r = math.max(1, math.min(nav.n_rows, sel.row))
  local c = math.max(1, math.min(nav.n_cols, sel.col))
  local cell = nav.grid[r] and nav.grid[r][c]
  if not cell then
    return nil
  end
  return {
    kind = cell.kind,
    env = cell.env,
    repo = cell.repo,
    row = r,
    col = c,
  }
end

---Draw (or redraw) the selection extmark on the selected cell, and move the
--- real window cursor to the cell start so motion reads naturally.
--- If there is no valid selection (no worktree cells) this is a no-op.
--- Fires `User WinterDashboardSelectionChanged` when the logical selection
--- changes (row or col differs from the pre-clamp value); does NOT fire on a
--- pure redraw where the selection is already at the same position.
---
---@param bufnr integer
---@param prev_sel? { row: integer, col: integer }  selection before this move (nil = first render)
local function draw_selection(bufnr, prev_sel)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local sel = _selections[bufnr]
  if not sel then
    return
  end
  local nav = M.build_nav_grid(_cells)
  if nav.n_rows == 0 or nav.n_cols == 0 then
    return
  end

  -- Clamp selection into current grid bounds (handles grid shrinkage on refresh).
  local r = math.max(1, math.min(nav.n_rows, sel.row))
  local c = math.max(1, math.min(nav.n_cols, sel.col))
  -- Persist the clamped value.
  _selections[bufnr] = { row = r, col = c }

  local cell = nav.grid[r] and nav.grid[r][c]
  if not cell then
    return
  end

  local sel_ns = get_sel_ns()
  -- Clear previous selection extmark.
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, sel_ns, 0, -1)
  -- Set new selection extmark on the cell's byte range.
  pcall(
    vim.api.nvim_buf_set_extmark,
    bufnr,
    sel_ns,
    cell.row,
    cell.col_start,
    { end_col = cell.col_end, hl_group = "WinterDashSelection" }
  )

  -- Move the real cursor onto the selected cell start in every window showing
  -- this buffer (pcall-wrapped; if no window is open this is a silent no-op).
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr) or {}) do
    -- nvim_win_set_cursor takes {1-based line, 0-based col}
    pcall(vim.api.nvim_win_set_cursor, winid, { cell.row + 1, cell.col_start })
  end

  -- Fire WinterDashboardSelectionChanged only when the selection actually moved
  -- (not on every redraw / refresh that calls draw_selection with same position).
  -- prev_sel == nil means this is the first render initialisation — fire the event
  -- so listeners can observe the initial selection too.
  local changed = prev_sel == nil or (prev_sel.row ~= r or prev_sel.col ~= c)
  if changed then
    vim.api.nvim_exec_autocmds("User", {
      pattern = "WinterDashboardSelectionChanged",
      data = {
        buf = bufnr,
        selection = {
          kind = cell.kind,
          env = cell.env,
          repo = cell.repo,
          row = r,
          col = c,
        },
      },
    })
  end
end

---Open a diff for the given scope and mode via winter.diff.
--- Called from dashboard quick-diff keymaps.
---@param scope "repo"|"env"
---@param mode? string "branch"|"uncommitted"|"staged" (default: "branch")
local function open_dashboard_diff(scope, mode)
  local sel = M.get_selection()
  if not sel then
    vim.notify("winter.dashboard: no selection — navigate to a cell first", vim.log.levels.WARN)
    return
  end
  local env = sel.env
  if not env then
    vim.notify("winter.dashboard: selection has no env", vim.log.levels.WARN)
    return
  end

  local diff_opts = {
    env = env,
    mode = mode or "branch",
    -- Pass the already-rendered status from the last refresh to avoid a
    -- redundant CLI round-trip. _last_status is set by the refresh path.
    status = _last_status,
  }

  if scope == "repo" and sel.repo then
    diff_opts.repo = sel.repo
  end

  -- Load config lazily from the module-level snapshot (set on M.open).
  local cfg = _cfg
  if not cfg then
    vim.notify("winter.dashboard: dashboard has not been opened yet", vim.log.levels.WARN)
    return
  end

  require("winter.diff").open(cfg, diff_opts)
end

---Install buffer-local normal-mode navigation keymaps on the dashboard buffer.
--- Called once after the buffer is first created/rendered.
--- Each map is buffer-local (nowait, silent) and updates the virtual selection,
--- redraws the selection extmark, then moves the real cursor.
--- GLOBAL hjkl/arrow motions in every other buffer are completely unaffected.
---
--- Quick-diff keymaps (also installed buffer-local):
---   d   — repo-cell diff  (current env + repo, default branch mode)
---   D   — env-wide diff   (all repos in the current env, default branch mode)
---
--- For uncommitted/staged variants use the buffer-local command:
---   :WinterDashboardDiff [repo|env] [branch|uncommitted|staged]
---
---@param bufnr integer
local function install_nav_keymaps(bufnr)
  local function move(dir)
    return function()
      local nav = M.build_nav_grid(_cells)
      if nav.n_rows == 0 or nav.n_cols == 0 then
        return
      end
      local sel = _selections[bufnr] or { row = 1, col = 1 }
      local new_sel = M.nav_step(nav, sel, dir)
      -- Capture the previous selection for change-detection in draw_selection.
      local prev = { row = sel.row, col = sel.col }
      _selections[bufnr] = new_sel
      draw_selection(bufnr, prev)
    end
  end

  local map_opts = { buffer = bufnr, nowait = true, silent = true }

  vim.keymap.set("n", "h", move("h"), vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection left" }))
  vim.keymap.set(
    "n",
    "<Left>",
    move("h"),
    vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection left" })
  )
  vim.keymap.set("n", "l", move("l"), vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection right" }))
  vim.keymap.set(
    "n",
    "<Right>",
    move("l"),
    vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection right" })
  )
  vim.keymap.set("n", "j", move("j"), vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection down" }))
  vim.keymap.set(
    "n",
    "<Down>",
    move("j"),
    vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection down" })
  )
  vim.keymap.set("n", "k", move("k"), vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection up" }))
  vim.keymap.set("n", "<Up>", move("k"), vim.tbl_extend("force", map_opts, { desc = "Dashboard: move selection up" }))

  -- Quick-diff keymaps.
  -- d = repo-cell diff (current env + repo, branch mode).
  -- D = env-wide diff  (all repos in current env, branch mode).
  -- For uncommitted/staged variants use :WinterDashboardDiff [repo|env] [mode].
  vim.keymap.set("n", "d", function()
    open_dashboard_diff("repo", "branch")
  end, vim.tbl_extend("force", map_opts, { desc = "Dashboard: repo diff (branch)" }))
  vim.keymap.set("n", "D", function()
    open_dashboard_diff("env", "branch")
  end, vim.tbl_extend("force", map_opts, { desc = "Dashboard: env-wide diff (branch)" }))

  -- Close the dashboard window (buffer stays alive/hidden).
  -- Snacks disables its own default 'q' handler above; we install our own so
  -- 'q' closes the window and stops the timer rather than being a no-op.
  vim.keymap.set("n", "q", function()
    local cfg = _cfg
    if cfg then
      M.open(cfg, _opts, _runner)
    else
      -- Fallback: close whatever window is currently focused.
      local win = vim.api.nvim_get_current_win()
      pcall(vim.api.nvim_win_close, win, false)
    end
  end, vim.tbl_extend("force", map_opts, { desc = "Dashboard: close window" }))

  -- Buffer-local command for scope×mode matrix access.
  -- :WinterDashboardDiff [repo|env] [branch|uncommitted|staged]
  pcall(vim.api.nvim_buf_create_user_command, bufnr, "WinterDashboardDiff", function(cmd_opts)
    local args = cmd_opts.fargs
    local scope = args[1] or "repo"
    local diff_mode = args[2] or "branch"
    if scope ~= "repo" and scope ~= "env" then
      vim.notify("WinterDashboardDiff: scope must be repo or env", vim.log.levels.ERROR)
      return
    end
    if diff_mode ~= "branch" and diff_mode ~= "uncommitted" and diff_mode ~= "staged" then
      vim.notify("WinterDashboardDiff: mode must be branch, uncommitted, or staged", vim.log.levels.ERROR)
      return
    end
    open_dashboard_diff(scope, diff_mode)
  end, {
    nargs = "*",
    desc = "Open diff for dashboard selection: [repo|env] [branch|uncommitted|staged]",
    complete = function(arg_lead, cmd_line, _)
      local parts = vim.split(vim.trim(cmd_line), "%s+")
      if #parts <= 2 then
        local scopes = { "repo", "env" }
        local out = {}
        for _, s in ipairs(scopes) do
          if s:sub(1, #arg_lead) == arg_lead then
            out[#out + 1] = s
          end
        end
        return out
      elseif #parts == 3 then
        local modes = { "branch", "uncommitted", "staged" }
        local out = {}
        for _, m in ipairs(modes) do
          if m:sub(1, #arg_lead) == arg_lead then
            out[#out + 1] = m
          end
        end
        return out
      end
      return {}
    end,
  })
end

---Write lines and highlights into the dashboard buffer.
--- Discipline: modifiable=true → set_lines → set extmarks → modifiable=false.
---@param bufnr integer
---@param grid Winter.DashGrid
local function write_grid(bufnr, grid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ok_mod = pcall(function()
    vim.bo[bufnr].modifiable = true
  end)
  if not ok_mod then
    return
  end

  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, grid.lines)

  -- Clear and re-apply content extmark highlights.
  local ns = get_ns()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  for _, hl in ipairs(grid.highlights) do
    pcall(
      vim.api.nvim_buf_set_extmark,
      bufnr,
      ns,
      hl.row,
      hl.col_start,
      { end_col = hl.col_end, hl_group = hl.hl_group }
    )
  end

  -- Store cell table in buffer-local variable for Phase 5 (navigation).
  vim.b[bufnr].winter_dashboard = grid.cells

  pcall(function()
    vim.bo[bufnr].modifiable = false
  end)

  -- Phase 5: navigation — install keymaps once and (re)draw selection.
  -- Install keymaps lazily on the first render (idempotent: setting the same
  -- buffer-local keymap again is a silent overwrite, not an error).
  install_nav_keymaps(bufnr)

  -- Initialise selection to top-left on first render; on subsequent renders
  -- preserve the existing selection and re-clamp into the new grid bounds.
  local prev_sel = _selections[bufnr]
  if not prev_sel then
    local nav = M.build_nav_grid(grid.cells)
    if nav.n_rows > 0 and nav.n_cols > 0 then
      _selections[bufnr] = { row = 1, col = 1 }
    end
  end

  -- Pass prev_sel (nil on first render) so draw_selection can detect changes.
  draw_selection(bufnr, prev_sel)
end

-- ---------------------------------------------------------------------------
-- Window management — Snacks.win-backed, configurable layout
-- ---------------------------------------------------------------------------

---@class Winter.DashboardWinOpts
---@field position string "bottom"|"top"|"left"|"right"|"float"
---@field height? number height for Snacks.win (split or float)
---@field width? number width for Snacks.win (split or float)
---@field border? string border style for float
---@field title? string window title

---Translate the `dashboard` config table into a `Snacks.win` options table.
---
--- This is a PURE function (no side-effects, no UI) so tests can call it
--- directly to assert the mapping without opening a real window.
---
---@param dash_cfg Winter.DashboardConfig
---@return Winter.DashboardWinOpts
function M.resolve_win_opts(dash_cfg)
  local position = dash_cfg.position or "bottom"
  local size = dash_cfg.size

  local win_opts = {
    position = position,
    border = (position == "float") and (dash_cfg.border or "rounded") or nil,
    title = dash_cfg.title,
  }

  if position == "float" then
    -- size may be a plain number (used for both axes) or {width=, height=}
    if type(size) == "table" then
      win_opts.width = size.width
      win_opts.height = size.height
    elseif type(size) == "number" then
      win_opts.width = size
      win_opts.height = size
    else
      -- snacks float defaults (0.9 each)
      win_opts.width = 0.8
      win_opts.height = 0.6
    end
  else
    -- dock split: bottom/top use height; left/right use width
    local is_vertical = (position == "left" or position == "right")
    if is_vertical then
      win_opts.width = (type(size) == "number") and size or 0.4
    else
      win_opts.height = (type(size) == "number") and size or 15
    end
  end

  return win_opts
end

---Open a window showing the dashboard buffer via Snacks.win.
---
--- Snacks is already a hard dependency (the worktrees picker requires it).
--- If `require('snacks')` fails at runtime, degrades to a plain split with a
--- clear ERROR notification rather than crashing.
---
--- The persistent dashboard buffer (bufnr) is passed to Snacks.win via the
--- `buf` option so Snacks never creates a throwaway buffer — the module-level
--- `_bufnr` remains the canonical buffer target for refresh and toggle.
---
---@param bufnr integer
---@return integer winid  (0 on failure)
function M._open_window(bufnr)
  local ok_snacks, Snacks = pcall(require, "snacks")
  if not ok_snacks or type(Snacks) ~= "table" or not Snacks.win then
    vim.notify("winter.dashboard: snacks.nvim not available — falling back to plain split", vim.log.levels.ERROR)
    -- Fallback: plain bottom split (Phase-2 behaviour).
    pcall(vim.cmd, "botright new")
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_buf, win, bufnr)
    pcall(vim.api.nvim_win_set_height, win, 15)
    return win
  end

  -- Resolve layout from current config snapshot (set by M.open before calling).
  local dash_cfg = (_cfg and _cfg.dashboard) or {}
  local win_opts = M.resolve_win_opts(dash_cfg)

  -- Build the Snacks.win call options.
  -- Pass `buf = bufnr` so Snacks reuses our persistent buffer instead of
  -- creating a new scratch buffer.
  local snacks_opts = {
    buf = bufnr,
    position = win_opts.position,
    enter = true,
    -- Snacks minimal mode strips distracting chrome (line numbers, sign col…)
    minimal = true,
    -- Do NOT let Snacks wipe the buffer on close — bufhidden=hide is already
    -- set on the buffer; we just want the window closed.
    bo = {},
    -- Disable the default 'q' close keymap Snacks adds — the toggle manages
    -- open/close so a bare 'q' closing without firing the timer-stop is wrong.
    keys = {
      q = false,
    },
  }

  if win_opts.title then
    snacks_opts.title = win_opts.title
    snacks_opts.title_pos = "center"
  end

  if win_opts.height then
    snacks_opts.height = win_opts.height
  end
  if win_opts.width then
    snacks_opts.width = win_opts.width
  end
  if win_opts.border then
    snacks_opts.border = win_opts.border
  end

  local snacks_win = nil
  local ok_win, err = pcall(function()
    snacks_win = Snacks.win.new(snacks_opts)
  end)

  if not ok_win or not snacks_win then
    vim.notify(("winter.dashboard: Snacks.win.new failed: %s"):format(tostring(err)), vim.log.levels.ERROR)
    -- Fallback: plain split.
    pcall(vim.cmd, "botright new")
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_buf, win, bufnr)
    pcall(vim.api.nvim_win_set_height, win, 15)
    return win
  end

  return snacks_win.win or 0
end

-- ---------------------------------------------------------------------------
-- Timer helpers
-- ---------------------------------------------------------------------------

---Stop and dispose the repeating refresh timer.
local function stop_timer()
  if _timer then
    pcall(function()
      _timer:stop()
      _timer:close()
    end)
    _timer = nil
  end
end

---Cancel the WinClosed autocmd guard (idempotent).
local function clear_winclosed_autocmd()
  if _winclosed_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, _winclosed_autocmd_id)
    _winclosed_autocmd_id = nil
  end
end

---Register a one-shot WinClosed autocmd for `winid` that stops the refresh
--- timer when the window is closed by any means other than the toggle/q path.
--- Called right after a new window is opened. Idempotent: clears any
--- previously-registered autocmd before creating a new one.
---@param winid integer
local function arm_winclosed_guard(winid)
  clear_winclosed_autocmd()
  _winclosed_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      _winclosed_autocmd_id = nil
      stop_timer()
    end,
  })
end

---Start a repeating timer that calls M.refresh() every REFRESH_INTERVAL_MS.
---The timer is guarded against overlapping fetches via `_fetch_in_flight`.
local function start_timer()
  stop_timer()
  _timer = vim.uv.new_timer()
  if not _timer then
    return
  end
  _timer:start(REFRESH_INTERVAL_MS, REFRESH_INTERVAL_MS, function()
    -- Run on the main thread: M.refresh does UI work.
    vim.schedule(function()
      M.refresh(_cfg, _opts, _runner)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Async fetch + render
-- ---------------------------------------------------------------------------

---Fetch `winter ws status --json` and write the result into the buffer.
--- Safe to call at any time; skips silently when a fetch is already in flight.
---
--- Semantic non-zero exit code handling (dirty/ahead/behind workspace) is
--- delegated to `cli.run_status_async` — see that function for the rule.
--- Injected test runners are used verbatim (pre-normalised).
---
---@param cfg Winter.Config
---@param opts? { winter_args?: string[] }
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: table))
function M.refresh(cfg, opts, runner)
  if _fetch_in_flight then
    return
  end

  -- Buffer must still exist for the refresh to mean anything.
  if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then
    return
  end

  local root = workspace.find_root_from_context()
  if not root then
    -- Don't notify on timer ticks — the user already saw it on open.
    return
  end

  opts = opts or {}
  local effective_global_args = opts.winter_args or (cfg and cfg.winter_args) or {}

  -- Use cli.run_status_async so a semantic non-zero exit (dirty/ahead/behind
  -- workspace) is treated as success. The shared normalisation rule lives in
  -- cli.run_status_async — see there for the canonical comment.
  _fetch_in_flight = true
  cli.run_status_async(root, cfg, effective_global_args, function(result, err)
    vim.schedule(function()
      _fetch_in_flight = false

      -- Buffer may have been wiped while the fetch was in flight.
      if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then
        return
      end

      if err then
        vim.notify("winter.dashboard: " .. err, vim.log.levels.ERROR)
        return
      end

      local status, parse_err = M.parse_status(result.stdout)
      if not status then
        vim.notify("winter.dashboard: " .. (parse_err or "bad JSON"), vim.log.levels.ERROR)
        return
      end

      -- Store status so dashboard quick-diff can reuse it without a CLI refetch.
      _last_status = status

      M.setup_highlights()
      local grid = M.build_grid(status)
      -- Update module-level cell table for Phase 5 access.
      _cells = grid.cells
      write_grid(_bufnr, grid)
      vim.api.nvim_exec_autocmds("User", { pattern = "WinterDashboardRefreshed", data = { buf = _bufnr } })
    end)
  end, runner)
end

-- ---------------------------------------------------------------------------
-- Toggle (primary entry point)
-- ---------------------------------------------------------------------------

---Find the window currently displaying the dashboard buffer, or nil.
---@return integer|nil winid
local function find_dashboard_win()
  if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then
    return nil
  end
  local wins = vim.fn.win_findbuf(_bufnr)
  return wins and wins[1] or nil
end

---Toggle the dashboard: show it if hidden, hide it if visible.
---
--- On first open (or after the buffer was wiped):
---   1. Discovers the workspace root; notifies and returns if not in a workspace.
---   2. Creates the persistent nofile/nomodifiable buffer.
---   3. Opens the buffer in a window (`M._open_window`).
---   4. Triggers an immediate async refresh.
---   5. Starts the repeating timer.
---
--- On close: closes the window (buffer stays alive in background), stops timer.
---
---@param cfg Winter.Config
---@param opts? { winter_args?: string[] }
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: table))
function M.open(cfg, opts, runner)
  -- Snapshot for the timer callback.
  _cfg = cfg
  _opts = opts
  _runner = runner

  local win = find_dashboard_win()

  if win then
    -- Dashboard is visible: close the window (buffer stays alive/hidden).
    -- Clear the WinClosed guard before closing so it does not fire redundantly.
    clear_winclosed_autocmd()
    pcall(vim.api.nvim_win_close, win, false)
    stop_timer()
    return
  end

  -- Dashboard is not visible: check workspace root before committing to UI.
  local root = workspace.find_root_from_context()
  if not root then
    vim.notify("winter.nvim: not inside a winter workspace", vim.log.levels.WARN)
    return
  end

  local bufnr = ensure_buf()
  local winid = M._open_window(bufnr)
  arm_winclosed_guard(winid)
  start_timer()

  -- Immediate refresh to populate the buffer without waiting for the first
  -- timer tick (which fires after REFRESH_INTERVAL_MS).
  M.refresh(cfg, opts, runner)

  vim.api.nvim_exec_autocmds("User", { pattern = "WinterDashboardOpened", data = { buf = bufnr } })
end

return M
