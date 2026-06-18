-- Tests for the winter.nvim plugin.
-- Run via: make test (uses mini.test)

local T = MiniTest.new_set()

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------

T["module loads without error"] = function()
  local ok, winter = pcall(require, "winter")
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(winter), "table")
end

T["module exposes setup() function"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.setup), "function")
end

T["module exposes worktrees() function"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.worktrees), "function")
end

T["module exposes switch_to() function"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.switch_to), "function")
end

T["module exposes open() deprecated alias"] = function()
  local winter = require("winter")
  MiniTest.expect.equality(type(winter.open), "function")
end

-- ---------------------------------------------------------------------------
-- Config / setup()
-- ---------------------------------------------------------------------------

T["setup() with no args applies defaults"] = function()
  local winter = require("winter")
  winter.setup()

  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
  MiniTest.expect.equality(winter.config.winter_args, {})
  MiniTest.expect.equality(winter.config.picker.layout, nil)
  MiniTest.expect.equality(winter.config.keymaps.open, nil)
  MiniTest.expect.equality(winter.config.use_sessions, true)
  MiniTest.expect.equality(winter.config.create_sessions, false)
  MiniTest.expect.equality(winter.config.cd_command, "cd")
  MiniTest.expect.equality(type(winter.config.session_dir), "string")
end

T["setup() merges opts over defaults"] = function()
  local winter = require("winter")
  winter.setup({
    winter_cmd = "winter2",
    winter_args = { "--winter=/some/path" },
    use_sessions = false,
    cd_command = "tcd",
  })

  MiniTest.expect.equality(winter.config.winter_cmd, "winter2")
  MiniTest.expect.equality(winter.config.winter_args, { "--winter=/some/path" })
  MiniTest.expect.equality(winter.config.use_sessions, false)
  MiniTest.expect.equality(winter.config.cd_command, "tcd")
  -- unset key still gets default
  MiniTest.expect.equality(winter.config.picker.layout, nil)
end

T["setup() does not mutate defaults when called twice"] = function()
  local config_module = require("winter.config")
  local winter = require("winter")

  winter.setup({ winter_cmd = "custom" })
  -- Reset to defaults
  winter.setup({})

  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
  -- Ensure the module-level defaults table itself was not mutated
  MiniTest.expect.equality(config_module.defaults.winter_cmd, "winter")
end

T["setup() with custom winter_cmd merges correctly"] = function()
  local winter = require("winter")
  winter.setup({ winter_cmd = "my-winter" })
  MiniTest.expect.equality(winter.config.winter_cmd, "my-winter")
  -- unrelated defaults remain intact
  MiniTest.expect.equality(winter.config.use_sessions, true)
end

T["setup() with winter_args merges correctly"] = function()
  local winter = require("winter")
  winter.setup({ winter_args = { "--winter=/dev/path" } })
  MiniTest.expect.equality(winter.config.winter_args, { "--winter=/dev/path" })
  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
end

T["setup() create_sessions defaults to false"] = function()
  local winter = require("winter")
  winter.setup()
  MiniTest.expect.equality(winter.config.create_sessions, false)
end

T["setup() merges create_sessions=true over default false"] = function()
  local winter = require("winter")
  winter.setup({ create_sessions = true })
  MiniTest.expect.equality(winter.config.create_sessions, true)
  -- other defaults intact
  MiniTest.expect.equality(winter.config.use_sessions, true)
  MiniTest.expect.equality(winter.config.winter_cmd, "winter")
end

-- ---------------------------------------------------------------------------
-- cli.build_argv — argument ordering
-- ---------------------------------------------------------------------------

