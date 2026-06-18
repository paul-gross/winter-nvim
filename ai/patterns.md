# winter.nvim — implicit plugin patterns

Short reference for the conventions that every feature module in this plugin follows. Read this before adding a new integration (diff viewer, dashboard, etc.).

## async-via-cli-seam

All winter CLI calls go through `winter.cli.run_async`. This function:

1. Builds the argv with `build_argv(winter_cmd, global_args, subcommand_args)`, enforcing the ordering `{ winter_cmd, <global_args...>, <subcommand_args...> }`.
2. Invokes `vim.system(argv, { cwd = root, text = true }, on_exit)` off the UI thread.
3. Delivers the raw `{ code, stdout, stderr }` result (or an error string) to the caller's `on_done` callback.

Feature modules do **not** call `vim.system` directly. Callers wrap UI work in `vim.schedule()` so it runs on the main thread.

`run_async` accepts an optional `runner` argument (the 6th parameter) that replaces `vim.system`. Inject a synchronous fake runner in tests to drive the async wiring deterministically — no real process, no network, no timing.

## pcall-wrap-Ex-commands

Every `:cmd` call that touches user buffers, windows, or state is wrapped in `pcall`. Examples: `pcall(vim.fn.winrestview, view)`, `pcall(vim.api.nvim_buf_set_name, ...)`, `pcall(vim.cmd, "lclose")`. This prevents one bad call from raising an uncaught error and aborting the rest of the render pipeline.

The pattern is: try the operation, silently ignore a failure or emit a WARN notification, continue. Do not re-raise.

## degrade-don't-error

When an optional dependency (delta renderer) or optional metadata (delta schema fields) is absent, the plugin degrades to a reduced capability rather than raising an error.

- Missing delta renderer → `load_delta()` notifies with ERROR and returns `nil`. The caller returns early; no crash.
- Missing delta metadata (empty `b:delta_artifacts` / `b:delta_diff_data_set`) → navigation and yank return no-ops. A one-time WARN fires the first time a non-empty diff has empty metadata (global flag `vim.g.winter_diff_schema_warn` prevents spam).
- `health.lua` probes the delta API at `:checkhealth` time so schema mismatches are surfaced before the user opens a diff.

## feature module shape

Each integration lives in `lua/winter/<feature>.lua` and follows:

- `M.open(cfg, opts, runner?)` — the primary entry point, takes the plugin config and an options table. The optional `runner` argument is the injected CLI runner for tests.
- Pure helpers (arg builders, formatters, parsers) are exposed directly on `M` so they can be unit-tested without touching the UI. Examples: `diff.diff_args`, `diff.default_format`, `diff.source_lines`, `diff.file_at`, `diff.compute_nav`.
- Buffer-local state is stored in `vim.b[bufnr][STATE_KEY]` where `STATE_KEY` is a module-local string constant (e.g. `"winter_diff"`).
- A `User WinterFeatureOpened` autocmd fires after render so callers can attach buffer-local keymaps without the plugin forcing any.

## root discovery

Both the worktrees and diff features share `workspace.find_root_from_context()`:

1. Tries the current buffer's file directory (`nvim_buf_get_name(0)` → `fnamemodify(:p:h)`).
2. Falls back to `vim.fn.getcwd()` for unnamed / scratch buffers.

The root is the first ancestor directory containing a `.winter/` directory. This matches the winter CLI's own convention — no `tools/winter-cli/` or `config.toml` required.
