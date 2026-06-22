---@mod winter.diff Cross-repo feature diff viewer
---@brief [[
--- Opens an aggregated cross-repo diff for a winter feature environment using
--- codediff.nvim (https://github.com/paul-gross/codediff.nvim) as the renderer.
--- codediff computes diffs directly from repo worktree roots + git revisions,
--- opening its own diff explorer in a new tab with native navigation, file-list,
--- syntax highlighting, and stage/unstage support.
---
--- This module is a thin adapter: it resolves the set of worktree roots and git
--- revisions for an env from `winter ws status --json`, then delegates to
--- codediff. No diff text is piped through this module.
---
---   :WinterDiff[!] [env] [--repo <name>]   open diff (! = uncommitted)
---   :Winter diff [env]                      umbrella alias
---
--- codediff's explorer provides its own navigation keymaps (next/prev hunk,
--- next/prev file, file-list, etc.). winter.nvim does NOT impose buffer-local
--- navigation commands — use codediff's native keymaps.
---
--- Migration note: this module was rewritten in Phase 7 from a deltaview.nvim-
--- based unified-diff renderer. The deltaview-specific commands
--- (:WinterDiffDrawer, :WinterDiffGotoFile*, :WinterDiffRefresh, :WinterDiffYank,
--- :WinterDiffNextHunk/:PrevHunk/:NextFile/:PrevFile) are intentionally dropped —
--- codediff's explorer provides equivalent functionality natively. If you relied
--- on :WinterDiffYank for Claude context, use codediff's file explorer and copy
--- from the diff panes directly.
---
--- Requires codediff.nvim (paul-gross/codediff.nvim) on the runtimepath.
--- Degrades to a clean ERROR notify when codediff is absent.
---
--- Modes:
---   branch      — `diff_repos`: HEAD vs origin/<main_branch> (committed diff)
---   uncommitted — `diff_repos_uncommitted`: working-tree staged+unstaged+conflicts
---   staged      — routes to `diff_repos_uncommitted` (codediff's working-tree
---                 explorer surfaces a "Staged Changes" group within the same view).
---                 A pure staged-only multi-repo view is not available in codediff's
---                 public API; the uncommitted explorer is the closest available path
---                 and shows staged changes prominently. This is documented here and
---                 in the README.
---@brief ]]

local cli = require("winter.cli")
local workspace = require("winter.workspace")

local M = {}

-- The diff modes :WinterDiff understands.
local VALID_MODES = { branch = true, uncommitted = true, staged = true }

---Resolve the codediff module, or notify and return nil.
---@return table|nil codediff
local function load_codediff()
  local ok, codediff = pcall(require, "codediff")
  if not ok then
    vim.notify(
      "winter.diff: codediff not found. Install paul-gross/codediff.nvim to use :WinterDiff.",
      vim.log.levels.ERROR
    )
    return nil
  end
  return codediff
end