T["cli.build_argv orders: winter_cmd, global_args, subcommand_args"] = function()
  local cli = require("winter.cli")

  local argv = cli.build_argv("winter", { "--winter=/home/x/ws/alpha/winter" }, { "ws", "worktrees", "--json" })

  MiniTest.expect.equality(#argv, 5)
  MiniTest.expect.equality(argv[1], "winter")
  MiniTest.expect.equality(argv[2], "--winter=/home/x/ws/alpha/winter")
  MiniTest.expect.equality(argv[3], "ws")
  MiniTest.expect.equality(argv[4], "worktrees")
  MiniTest.expect.equality(argv[5], "--json")
end

T["cli.build_argv with empty global_args omits them"] = function()
  local cli = require("winter.cli")

  local argv = cli.build_argv("winter", {}, { "ws", "worktrees", "--json" })

  MiniTest.expect.equality(#argv, 4)
  MiniTest.expect.equality(argv[1], "winter")
  MiniTest.expect.equality(argv[2], "ws")
  MiniTest.expect.equality(argv[3], "worktrees")
  MiniTest.expect.equality(argv[4], "--json")
end

T["cli.build_argv with multiple global_args preserves order"] = function()
  local cli = require("winter.cli")

  local argv = cli.build_argv("mywinter", { "--flag-a", "--flag-b" }, { "ws", "status" })

  MiniTest.expect.equality(#argv, 5)
  MiniTest.expect.equality(argv[1], "mywinter")
  MiniTest.expect.equality(argv[2], "--flag-a")
  MiniTest.expect.equality(argv[3], "--flag-b")
  MiniTest.expect.equality(argv[4], "ws")
  MiniTest.expect.equality(argv[5], "status")
end

-- ---------------------------------------------------------------------------
-- cli.run_async with injected callback-style fake runner
--
-- The injected runner receives (argv, cwd, on_exit) and drives on_exit
-- synchronously with a fake result table, so the async wiring is exercised
-- deterministically without spawning a real process.
-- ---------------------------------------------------------------------------

local sample_json = [[
  [
    {"kind":"worktree","env":"alpha","repo":"winter","name":null,"label":"alpha/winter","path":"/ws/alpha/winter"},
    {"kind":"standalone","env":null,"repo":null,"name":"winter-harness","label":"winter-harness","path":"/ws/winter-harness"}
  ]
]]

T["cli.run_async with fake runner delivers raw result on success"] = function()
  local cli = require("winter.cli")
  local cfg = require("winter.config").defaults

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 0, stdout = sample_json, stderr = "" })
  end

  local result, err
  cli.run_async("/fake/root", cfg, {}, { "ws", "worktrees", "--json" }, function(res, e)
    result, err = res, e
  end, fake_runner)

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(result), "table")
  MiniTest.expect.equality(result.code, 0)

  -- Caller decodes JSON
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(#decoded, 2)
  MiniTest.expect.equality(decoded[1].label, "alpha/winter")
  MiniTest.expect.equality(decoded[2].label, "winter-harness")
end

T["cli.run_async with fake runner delivers nil + error on non-zero exit"] = function()
  local cli = require("winter.cli")
  local cfg = require("winter.config").defaults

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 1, stdout = "", stderr = "some CLI error" })
  end

  local result, err
  cli.run_async("/fake/root", cfg, {}, { "ws", "worktrees", "--json" }, function(res, e)
    result, err = res, e
  end, fake_runner)

  MiniTest.expect.equality(result, nil)
  MiniTest.expect.equality(type(err), "string")
  -- Error message should include the stderr content
  MiniTest.expect.equality(err:find("some CLI error") ~= nil, true)
end

T["cli.run_async passes global_args before subcommand_args to runner"] = function()
  local cli = require("winter.cli")
  local cfg = require("winter.config").defaults

  local captured_argv = nil
  local fake_runner = function(argv, _cwd, on_exit)
    captured_argv = argv
    on_exit({ code = 0, stdout = "[]", stderr = "" })
  end

  cli.run_async(
    "/fake/root",
    cfg,
    { "--winter=/some/path" },
    { "ws", "worktrees", "--json" },
    function() end,
    fake_runner
  )

  MiniTest.expect.equality(type(captured_argv), "table")
  MiniTest.expect.equality(captured_argv[1], "winter")
  MiniTest.expect.equality(captured_argv[2], "--winter=/some/path")
  MiniTest.expect.equality(captured_argv[3], "ws")
end

-- ---------------------------------------------------------------------------
-- worktrees.build_subcommand — status flag
-- ---------------------------------------------------------------------------

T["worktrees.build_subcommand without status omits --status"] = function()
  local worktrees = require("winter.worktrees")
  local args = worktrees.build_subcommand(false)
  MiniTest.expect.equality(args, { "ws", "worktrees", "--json" })
end

