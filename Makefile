.PHONY: test lint fmt deps

# Download test dependencies (mini.nvim)
deps:
	@mkdir -p .tests
	@if [ ! -d .tests/mini.nvim ]; then \
		git clone --filter=blob:none --branch=stable \
			https://github.com/echasnovski/mini.nvim .tests/mini.nvim; \
	fi

# Run the mini.test suite
test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests', '**/*_spec.lua', true, true) end }, execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })" \
		+qa

# Check formatting (stylua) and linting (luacheck)
lint:
	@if command -v stylua >/dev/null 2>&1; then \
		stylua --check lua/ plugin/ tests/; \
	else \
		echo "stylua not found; skipping format check"; \
	fi
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck lua/ plugin/ tests/; \
	else \
		echo "luacheck not found; skipping lint"; \
	fi

# Auto-format with stylua
fmt:
	@if command -v stylua >/dev/null 2>&1; then \
		stylua lua/ plugin/ tests/; \
	else \
		echo "stylua not found; cannot format"; \
	fi
