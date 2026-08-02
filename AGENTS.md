## About the plugin

This is a Neovim plugin, written in Lua, that provides a lightweight Git status UI inspired by fugitive.nvim.

## Tests

- Use `plenary.nvim` for creating/managing tests.
- Get information about how to create tests from this URL: https://raw.githubusercontent.com/nvim-lua/plenary.nvim/refs/heads/master/TESTS_README.md
- There should be:
    - Functional tests: only for functions that are part of each module's API. Do NOT create tests for local functions
    - UI tests: check whether windows are created/deleted correctly, ensuring the UI is shown as expected during and after the execution of the plugin.
- Use temporary directories as git repositories for testing, do not use real repositories.

## Releases

- When creating a new release, do not create a new branch, do it from main.
- If you are not in the main branch, ask the user for confirmation.

## Formatting

Use `stylua` for formatting.

---

For coding conventions, structure, and project practices, see `docs/CONVENTIONS.md`.