T["worktrees.build_subcommand with status includes --status"] = function()
  local worktrees = require("winter.worktrees")
  local args = worktrees.build_subcommand(true)
  MiniTest.expect.equality(args, { "ws", "worktrees", "--json", "--status" })
end

-- ---------------------------------------------------------------------------
-- diff.diff_args — pure mode→argv mapping for `winter ws diff`
-- ---------------------------------------------------------------------------

T["diff.diff_args branch mode appends --branch"] = function()
  local diff = require("winter.diff")
  MiniTest.expect.equality(diff.diff_args("alpha", "branch"), { "ws", "diff", "alpha", "--no-headers", "--branch" })
end

T["diff.diff_args uncommitted mode appends no flag"] = function()
  local diff = require("winter.diff")
  MiniTest.expect.equality(diff.diff_args("beta", "uncommitted"), { "ws", "diff", "beta", "--no-headers" })
end

T["diff.diff_args staged mode appends --staged"] = function()
  local diff = require("winter.diff")
  MiniTest.expect.equality(diff.diff_args("gamma", "staged"), { "ws", "diff", "gamma", "--no-headers", "--staged" })
end

-- ---------------------------------------------------------------------------
-- diff.default_format — pure Claude-context yank formatter
-- ---------------------------------------------------------------------------

T["diff.default_format emits the claude xml file shape"] = function()
  local diff = require("winter.diff")
  local out = diff.default_format({
    path = "winter/lua/foo.lua",
    lines = "10-12",
    language = "lua",
    content = "local x = 1",
  })
  MiniTest.expect.equality(out, '<file path="winter/lua/foo.lua" lines="10-12" language="lua">\nlocal x = 1\n</file>')
end

-- ---------------------------------------------------------------------------
-- worktrees.parse_items — pure JSON parsing with and without status fields
-- ---------------------------------------------------------------------------

local sample_with_status = [[
  [
    {"kind":"worktree","env":"alpha","repo":"winter","name":null,"label":"alpha/winter","path":"/ws/alpha/winter","ahead":0,"behind":3,"dirty":2},
    {"kind":"standalone","env":null,"repo":null,"name":"winter-harness","label":"winter-harness","path":"/ws/winter-harness","ahead":1,"behind":0,"dirty":0}
  ]
]]

local sample_without_status = [[
  [
    {"kind":"worktree","env":"alpha","repo":"winter","name":null,"label":"alpha/winter","path":"/ws/alpha/winter"},
    {"kind":"standalone","env":null,"repo":null,"name":"winter-harness","label":"winter-harness","path":"/ws/winter-harness"}
  ]
]]

T["worktrees.parse_items parses items with status fields (ahead/behind/dirty)"] = function()
  local worktrees = require("winter.worktrees")

  local items, err = worktrees.parse_items(sample_with_status)

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 2)

  local first = items[1]
  MiniTest.expect.equality(first.label, "alpha/winter")
  MiniTest.expect.equality(first.ahead, 0)
  MiniTest.expect.equality(first.behind, 3)
  MiniTest.expect.equality(first.dirty, 2)

  local second = items[2]
  MiniTest.expect.equality(second.label, "winter-harness")
  MiniTest.expect.equality(second.ahead, 1)
  MiniTest.expect.equality(second.behind, 0)
  MiniTest.expect.equality(second.dirty, 0)
end

T["worktrees.parse_items parses items without status fields (fields are nil)"] = function()
  local worktrees = require("winter.worktrees")

  local items, err = worktrees.parse_items(sample_without_status)

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 2)

  local first = items[1]
  MiniTest.expect.equality(first.label, "alpha/winter")
  MiniTest.expect.equality(first.ahead, nil)
  MiniTest.expect.equality(first.behind, nil)
  MiniTest.expect.equality(first.dirty, nil)

  local second = items[2]
  MiniTest.expect.equality(second.label, "winter-harness")
  MiniTest.expect.equality(second.ahead, nil)
  MiniTest.expect.equality(second.behind, nil)
  MiniTest.expect.equality(second.dirty, nil)
end

T["worktrees.parse_items returns nil + err on empty output"] = function()
  local worktrees = require("winter.worktrees")

  local items, err = worktrees.parse_items("   ")

  MiniTest.expect.equality(items, nil)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:find("empty") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- worktrees.fetch_async — async fetch driven by a synchronous fake runner
