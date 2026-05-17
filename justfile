test:
	#!/usr/bin/env bash
	test -d plenary.nvim || git clone --depth 1 https://github.com/nvim-lua/plenary.nvim plenary.nvim
	nvim --headless --noplugin \
		-u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/functional', { minimal_init = './tests/minimal_init.lua' })"
