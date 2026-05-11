## About the plugin

This is a Neovim plugin, written in Lua, that provides a lightweight Git status UI inspired by fugitive.nvim.

## Working on a new issue

- Create a new branch for the issue following conventional naming (e.g. feat/new-feat, fix/fixing-this, etc.).
- Plan the implementation regarding the issue motivation.
- Follow the code structure:
    - Create a new file if the implementation does not fit in any of the current files or if splitting into more files is necessary because the code handles a very specific functionality.
    - Do not over-split code. Long files are okay. Long files that handle more functionalities than what it should, no.
- Write the code.
- Format the code.
- Do not commit/push until indicated.

## Formatting

Open Neovim with `v` from the root directory and run `:!stylua .` from there.

---

For coding conventions, structure, and project practices, see `docs/CONVENTIONS.md`.
