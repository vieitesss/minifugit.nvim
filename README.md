# minifugit.nvim

A lightweight Git status UI for Neovim, inspired by
[vim-fugitive](https://github.com/tpope/vim-fugitive).

minifugit.nvim focuses on a compact status window for everyday Git operations
without leaving Neovim.

## Features

- Open a Git status window with `:MinifugitStatus`.
- View your files' status
- Stage and unstage files from the status window (visual mode as well).
- Preview diffs for the entry under the cursor.
- Discard unstaged changes or delete untracked paths, with confirmation by
  default.
- Create commits.
- Run `:checkhealth minifugit` to verify Neovim and Git requirements.

## Requirements

- Neovim 0.10+
- `git` executable on `PATH`

## Configuration

### vim.pack

```lua
vim.pack.add({
    'https://github.com/vieitesss/minifugit.nvim',
})
```

### lazy.nvim

```lua
{
    'vieitesss/minifugit.nvim',
    cmd = { 'MinifugitStatus' },
}
```

## Usage

Open the status window:

```vim
:MinifugitStatus
```

```lua
require('minifugit').status()
```

Default status-window mappings:

| Mode | Key | Action |
| --- | --- | --- |
| n | `<CR>` / `o` | Open entry |
| n | `=` | Preview diff |
| n | `r` | Refresh status |
| n,v | `s` | Stage/Unstage entry |
| n,v | `u` | Unstage entry |
| n | `S` | Stage all entries |
| n | `U` | Unstage all entries |
| n | `d` | Discard entry with confirmation |
| n | `D` | Discard entry without confirmation |
| n | `c` | Commit staged changes |
| n | `?` | Toggle help |

