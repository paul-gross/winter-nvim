-- Guard against double-loading
if vim.g.loaded_winter then
  return
end
vim.g.loaded_winter = true

-- Require Neovim 0.10+ (vim.system, used in cli.run_async, requires 0.10)
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("winter.nvim requires Neovim >= 0.10. Please upgrade your Neovim installation.", vim.log.levels.ERROR)
  return
end

-- Subcommand dispatch table. Adding a new feature is one line here.
-- Each handler receives a list of remaining args (after the subcommand word).
local subcommands = {
  worktrees = function(args)
    local opts = (#args > 0) and { winter_args = args } or nil
    require("winter").worktrees(opts)
  end,
  diff = function(args)
    -- Parse: first positional = env; --repo <name> for single-repo scope.
    local env = nil
    local repo = nil
    local winter_args = {}
    local i = 1
    while i <= #args do
      local a = args[i]
      if a == "--repo" then
        i = i + 1
        repo = args[i]
      elseif not env then
        env = a
      else
        winter_args[#winter_args + 1] = a
      end
      i = i + 1
    end
    local opts = { env = env }
    if repo then
      opts.repo = repo
    end
    if #winter_args > 0 then
      opts.winter_args = winter_args
    end
    require("winter").diff(opts)
  end,
  dashboard = function(args)
    local winter_args = {}
    for _, a in ipairs(args) do
      winter_args[#winter_args + 1] = a
    end
    local opts = (#winter_args > 0) and { winter_args = winter_args } or nil
    require("winter").dashboard(opts)
  end,
  refresh = function(_args)
    require("winter").dashboard_refresh()
  end,
}

-- :WinterWorktrees [winter-args...]
-- Opens the worktrees picker. Any args passed to the command are used as the
-- global winter args for that invocation (overriding config.winter_args).
-- Example: :WinterWorktrees --winter=/home/me/ws/alpha/winter
vim.api.nvim_create_user_command("WinterWorktrees", function(cmd_opts)
  local args = cmd_opts.fargs
  local opts = (#args > 0) and { winter_args = args } or nil
  require("winter").worktrees(opts)
end, {
  nargs = "*",
  desc = "Open the winter worktrees picker (optional: pass global winter args)",
})

-- :WinterDiff[!] [env] [--repo <name>] [winter-args...]
-- Opens the cross-repo feature diff for ENV (default "alpha") using codediff.nvim.
-- With no bang: branch diff (HEAD vs origin/<main_branch>).
-- With bang (:WinterDiff!): uncommitted working-tree changes (staged+unstaged+conflicts).
-- --repo <name>: limit diff to a single repo worktree within the env.
-- Any remaining args after parsing are passed as global winter args for this
-- invocation, overriding config.winter_args (e.g. to target a dev CLI build).
vim.api.nvim_create_user_command("WinterDiff", function(cmd_opts)
  -- Parse args: extract --repo <name> before treating remaining as env/winter_args.
  local raw_args = cmd_opts.fargs
  local env = nil
  local repo = nil
  local winter_args = {}
  local i = 1
  while i <= #raw_args do
    local a = raw_args[i]
    if a == "--repo" then
      i = i + 1
      repo = raw_args[i]
    elseif not env then
      env = a
    else
      winter_args[#winter_args + 1] = a
    end
    i = i + 1
  end
  env = env or "alpha"

  -- bang forces uncommitted; otherwise nil lets M.open resolve cfg.diff.mode.
  local mode = cmd_opts.bang and "uncommitted" or nil
  local opts = { env = env, mode = mode }
  if repo then
    opts.repo = repo
  end
  if #winter_args > 0 then
    opts.winter_args = winter_args
  end
  require("winter").diff(opts)
end, {
  nargs = "*",
  bang = true,
  desc = "Open the cross-repo feature diff via codediff (! = uncommitted; optional: env [--repo <name>] [winter-args...])",
})

-- :WinterDashboard [winter-args...]
-- Toggles the persistent workspace status dashboard. Any args are forwarded as
-- global winter args for this invocation (e.g. to target a dev CLI build).
vim.api.nvim_create_user_command("WinterDashboard", function(cmd_opts)
  local args = cmd_opts.fargs
  local opts = (#args > 0) and { winter_args = args } or nil
  require("winter").dashboard(opts)
end, {
  nargs = "*",
  desc = "Toggle the winter workspace status dashboard",
})

-- :WinterRefresh
-- Refreshes the dashboard if it is currently open. No-op (with a notification)
-- when the dashboard is not open.
vim.api.nvim_create_user_command("WinterRefresh", function(_cmd_opts)
  -- Check whether the dashboard window is visible before delegating, so we
  -- can surface a friendly notify rather than a silent no-op.
  local bufnr = vim.fn.bufnr("winter://dashboard")
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("winter.nvim: dashboard is not open", vim.log.levels.INFO)
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if not wins or #wins == 0 then
    vim.notify("winter.nvim: dashboard is not open", vim.log.levels.INFO)
    return
  end
  require("winter").dashboard_refresh()
end, {
  nargs = 0,
  desc = "Refresh the winter workspace status dashboard (no-op if not open)",
})

-- :Winter [subcommand] [winter-args...]
-- Umbrella dispatcher. With no args defaults to worktrees.
-- :Winter worktrees [args...]  → worktrees picker
-- :Winter <Tab>                → completes available subcommands
vim.api.nvim_create_user_command("Winter", function(cmd_opts)
  local args = cmd_opts.fargs

  -- No args: default to worktrees.
  if #args == 0 then
    require("winter").worktrees()
    return
  end

  local subcmd = args[1]
  local rest = {}
  for i = 2, #args do
    rest[#rest + 1] = args[i]
  end

  local handler = subcommands[subcmd]
  if handler then
    handler(rest)
  else
    local available = {}
    for name, _ in pairs(subcommands) do
      available[#available + 1] = name
    end
    table.sort(available)
    vim.notify(
      ("winter.nvim: unknown subcommand %q. Available: %s"):format(subcmd, table.concat(available, ", ")),
      vim.log.levels.ERROR
    )
  end
end, {
  nargs = "*",
  desc = "Winter integration: :Winter [worktrees] [winter-args...]",
  complete = function(arg_lead, cmd_line, _)
    -- Complete subcommand names on the first positional argument.
    local parts = vim.split(vim.trim(cmd_line), "%s+")
    -- parts[1] is "Winter", parts[2] is the subcommand being typed.
    if #parts <= 2 then
      local names = {}
      for name, _ in pairs(subcommands) do
        if name:sub(1, #arg_lead) == arg_lead then
          names[#names + 1] = name
        end
      end
      table.sort(names)
      return names
    end
    return {}
  end,
})
