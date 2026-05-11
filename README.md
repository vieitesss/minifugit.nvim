# minifugit.nvim

A lightweight Git status UI for Neovim, inspired by
[vim-fugitive](https://github.com/tpope/vim-fugitive).


minifugit.nvim focuses on a compact status window for everyday Git operations
without leaving Neovim.

## Features

- Open a Git status window with `:MinifugitStatus`.
- View your files' status.
- Discard unstaged changes or delete untracked paths, with confirmation by
  default.
- Stage and unstage files from the status window (visual mode as well).
- Preview diffs for the entry under the cursor.
- Stage and unstage hunks from the diff window.
- Create commits.
- Animated loading spinner while pushing your commits.
- View unpushed commits in the status window.
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

### Options

```lua
-- Returns Minifugit object
require('minifugit').setup({
    preview = {
        -- Start diff previews with wrapping disabled.
        wrap = false,

        -- Show old/new line numbers in diff previews.
        show_line_numbers = true,

        -- Show git diff metadata rows such as `diff --git`, `index`, `---`,
        -- and `+++`.
        show_metadata = true,

        -- Diff preview layout: 'stacked', 'split', or 'auto'.
        diff_layout = 'stacked',

        -- Editor width where 'auto' switches from stacked to split.
        diff_auto_threshold = 120,
    },
    status = {
        -- Fraction of the editor width used by the status window.
        width = 0.4,

        -- Minimum status window width in columns.
        min_width = 20,
    },
})
```

Diff-preview mappings can toggle `preview.wrap`, `preview.show_line_numbers`,
`preview.show_metadata`, and the diff layout at runtime for the current status
session.

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
| n | `q` | Close status window |
| n | `/` | Filter entries |
| n | `<BS>` | Clear filter |
| n | `r` | Refresh status |
| n,v | `s` | Stage/Unstage entry |
| n,v | `u` | Unstage entry |
| n | `S` | Stage all entries |
| n | `U` | Unstage all entries |
| n | `d` | Discard entry with confirmation |
| n | `D` | Discard entry without confirmation |
| n | `c` | Commit staged changes |
| n | `p` | Push unpushed commits |
| n | `t` | Toggle stacked/split diff layout |
| n | `?` | Toggle help |

Default diff-preview mappings:

| Mode | Key | Action |
| --- | --- | --- |
| n | `q` | Close diff preview |
| n | `[h` / `]h` | Jump to previous/next hunk |
| n | `s` | Stage current unstaged hunk *(stacked only)* |
| n | `u` | Unstage current staged hunk *(stacked only)* |
| n | `d` | Discard current unstaged hunk with confirmation *(stacked only)* |
| n | `w` | Toggle wrap |
| n | `l` | Toggle line numbers |
| n | `m` | Toggle metadata rows *(stacked only)* |
| n | `t` | Toggle stacked/split layout |

