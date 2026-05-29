-- luacheck configuration for winter.nvim

-- Neovim global
globals = { "vim" }

-- Test runner globals (mini.test)
read_globals = {
  "MiniTest",
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
}

-- Allow longer lines (stylua enforces column_width = 120)
max_line_length = 120

-- Ignore warnings about unused arguments that start with _
unused_args = false

-- Ignore line-length warning (W0631) — stylua handles formatting
ignore = { "631" }

files["tests/**/*.lua"] = {
  globals = { "MiniTest", "describe", "it", "before_each", "after_each", "assert" },
}
