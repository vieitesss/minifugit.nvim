# Project Context

## Purpose
- Neovim Lua plugin providing a lightweight Git status buffer and diff previews.

## Vocabulary
- **Status buffer**: Plugin-owned text buffer listing Git state and actions.
- **Diff buffer**: Plugin-owned text buffer showing staged/unstaged/commit diffs.
- **Related buffer**: Real user file buffer opened from minifugit.

## Commands
- Test: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"`
- Format: `stylua lua tests plugin`
- Health: `:checkhealth minifugit`

## Pitfalls
- Never set global editor or buffer options from plugin buffer setup; scope options to plugin-owned buffers/windows.
- Diff previews may temporarily occupy the selected normal target window; restore its previous buffer/options when the preview closes.
- Treat plugin buffers as text buffers with local filetypes and buffer-local mappings, not opaque UI widgets.
- Use temp Git repositories in tests; do not operate on real repositories.

## ADRs
Design decisions live in [docs/adr/](docs/adr/).
