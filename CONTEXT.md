# Project Context

## Purpose
- Neovim Lua plugin providing a lightweight Git status buffer and diff previews.

## Vocabulary
- **Status buffer**: Plugin-owned text buffer listing Git state and actions.
- **Diff buffer**: Plugin-owned text buffer showing staged/unstaged/commit diffs.
- **Related buffer**: Real user file buffer opened from minifugit.
- **Target window**: The status window (or a preview split derived from it) that a diff preview opens into and restores on close.
- **Stacked layout**: Single-window diff preview showing one combined diff in the target window.
- **Split layout**: Two-window diff preview showing the two sides of a diff side by side.

## Commands
- Test: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"`
- Format: `stylua lua tests plugin`
- Health: `:checkhealth minifugit`

## Pitfalls
- Never set global editor or buffer options from plugin buffer setup; scope options to plugin-owned buffers/windows.
- Diff previews reuse the status target window when available, but must restore that window's buffer/options on close.
- Refreshing or toggling diff previews should preserve the caller's current window unless the user explicitly requested preview focus.
- Treat plugin buffers as text buffers with local filetypes and buffer-local mappings, not opaque UI widgets.
- Use temp Git repositories in tests; do not operate on real repositories.

## ADRs
Design decisions live in [docs/adr/](docs/adr/).
