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

---Run `winter ws status --json` asynchronously, tolerating the semantic non-zero
---exit code that `winter ws status` uses to signal dirty/ahead/behind state.
---
--- `winter ws status` exits with code 1 (not 0) when any repo is dirty or
--- ahead/behind. This is a semantic exit code — the JSON payload is still valid.
--- This helper normalises that: when the process exits non-zero but stdout is
--- non-empty, the result is treated as success (code=0). True failures produce
--- empty stdout and are forwarded as errors.
---
--- Both `dashboard.lua` and `diff.lua` use this helper so the normalisation
--- rule lives in ONE place.
---
--- An optional callback-style `runner` can be injected for unit tests — same
--- contract as `run_async`: receives `(argv, cwd, on_exit)` and invokes
--- `on_exit` with `{ code, stdout, stderr }`. Injected runners are used
--- verbatim (no normalisation wrapper applied) so tests can pre-normalise.
---
---@param root string workspace root directory (used as cwd)
---@param cfg Winter.Config plugin configuration
---@param global_args string[] global flags (see build_argv)
---@param on_done fun(result: {code: integer, stdout: string, stderr: string}|nil, err: string|nil)
---@param runner? fun(argv: string[], cwd: string, on_exit: fun(result: {code: integer, stdout: string, stderr: string}))
function M.run_status_async(root, cfg, global_args, on_done, runner)
  -- When a test runner is injected, use it directly (tests supply pre-normalised
  -- results and expect the raw on_done semantics from run_async).
  if runner then
    M.run_async(root, cfg, global_args, { "ws", "status", "--json" }, on_done, runner)
    return
  end

  -- Real invocation: wrap vim.system to normalise the semantic non-zero exit.
  local argv = M.build_argv(cfg.winter_cmd, global_args, { "ws", "status", "--json" })
  vim.system(argv, { cwd = root, text = true }, function(result)
    if result.code ~= 0 and vim.trim(result.stdout or "") ~= "" then
      -- Semantic non-zero: dirty/ahead/behind workspace. JSON is still valid.
      on_done({ code = 0, stdout = result.stdout, stderr = result.stderr }, nil)
    else
      -- True failure (empty stdout) or success (code 0): forward as-is.
      local function on_exit(r)
        if r.code ~= 0 then
          local stderr = vim.trim(r.stderr or "")
          on_done(nil, ("winter CLI exited with code %d: %s"):format(r.code, stderr ~= "" and stderr or "(no output)"))
        else
          on_done(r, nil)
        end
      end
      on_exit(result)
    end
  end)
end

return M
