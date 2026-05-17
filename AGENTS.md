## About the plugin

This is a Neovim plugin, written in Lua, that provides a lightweight Git status UI inspired by fugitive.nvim.

## Working on a new issue

- Create a new branch for the issue following conventional naming (e.g. feat/new-feat, fix/fixing-this, etc.).
- Do not change to a new branch unless you are already in the main branch. If you are not in the main branch, ask what to do about the branch before anything else.
- Plan the implementation regarding the issue motivation.
- Follow the code structure:
    - Create a new file if the implementation does not fit in any of the current files or if splitting into more files is necessary because the code handles a very specific functionality.
    - Do not over-split code. Long files are okay. Long files that handle more functionalities than what it should, no.
- Write the code.
- Format the code.
- Do not commit/push until indicated.

## Tests

- Use `plenary.nvim` for creating/managing tests.
- Get information about how to create tests from this URL: https://raw.githubusercontent.com/nvim-lua/plenary.nvim/refs/heads/master/TESTS_README.md
- There should be:
    - Functional tests: only for functions that are part of each module's API. Do NOT create tests for local functions
    - UI tests: check whether windows are created/deleted correctly, ensuring the UI is shown as expected during and after the execution of the plugin.
- Use temporal directories as git repositories for testing, do not use real repositories.

## Formatting

Use `stylua` for formatting.

---

For coding conventions, structure, and project practices, see `docs/CONVENTIONS.md`.
