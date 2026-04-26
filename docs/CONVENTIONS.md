# Conventions

## Project shape

- Keep the public `minifugit` entrypoints thin and move behavior into focused modules.
- Separate data collection, formatting, and UI rendering. A good default flow is: Git/process output -> parsed data -> renderable lines -> buffer/window updates.
- Prefer small single-purpose modules over catch-all utility files.
- Model stateful UI pieces as table-based objects with `__index`; keep pure transforms and parsers as local helper functions or stateless modules.

## Lua style

- Follow the repo's Stylua rules: 4 spaces, 80-column width, Unix line endings, always-parenthesized calls, and a preference for single quotes.
- Use LuaLS annotations for non-trivial modules and APIs: `---@class`, `---@field`, `---@alias`, `---@param`, and `---@return`.
- Default to `local` functions and locals; only export what is part of a module API.
- Prefer early returns and explicit `nil` handling over deeply nested conditionals.
- Validate option tables and constructor inputs with `vim.validate`.

## Neovim API usage

- Prefer the Lua Neovim API (`vim.api`, `vim.fn`, `vim.system`) over stringly Vimscript-style code when a Lua API exists.
- Centralize shell/process interactions instead of spawning ad hoc commands from multiple places. Git access should go through shared helpers.
- Keep render steps side-effect free until the final buffer/window apply step.
- Reuse existing editor highlight groups first, then provide sensible fallback colors.

## Good practices

- Keep parsing and formatting logic deterministic and easy to inspect from plain strings/tables.
- Use logging through `minifugit.log` for plugin-internal diagnostics; reserve direct user-facing output for health checks or truly actionable failures.
- Preserve compatibility assumptions already present in the project: Neovim 0.10+ and a working `git` executable.
- There is no formal automated test suite yet, so changes should at least be formatted and manually smoke-tested in Neovim.
- For UI or git-status changes, validate against realistic repository states such as modified, untracked, renamed, and conflicted files when relevant.
- When creating commits, match the existing conventional-commit style seen in history (`feat:`, `fix:`, `refactor:`, `style:`, `chore:`).
