test:
	#!/usr/bin/env bash
	PLENARY_REF=74b06c6c75e4eeb3108ec01852001636d85a932b
	if ! test -d plenary.nvim; then
		git clone https://github.com/nvim-lua/plenary.nvim plenary.nvim
	fi
	git -C plenary.nvim checkout "$PLENARY_REF"
	nvim --headless --noplugin \
		-u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = './tests/minimal_init.lua' })"
