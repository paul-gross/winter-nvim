---@mod winter.cli CLI invocation seam for winter.nvim
---@brief [[
--- Single seam for invoking the winter CLI. All winter CLI calls go through
--- this module so argument ordering is enforced consistently.
---
--- Argument ordering rule: the winter wrapper only honours `--winter=PATH` when
--- it is the FIRST argument after the executable. Therefore:
---
---   argv = { winter_cmd, <global_args...>, <subcommand_args...> }
---
--- `build_argv` enforces this ordering. `run_async` calls `build_argv`
--- internally.
---
--- `run_async` is non-blocking: it invokes `vim.system(argv, …, on_exit)` and
--- returns immediately, delivering the raw `{ code, stdout, stderr }` result
--- table to its `on_done` callback. The UI thread is never blocked. Callers are
--- responsible for JSON decoding so this module stays data-format–agnostic.
---@brief ]]

local M = {}

---Build an argv list from the configured executable, global args, and
---subcommand args. Ordering is enforced:
---  { winter_cmd, <global_args...>, <subcommand_args...> }
---
---@param winter_cmd string the winter executable (e.g. "winter" or "/path/to/winter")
---@param global_args string[] global flags (e.g. {"--winter=/path"}) — inserted immediately after winter_cmd
---@param subcommand_args string[] subcommand + its flags (e.g. {"ws","worktrees","--json"})
---@return string[] argv
function M.build_argv(winter_cmd, global_args, subcommand_args)
  local argv = { winter_cmd }
  for _, a in ipairs(global_args) do
    argv[#argv + 1] = a
  end
  for _, a in ipairs(subcommand_args) do
    argv[#argv + 1] = a
  end
  return argv
end

---Run the winter CLI asynchronously, delivering the raw result to `on_done`.
---
--- cwd is set to `root` (the workspace root). The CLI is invoked via
--- `vim.system(argv, opts, on_exit)`, which returns immediately and fires
--- `on_exit` on completion — the UI thread is never blocked.
---
--- `on_done` is called with `(result, nil)` on success or `(nil, err)` on a
--- non-zero exit, where result is a `{ code, stdout, stderr }` table. The
--- callback runs in the libuv context where `vim.system` fires its `on_exit`;
--- callers doing UI work must wrap it in `vim.schedule()`.
---
--- An optional callback-style `runner` can be injected for unit tests — it
--- receives `(argv, cwd, on_exit)` and must invoke `on_exit` with a
--- `{ code, stdout, stderr }` table. Tests invoke `on_exit` synchronously so the
--- async wiring stays deterministically testable. Defaults to a
--- `vim.system(argv, …, on_exit)` wrapper.
---
---@param root string workspace root directory (used as cwd)
---@param cfg Winter.Config plugin configuration (only winter_cmd is used here)
---@param global_args string[] global flags (see build_argv)
---@param subcommand_args string[] subcommand + its flags (see build_argv)
---@param on_done fun(result: {code: integer, stdout: string, stderr: string}|nil, err: string|nil)
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: {code: integer, stdout: string, stderr: string}))
function M.run_async(root, cfg, global_args, subcommand_args, on_done, runner)
  local argv = M.build_argv(cfg.winter_cmd, global_args, subcommand_args)

  ---@param result {code: integer, stdout: string, stderr: string}
  local function on_exit(result)
    if result.code ~= 0 then
      local stderr = vim.trim(result.stderr or "")
      on_done(nil, ("winter CLI exited with code %d: %s"):format(result.code, stderr ~= "" and stderr or "(no output)"))
      return
    end
    on_done(result, nil)
  end

  if runner then
    runner(argv, root, on_exit)
  else
    vim.system(argv, { cwd = root, text = true }, on_exit)
  end
end

return M
