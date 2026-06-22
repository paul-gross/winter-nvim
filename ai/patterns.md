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

When an optional dependency is absent, the plugin degrades to a reduced capability rather than raising an error.

- Missing codediff renderer → `load_codediff()` notifies with ERROR and returns `nil`. The caller returns early; no crash.
- `health.lua` probes the codediff API at `:checkhealth` time so mismatches are surfaced before the user opens a diff.

## feature module shape

Each integration lives in `lua/winter/<feature>.lua` and follows:

- `M.open(cfg, opts, runner?)` — the primary entry point, takes the plugin config and an options table. The optional `runner` argument is the injected CLI runner for tests.
- Pure helpers (arg builders, parsers) are exposed directly on `M` so they can be unit-tested without touching the UI. Examples: `diff.build_specs`, `diff.build_roots`.
- Module-level state is stored in local variables (e.g. `_last_status` in dashboard.lua for status caching); buffer-local state goes in `vim.b[bufnr][STATE_KEY]`.
- Each feature fires a namespaced `User Winter<Feature>*` autocmd after render so callers can attach keymaps or react without the plugin forcing any. Actual events: `WinterDiffOpened`, `WinterDashboardOpened`, `WinterDashboardRefreshed`, `WinterDashboardSelectionChanged`.

## root discovery

All feature modules share `workspace.find_root_from_context()`:

1. Tries the current buffer's file directory (`nvim_buf_get_name(0)` → `fnamemodify(:p:h)`).
2. Falls back to `vim.fn.getcwd()` for unnamed / scratch buffers.

The root is the first ancestor directory containing a `.winter/` directory. This matches the winter CLI's own convention — no `tools/winter-cli/` or `config.toml` required.

## CLI contract

The dashboard and its diff actions are coupled to the `winter ws status --json` output at `schema_version: 1`. The specific fields consumed are:

| Field | Used for |
|---|---|
| `wt.main_branch` | gate for cyan/orange tracking markers (diverged vs upstream) |
| `wt.upstream` | same gate — compared against `"origin/" .. main_branch` |
| `wt.tracking_ahead` / `wt.tracking_behind` | divergence indicator `[+A,-B]` |
| `wt.tracking_ref_present` | unborn-upstream indicator `[+]` |
| `env.extensions` | badge values rendered in `WinterDashBadge` |
| `status.dashboard.resolved_layout` | layout orientation (`"repos-as-rows"` or future values) |

See `workspace:/ai/winter-cli/usage/ws/status.md` for the full `ws status --json` wire contract. When the CLI schema changes, re-verify these field paths before shipping.