-- ---------------------------------------------------------------------------

T["worktrees.fetch_async delivers parsed items via callback"] = function()
  local worktrees = require("winter.worktrees")
  local cfg = require("winter.config").defaults

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 0, stdout = sample_with_status, stderr = "" })
  end

  local items, err
  worktrees.fetch_async("/fake/root", cfg, {}, true, function(its, e)
    items, err = its, e
  end, fake_runner)

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 2)
  MiniTest.expect.equality(items[1].label, "alpha/winter")
  MiniTest.expect.equality(items[1].behind, 3)
end

T["worktrees.fetch_async delivers nil + err on CLI failure"] = function()
  local worktrees = require("winter.worktrees")
  local cfg = require("winter.config").defaults

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 1, stdout = "", stderr = "status error" })
  end

  local items, err
  worktrees.fetch_async("/fake/root", cfg, {}, true, function(its, e)
    items, err = its, e
  end, fake_runner)

  MiniTest.expect.equality(items, nil)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:find("status error") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- User commands (registered by plugin/winter.lua)
-- ---------------------------------------------------------------------------

T[":Winter command is registered after plugin file runs"] = function()
  -- Source the plugin file (guards against double-load)
  -- Reset the guard so we can source it in isolation
  vim.g.loaded_winter = nil
  local plugin_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/plugin/winter.lua"
  vim.cmd("source " .. plugin_path)

  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(type(cmds["Winter"]), "table")
end

T[":WinterWorktrees command is registered after plugin file runs"] = function()
  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(type(cmds["WinterWorktrees"]), "table")
end

-- ---------------------------------------------------------------------------
-- workspace.find_root — pure filesystem logic, no CLI needed
-- ---------------------------------------------------------------------------

T["workspace.find_root returns nil outside a winter workspace"] = function()
  local workspace = require("winter.workspace")

  -- Create a temp dir that is NOT a workspace.
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  local root = workspace.find_root(tmpdir)
  MiniTest.expect.equality(root, nil)

  vim.fn.delete(tmpdir, "rf")
end

T["workspace.find_root returns root when .winter/ is present"] = function()
  local workspace = require("winter.workspace")

  -- Build a minimal fake workspace under a temp dir.
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir .. "/.winter", "p")
  vim.fn.writefile({ "[workspace]" }, tmpdir .. "/.winter/config.toml")

  -- Start searching from a nested subdirectory.
  local nested = tmpdir .. "/alpha/myrepo/src"
  vim.fn.mkdir(nested, "p")

  local root = workspace.find_root(nested)
  MiniTest.expect.equality(root, tmpdir)

  vim.fn.delete(tmpdir, "rf")
end

-- Regression: a consumer workspace has `.winter/` but does NOT vendor the CLI
-- under `tools/winter-cli/`. The plugin must still recognise it (it keys on the
-- `.winter/` directory alone, matching the winter CLI's own root convention).
T["workspace.find_root recognises a workspace without tools/winter-cli"] = function()
  local workspace = require("winter.workspace")

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir .. "/.winter", "p")
  -- Deliberately no tools/winter-cli and no config.toml file.

  local nested = tmpdir .. "/alpha/myrepo/src"
  vim.fn.mkdir(nested, "p")

  local root = workspace.find_root(nested)
  MiniTest.expect.equality(root, tmpdir)

  vim.fn.delete(tmpdir, "rf")
end

T["workspace.find_root works when given a file path"] = function()
  local workspace = require("winter.workspace")

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir .. "/.winter", "p")
  vim.fn.writefile({ "[workspace]" }, tmpdir .. "/.winter/config.toml")

  local fake_file = tmpdir .. "/myfile.lua"
  vim.fn.writefile({ "-- lua" }, fake_file)

  local root = workspace.find_root(fake_file)
  MiniTest.expect.equality(root, tmpdir)

  vim.fn.delete(tmpdir, "rf")
end

-- ---------------------------------------------------------------------------
-- CLI JSON parsing (shape validation via sample payload)
-- ---------------------------------------------------------------------------

