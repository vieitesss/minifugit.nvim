plenary_ref := "74b06c6c75e4eeb3108ec01852001636d85a932b"
plenary_url := "https://github.com/nvim-lua/plenary.nvim"

_default:
	just -l

test:
	#!/usr/bin/env bash
	plenary_path="{{ justfile_directory() }}/plenary.nvim"

	if ! test -d "${plenary_path}"; then
		git clone {{ plenary_url }} "${plenary_path}"
	fi

	git -C "${plenary_path}" checkout "{{ plenary_ref }}"

	minimal_init="{{ justfile_directory() }}/tests/minimal_init.lua"
	nvim --headless --noplugin \
		-u "${minimal_init}" \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '${minimal_init}' })"
