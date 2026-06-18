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
    -- First positional arg (if any) is the env; remaining args are winter_args.
    local env = args[1]
    local winter_args = {}
    for i = 2, #args do
      winter_args[#winter_args + 1] = args[i]
    end
    local opts = { env = env }
    if #winter_args > 0 then
      opts.winter_args = winter_args
    end
    require("winter").diff(opts)
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

-- :WinterDiff[!] [env] [winter-args...]
-- Opens the cross-repo feature diff for ENV (default "alpha"), replacing the
-- buffer in the current window.
-- With no bang: branch diff (HEAD vs main) via config.diff.mode.
-- With bang (:WinterDiff!): uncommitted working-tree changes.
-- Any args after [env] are passed as global winter args for this invocation,
-- overriding config.winter_args (e.g. to target a dev CLI build).
vim.api.nvim_create_user_command("WinterDiff", function(cmd_opts)
  local env = cmd_opts.fargs[1] or "alpha"
  -- bang forces uncommitted; otherwise nil lets M.open resolve cfg.diff.mode.
  local mode = cmd_opts.bang and "uncommitted" or nil
  local winter_args = {}
  for i = 2, #cmd_opts.fargs do
    winter_args[#winter_args + 1] = cmd_opts.fargs[i]
  end
  local opts = { env = env, mode = mode }
  if #winter_args > 0 then
    opts.winter_args = winter_args
  end
  require("winter").diff(opts)
end, {
  nargs = "*",
  bang = true,
  desc = "Open the cross-repo feature diff (! = uncommitted working tree; optional: env [winter-args...])",
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