---Build the list of codediff `diff_repos` specs for a branch diff.
--- Each spec = { root, base, target, label } where:
---   root  = absolute path to the worktree  (<workspace_root>/<env>/<repo>)
---   base  = "origin/<main_branch>"
---   target = "HEAD"
---   label = "<env>/<repo>"
---
--- Repos whose worktree directory does not exist on disk are skipped.
--- Exposed on M (pure) so tests can drive it without touching the filesystem
--- (pass a custom exists_fn to stub `vim.fn.isdirectory`).
---
---@param status table decoded `ws status --json` table
---@param opts { env: string, repo?: string, workspace_root: string }
---@param exists_fn? fun(path: string): boolean filesystem probe (injectable for tests; defaults to vim.fn.isdirectory)
---@return { root: string, base: string, target: string, label: string }[]
function M.build_specs(status, opts, exists_fn)
  exists_fn = exists_fn or function(p)
    return vim.fn.isdirectory(p) == 1
  end

  local env_name = opts.env
  local repo_filter = opts.repo
  local ws_root = opts.workspace_root

  -- Find the matching env in the status.
  local env_entry = nil
  for _, env in ipairs(status.environments or {}) do
    if env.name == env_name then
      env_entry = env
      break
    end
  end

  if not env_entry then
    return {}
  end

  local specs = {}
  for _, wt in ipairs(env_entry.worktrees or {}) do
    local repo = wt.repo or "?"
    local pass_filter = not repo_filter or repo == repo_filter
    if pass_filter then
      local root = ws_root .. "/" .. env_name .. "/" .. repo
      if exists_fn(root) then
        local main_branch = wt.main_branch or "master"
        local base = "origin/" .. main_branch
        local label = env_name .. "/" .. repo
        specs[#specs + 1] = { root = root, base = base, target = "HEAD", label = label }
      end
    end
  end

  return specs
end

---Build the list of roots for `diff_repos_uncommitted`.
--- Each root = { root = <path>, label = "<env>/<repo>" }.
--- Repos whose worktree directory does not exist are skipped.
---
---@param status table decoded `ws status --json` table
---@param opts { env: string, repo?: string, workspace_root: string }
---@param exists_fn? fun(path: string): boolean injectable filesystem probe
---@return { root: string, label: string }[]
function M.build_roots(status, opts, exists_fn)
  exists_fn = exists_fn or function(p)
    return vim.fn.isdirectory(p) == 1
  end

  local env_name = opts.env
  local repo_filter = opts.repo
  local ws_root = opts.workspace_root

  local env_entry = nil
  for _, env in ipairs(status.environments or {}) do
    if env.name == env_name then
      env_entry = env
      break
    end
  end

  if not env_entry then
    return {}
  end

  local roots = {}
  for _, wt in ipairs(env_entry.worktrees or {}) do
    local repo = wt.repo or "?"
    local pass_filter = not repo_filter or repo == repo_filter
    if pass_filter then
      local root = ws_root .. "/" .. env_name .. "/" .. repo
      if exists_fn(root) then
        roots[#roots + 1] = { root = root, label = env_name .. "/" .. repo }
      end
    end
  end

  return roots
end

---Dispatch to codediff using the resolved specs/roots for the given mode.
---Fires `User WinterDiffOpened` after dispatching.
---@param codediff table the codediff module
---@param status table decoded ws status document
---@param env string
---@param repo? string optional single-repo filter
---@param mode string "branch"|"uncommitted"|"staged"
---@param ws_root string workspace root path
---@param diff_layout? string optional codediff layout ("inline"|"side-by-side")
local function dispatch(codediff, status, env, repo, mode, ws_root, diff_layout)
  local codediff_opts = {}
  if diff_layout then
    codediff_opts.layout = diff_layout
  end

  if mode == "branch" then
    local specs = M.build_specs(status, { env = env, repo = repo, workspace_root = ws_root })
    if #specs == 0 then
      vim.notify(("winter.diff: no worktree dirs found for env %q"):format(env), vim.log.levels.INFO)
      return
    end
    local ok, err = pcall(codediff.diff_repos, specs, codediff_opts)
    if not ok then
      vim.notify(("winter.diff: codediff.diff_repos failed: %s"):format(tostring(err)), vim.log.levels.ERROR)
      return
    end
  else
    -- Both "uncommitted" and "staged" route to diff_repos_uncommitted.
    -- codediff's working-tree explorer surfaces staged/unstaged/conflicts
    -- as separate groups. There is no pure staged-only multi-repo API.
    local roots = M.build_roots(status, { env = env, repo = repo, workspace_root = ws_root })
    if #roots == 0 then
      vim.notify(("winter.diff: no worktree dirs found for env %q"):format(env), vim.log.levels.INFO)
      return
    end
    local ok, err = pcall(codediff.diff_repos_uncommitted, roots, codediff_opts)
    if not ok then
      vim.notify(
        ("winter.diff: codediff.diff_repos_uncommitted failed: %s"):format(tostring(err)),
        vim.log.levels.ERROR
      )
      return
    end
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "WinterDiffOpened",
    data = { env = env, repo = repo, mode = mode },
  })
end

---Open the cross-repo diff for a feature environment.
---
--- Fetches `winter [global_args] ws status --json` to resolve worktree roots
--- and main_branch values, then dispatches to codediff in a new tab.
---
--- Accepts an optional pre-parsed `status` table (e.g. passed from the
--- dashboard after its own fetch) to avoid a redundant CLI round-trip.
---
---@param cfg Winter.Config plugin configuration
---@param opts? { env?: string, repo?: string, mode?: string, winter_args?: string[], status?: table } env (default "alpha"); repo (optional single-repo scope); mode ("branch"|"uncommitted"|"staged", default cfg.diff.mode); winter_args overrides cfg.winter_args; status pre-parsed status table (skips CLI refetch)
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: table)) injectable CLI runner for unit tests
function M.open(cfg, opts, runner)
  opts = opts or {}
  local env = opts.env or "alpha"
  local repo = opts.repo or nil
  local mode = opts.mode or (cfg.diff and cfg.diff.mode) or "branch"

  if not VALID_MODES[mode] then
    vim.notify(("winter.diff: invalid mode %q (use branch|uncommitted|staged)"):format(mode), vim.log.levels.ERROR)
    return
  end

  local codediff = load_codediff()
  if not codediff then
    return
  end

  local root = workspace.find_root_from_context()
  if not root then
    vim.notify("winter.diff: not inside a winter workspace", vim.log.levels.ERROR)
    return
  end

  local diff_layout = cfg.diff and cfg.diff.layout or nil

  -- If a pre-parsed status is supplied (e.g. from the dashboard), skip the CLI fetch.
  if opts.status then
    vim.schedule(function()
      dispatch(codediff, opts.status, env, repo, mode, root, diff_layout)
    end)
    return
  end

  -- Guard the CLI before spawning.
  if vim.fn.executable(cfg.winter_cmd) == 0 then
    vim.notify(
      ("winter.diff: winter CLI not found on PATH (looked for %q)"):format(cfg.winter_cmd),
      vim.log.levels.ERROR
    )
    return
  end

  local effective_global_args = opts.winter_args or cfg.winter_args or {}
  -- Use run_status_async so a semantic non-zero exit (dirty/ahead/behind workspace)
  -- is treated as success. See cli.run_status_async for the shared normalisation rule.
  cli.run_status_async(root, cfg, effective_global_args, function(result, err)
    vim.schedule(function()
      if err then
        vim.notify("winter.diff: " .. err, vim.log.levels.ERROR)
        return
      end

      local ok, status = pcall(vim.json.decode, result.stdout or "")
      if not ok or type(status) ~= "table" then
        vim.notify("winter.diff: failed to parse status JSON", vim.log.levels.ERROR)
        return
      end

      dispatch(codediff, status, env, repo, mode, root, diff_layout)
    end)
  end, runner)
end

return M