T["cli JSON parsing: two-element payload has correct shape"] = function()
  -- We exercise the JSON-parsing branch by decoding the canonical sample
  -- payload from the spec and checking the shapes that the worktrees feature
  -- would receive after cli.run_async delivers raw stdout.
  local sample = vim.json.decode([[
    [
      {"kind":"worktree","env":"alpha","repo":"winter","name":null,"label":"alpha/winter","path":"/ws/alpha/winter"},
      {"kind":"standalone","env":null,"repo":null,"name":"winter-harness","label":"winter-harness","path":"/ws/winter-harness"}
    ]
  ]])

  MiniTest.expect.equality(#sample, 2)

  local first = sample[1]
  MiniTest.expect.equality(first.kind, "worktree")
  MiniTest.expect.equality(first.label, "alpha/winter")
  MiniTest.expect.equality(first.path, "/ws/alpha/winter")
  MiniTest.expect.equality(first.env, "alpha")
  MiniTest.expect.equality(first.repo, "winter")

  local second = sample[2]
  MiniTest.expect.equality(second.kind, "standalone")
  MiniTest.expect.equality(second.label, "winter-harness")
  MiniTest.expect.equality(second.path, "/ws/winter-harness")
  -- null becomes vim.NIL in Lua
  MiniTest.expect.equality(second.env, vim.NIL)
end

-- ---------------------------------------------------------------------------
-- session.session_file — pure string helper, no filesystem needed
-- ---------------------------------------------------------------------------

T["session.session_file produces a deterministic path under session_dir"] = function()
  local session = require("winter.session")

  local dir = "/home/user/.local/state/winter-nvim/sessions"
  local sf = session.session_file("/home/user/projects/winter-workspace/alpha/winter", dir)

  -- Must be a string under session_dir.
  MiniTest.expect.equality(type(sf), "string")
  MiniTest.expect.equality(sf:sub(1, #dir), dir)
  -- Must end with .vim.
  MiniTest.expect.equality(sf:sub(-4), ".vim")
end

T["session.session_file is deterministic (same input → same output)"] = function()
  local session = require("winter.session")

  local dir = "/tmp/sessions"
  local path = "/workspace/alpha/my-repo"

  local sf1 = session.session_file(path, dir)
  local sf2 = session.session_file(path, dir)
  MiniTest.expect.equality(sf1, sf2)
end

T["session.session_file varies with different paths"] = function()
  local session = require("winter.session")

  local dir = "/tmp/sessions"
  local sf_alpha = session.session_file("/ws/alpha/winter", dir)
  local sf_beta = session.session_file("/ws/beta/winter", dir)

  -- Different paths must produce different filenames.
  MiniTest.expect.equality(sf_alpha ~= sf_beta, true)
end

-- Regression: paths that slugify identically (every non-alphanumeric char →
-- "_") must still map to distinct session files. The appended path hash makes
-- the mapping injective; without it "/ws/a-b" and "/ws/a/b" would collide.
T["session.session_file disambiguates paths with the same slug"] = function()
  local session = require("winter.session")

  local dir = "/tmp/sessions"
  local sf_slash = session.session_file("/ws/a/b", dir)
  local sf_dash = session.session_file("/ws/a-b", dir)
  local sf_dot = session.session_file("/ws/a.b", dir)

  MiniTest.expect.equality(sf_slash ~= sf_dash, true)
  MiniTest.expect.equality(sf_slash ~= sf_dot, true)
  MiniTest.expect.equality(sf_dash ~= sf_dot, true)
end

-- ---------------------------------------------------------------------------
-- worktrees() — without snacks or winter CLI, notifies rather than crashes
-- ---------------------------------------------------------------------------

T["worktrees() notifies when not inside a winter workspace"] = function()
  local winter = require("winter")
  winter.setup()

  -- Point the buffer at a path that is definitely not a winter workspace.
  local notified = false
  local orig_notify = vim.notify
  vim.notify = function(msg, level, _opts)
    if level == vim.log.levels.WARN and msg:find("not inside a winter workspace") then
      notified = true
    end
  end

  -- Override find_root to always return nil for this test.
  local workspace = require("winter.workspace")
  local orig_find_root = workspace.find_root
  workspace.find_root = function(_)
    return nil
  end

  winter.worktrees()

  workspace.find_root = orig_find_root
  vim.notify = orig_notify
  MiniTest.expect.equality(notified, true)
end

-- open() deprecated alias forwards to worktrees()
T["open() alias notifies when not inside a winter workspace"] = function()
  local winter = require("winter")
  winter.setup()

  local notified = false
  local orig_notify = vim.notify
  vim.notify = function(msg, level, _opts)
    if level == vim.log.levels.WARN and msg:find("not inside a winter workspace") then
      notified = true
    end
  end

  local workspace = require("winter.workspace")
  local orig_find_root = workspace.find_root
  workspace.find_root = function(_)
    return nil
  end

  winter.open()

  workspace.find_root = orig_find_root
  vim.notify = orig_notify
  MiniTest.expect.equality(notified, true)
end

-- ---------------------------------------------------------------------------
-- config.validate — per-field vim.validate (nvim-0.11 non-deprecated form)
-- ---------------------------------------------------------------------------

T["config.validate accepts valid opts without error"] = function()
  local config = require("winter.config")
  -- Should not raise
  local ok, err = pcall(config.validate, {
    winter_cmd = "winter",
    winter_args = { "--winter=/some/path" },
    use_sessions = true,
    create_sessions = false,
    cd_command = "tcd",
    diff = { mode = "branch", drawer = false, yank_registers = { "+" } },
  })
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
end

T["config.validate rejects non-string winter_cmd"] = function()
  local config = require("winter.config")
  local ok, err = pcall(config.validate, { winter_cmd = 42 })
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
end

T["config.validate rejects non-table winter_args"] = function()
  local config = require("winter.config")
  local ok, err = pcall(config.validate, { winter_args = "bad" })
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
end

T["config.validate rejects invalid diff.mode"] = function()
  local config = require("winter.config")
  local ok, err = pcall(config.validate, { diff = { mode = "invalid" } })
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:find("diff.mode") ~= nil, true)
end

T["config.validate rejects non-boolean diff.drawer"] = function()
  local config = require("winter.config")
  local ok, err = pcall(config.validate, { diff = { drawer = "yes" } })
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
end

-- ---------------------------------------------------------------------------
-- diff.source_lines — resolves buffer rows to source line numbers via
-- b:delta_line_map. All tests use a hand-built vim.b[bufnr] fixture.
-- ---------------------------------------------------------------------------

T["diff.source_lines returns nil,nil when map is empty"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_line_map = {}

  local lo, hi = diff.source_lines(bufnr, 1, 3)
  MiniTest.expect.equality(lo, nil)
  MiniTest.expect.equality(hi, nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.source_lines returns new line number for a single added row"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Row 5 maps to new source line 42
  vim.b[bufnr].delta_line_map = { [5] = { new = 42 } }

  local lo, hi = diff.source_lines(bufnr, 5, 5)
  MiniTest.expect.equality(lo, 42)
  MiniTest.expect.equality(hi, 42)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.source_lines uses old when new is absent (removed line)"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Row 3 is a removed line — only old is set
  vim.b[bufnr].delta_line_map = { [3] = { old = 10 } }

  local lo, hi = diff.source_lines(bufnr, 3, 3)
  MiniTest.expect.equality(lo, 10)
  MiniTest.expect.equality(hi, 10)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.source_lines computes min/max over a multi-row range"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_line_map = {
    [2] = { new = 10 },
    [3] = { new = 11 },
    [4] = { new = 15 }, -- gap — still tracked
  }

  local lo, hi = diff.source_lines(bufnr, 2, 4)
  MiniTest.expect.equality(lo, 10)
  MiniTest.expect.equality(hi, 15)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---------------------------------------------------------------------------
-- diff.file_at — walks b:delta_artifacts to find the file path for a row
-- ---------------------------------------------------------------------------

T["diff.file_at returns nil when buffer has no artifacts"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_artifacts = {}

  MiniTest.expect.equality(diff.file_at(bufnr, 1), nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.file_at returns the path of the file title at or before the row"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- row_number is 0-based; file_at converts +1 to 1-based
  vim.b[bufnr].delta_artifacts = {
    { type = "title", row_number = 0, content = "alpha/winter/lua/foo.lua" },
    { type = "title", row_number = 9, content = "alpha/myrepo/src/bar.py" },
  }

  -- Row 1 is inside the first file (row_number 0 → buf row 1)
  MiniTest.expect.equality(diff.file_at(bufnr, 1), "alpha/winter/lua/foo.lua")
  -- Row 5 is also inside the first file
  MiniTest.expect.equality(diff.file_at(bufnr, 5), "alpha/winter/lua/foo.lua")
  -- Row 10 is at the second file title (row_number 9 → buf row 10)
  MiniTest.expect.equality(diff.file_at(bufnr, 10), "alpha/myrepo/src/bar.py")
  -- Row 20 is after the last title — still returns the last file
  MiniTest.expect.equality(diff.file_at(bufnr, 20), "alpha/myrepo/src/bar.py")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.file_at excludes 'Line N' sub-headers from file titles"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_artifacts = {
    { type = "title", row_number = 0, content = "alpha/winter/lua/foo.lua" },
    -- This is a multi-hunk sub-header — must NOT be treated as a file title
    { type = "title", row_number = 4, content = "Line 12" },
  }

  -- Row 5 (sub-header row) should still resolve to the real file title, not "Line 12"
  MiniTest.expect.equality(diff.file_at(bufnr, 5), "alpha/winter/lua/foo.lua")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---------------------------------------------------------------------------
-- diff.compute_nav — derives sorted file/hunk row lists from delta metadata
-- ---------------------------------------------------------------------------

T["diff.compute_nav returns empty lists when buffer has no metadata"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- No metadata set — should degrade gracefully to empty lists
  local files, hunks = diff.compute_nav(bufnr)
  MiniTest.expect.equality(files, {})
  MiniTest.expect.equality(hunks, {})

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.compute_nav extracts file rows from title artifacts"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_artifacts = {
    { type = "title", row_number = 0, content = "alpha/winter/foo.lua" },
    { type = "title", row_number = 19, content = "alpha/myrepo/bar.py" },
    -- A non-title artifact — must be ignored
    { type = "other", row_number = 5, content = "something" },
  }
  vim.b[bufnr].delta_diff_data_set = {}

  local files, hunks = diff.compute_nav(bufnr)
  MiniTest.expect.equality(files, { 1, 20 }) -- row_number + 1
  MiniTest.expect.equality(hunks, {})

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["diff.compute_nav extracts hunk rows, preferring the first changed line"] = function()
  local diff = require("winter.diff")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].delta_artifacts = {
    { type = "title", row_number = 0, content = "alpha/winter/foo.lua" },
  }
  vim.b[bufnr].delta_diff_data_set = {
    {
      hunks = {
        {
          lines = {
            -- First line is context — should be skipped
            { line_type = "context", formatted_diff_line_num = 2 },
            -- Second line is added — this should be the hunk row
            { line_type = "added", formatted_diff_line_num = 3 },
          },
        },
        {
          lines = {
            -- All context (no changed lines) — fall back to first line
            { line_type = "context", formatted_diff_line_num = 9 },
          },
        },
      },
    },
  }

  local _, hunks = diff.compute_nav(bufnr)
  -- First hunk: lands on added line (3 + 1 = 4)
  -- Second hunk: all context, falls back to first line (9 + 1 = 10)
  MiniTest.expect.equality(hunks, { 4, 10 })

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---------------------------------------------------------------------------
-- diff.open — async path via injected runner
-- The runner is injected as the 3rd argument to M.open. Because M.open wraps
-- the callback in vim.schedule(), we flush pending scheduled calls with
-- vim.wait() after the synchronous runner fires.
-- ---------------------------------------------------------------------------

T["diff.open passes correct argv to the runner (branch mode)"] = function()
  local diff = require("winter.diff")
  local cfg = vim.tbl_deep_extend("force", require("winter.config").defaults, {
    winter_cmd = "winter",
    winter_args = {},
  })

  -- Override workspace discovery so there is always a root
  local workspace = require("winter.workspace")
  local orig_from_context = workspace.find_root_from_context
  workspace.find_root_from_context = function()
    return "/fake/root"
  end

  local captured_argv = nil
  local fake_runner = function(argv, _cwd, on_exit)
    captured_argv = argv
    -- Return empty diff so open does not try to render
    on_exit({ code = 0, stdout = "", stderr = "" })
  end

  diff.open(cfg, { env = "gamma", mode = "branch" }, fake_runner)
  -- Flush vim.schedule callbacks
  vim.wait(100, function()
    return captured_argv ~= nil
  end, 10)

  workspace.find_root_from_context = orig_from_context

  MiniTest.expect.equality(type(captured_argv), "table")
  -- { "winter", "ws", "diff", "gamma", "--no-headers", "--branch" }
  MiniTest.expect.equality(captured_argv[1], "winter")
  MiniTest.expect.equality(captured_argv[2], "ws")
  MiniTest.expect.equality(captured_argv[3], "diff")
  MiniTest.expect.equality(captured_argv[4], "gamma")
  MiniTest.expect.equality(captured_argv[5], "--no-headers")
  MiniTest.expect.equality(captured_argv[6], "--branch")
end

T["diff.open threads winter_args into the runner argv"] = function()
  local diff = require("winter.diff")
  local cfg = vim.tbl_deep_extend("force", require("winter.config").defaults, {
    winter_cmd = "winter",
    winter_args = {},
  })

  local workspace = require("winter.workspace")
  local orig_from_context = workspace.find_root_from_context
  workspace.find_root_from_context = function()
    return "/fake/root"
  end

  local captured_argv = nil
  local fake_runner = function(argv, _cwd, on_exit)
    captured_argv = argv
    on_exit({ code = 0, stdout = "", stderr = "" })
  end

  diff.open(cfg, { env = "alpha", mode = "uncommitted", winter_args = { "--winter=/dev/path" } }, fake_runner)
  vim.wait(100, function()
    return captured_argv ~= nil
  end, 10)

  workspace.find_root_from_context = orig_from_context

  MiniTest.expect.equality(type(captured_argv), "table")
  -- --winter arg must come right after winter_cmd, before subcommand
  MiniTest.expect.equality(captured_argv[2], "--winter=/dev/path")
  MiniTest.expect.equality(captured_argv[3], "ws")
  MiniTest.expect.equality(captured_argv[4], "diff")
end

T["diff.open notifies error on CLI failure"] = function()
  local diff = require("winter.diff")
  local cfg = vim.tbl_deep_extend("force", require("winter.config").defaults, {
    winter_cmd = "winter",
    winter_args = {},
  })

  local workspace = require("winter.workspace")
  local orig_from_context = workspace.find_root_from_context
  workspace.find_root_from_context = function()
    return "/fake/root"
  end

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 1, stdout = "", stderr = "cli boom" })
  end

  local notified_msg = nil
  local orig_notify = vim.notify
  vim.notify = function(msg, _level, _opts)
    notified_msg = msg
  end

  diff.open(cfg, { env = "alpha", mode = "branch" }, fake_runner)
  vim.wait(200, function()
    return notified_msg ~= nil
  end, 10)

  workspace.find_root_from_context = orig_from_context
  vim.notify = orig_notify

  MiniTest.expect.equality(type(notified_msg), "string")
  MiniTest.expect.equality(notified_msg:find("cli boom") ~= nil, true)
end

T["diff.open notifies when diff is empty (no changes)"] = function()
  local diff = require("winter.diff")
  local cfg = vim.tbl_deep_extend("force", require("winter.config").defaults, {
    winter_cmd = "winter",
    winter_args = {},
  })

  local workspace = require("winter.workspace")
  local orig_from_context = workspace.find_root_from_context
  workspace.find_root_from_context = function()
    return "/fake/root"
  end

  local fake_runner = function(_argv, _cwd, on_exit)
    on_exit({ code = 0, stdout = "   ", stderr = "" })
  end

  local notified_msg = nil
  local orig_notify = vim.notify
  vim.notify = function(msg, _level, _opts)
    notified_msg = msg
  end

  diff.open(cfg, { env = "beta", mode = "uncommitted" }, fake_runner)
  vim.wait(200, function()
    return notified_msg ~= nil
  end, 10)

  workspace.find_root_from_context = orig_from_context
  vim.notify = orig_notify

  MiniTest.expect.equality(type(notified_msg), "string")
  MiniTest.expect.equality(notified_msg:find("no changes") ~= nil, true)
end

return T
