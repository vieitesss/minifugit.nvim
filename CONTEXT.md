# minifugit.nvim Context

minifugit.nvim is a lightweight Neovim Git interface centered on status inspection and diff review.

## Language

**Status Buffer**:
A plugin-owned Neovim buffer that presents the current Git repository state.
_Avoid_: Git panel, status pane, status view

**Diff Buffer**:
A plugin-owned Neovim buffer that presents Git diff content for review.
_Avoid_: Diff pane, preview buffer, diff view

**Related Buffer**:
A user file buffer opened from minifugit because it corresponds to a Git status entry or diff location.
_Avoid_: Source buffer, target buffer, file pane
