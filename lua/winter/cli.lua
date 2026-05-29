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
--- `build_argv` enforces this ordering. `run` calls `build_argv` internally.
---
--- `run` returns the raw `{ code, stdout, stderr }` result table. Callers are
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

---Run the winter CLI with the given args, returning the raw result.
---
--- cwd is set to `root` (the workspace root). An optional `runner` function
--- can be injected for unit tests — it receives the argv table and cwd string
--- and must return a table with `code` (integer), `stdout` (string), and
--- `stderr` (string) fields. Defaults to a `vim.system(...):wait()` wrapper.
---
---@param root string workspace root directory (used as cwd)
---@param cfg Winter.Config plugin configuration (only winter_cmd is used here)
---@param global_args string[] global flags (see build_argv)
---@param subcommand_args string[] subcommand + its flags (see build_argv)
---@param runner? fun(argv: string[], cwd: string): {code: integer, stdout: string, stderr: string}
---@return {code: integer, stdout: string, stderr: string}|nil result, string|nil err
function M.run(root, cfg, global_args, subcommand_args, runner)
  local argv = M.build_argv(cfg.winter_cmd, global_args, subcommand_args)

  local result
  if runner then
    result = runner(argv, root)
  else
    result = vim.system(argv, { cwd = root, text = true }):wait()
  end

  if result.code ~= 0 then
    local stderr = vim.trim(result.stderr or "")
    return nil, ("winter CLI exited with code %d: %s"):format(result.code, stderr ~= "" and stderr or "(no output)")
  end

  return result, nil
end

return M
