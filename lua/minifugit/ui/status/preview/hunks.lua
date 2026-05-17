require('minifugit.ui.status.preview.types')

local common = require('minifugit.ui.status.common')
local diff_position = require('minifugit.ui.diff.position')
local git = require('minifugit.git')
local selection = require('minifugit.ui.status.selection')
local preview_cursor = require('minifugit.ui.status.preview.cursor')

local M = {}

---@param self GitStatusWindow
---@param hunk MiniFugitDiffHunk
---@return string[]?
function M.hunk_patch(self, hunk)
    local lines = self.diff_raw_lines

    if lines == nil then
        common.notify_warn('Diff preview is not open')
        return nil
    end

    local hunk_start = hunk.raw_header_row
    local file_start = hunk_start

    while
        file_start > 1 and not vim.startswith(lines[file_start] or '', 'diff ')
    do
        file_start = file_start - 1
    end

    local header_stop = hunk_start - 1

    for row = file_start, hunk_start - 1 do
        if vim.startswith(lines[row] or '', '@@') then
            header_stop = row - 1
            break
        end
    end

    local patch = {}

    for row = file_start, header_stop do
        table.insert(patch, lines[row])
    end

    for row = hunk_start, hunk.raw_end_row do
        table.insert(patch, lines[row])
    end

    return patch
end

---@param self GitStatusWindow
---@param callbacks MiniFugitPreviewActions
---@return string[]?
function M.current_hunk_patch(self, callbacks)
    if not callbacks.has_open_diff() or self.diff_raw_lines == nil then
        common.notify_warn('Diff preview is not open')
        return nil
    end

    local position = preview_cursor.current_hunk_position(self)

    if position == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    local hunk =
        diff_position.hunk_by_index(self.diff_hunks, position.hunk_index)

    if hunk == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    return M.hunk_patch(self, hunk)
end

---@param self GitStatusWindow
---@param kind 'stage'|'unstage'|'discard'
---@param callbacks MiniFugitPreviewActions
---@return boolean
function M.apply_current_hunk(self, kind, callbacks)
    local section = self.diff_section

    if kind == 'stage' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to stage')
        return false
    end

    if kind == 'unstage' and section ~= 'staged' then
        common.notify_warn('No staged hunk to unstage')
        return false
    end

    if kind == 'discard' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to discard')
        return false
    end

    local patch = M.current_hunk_patch(self, callbacks)

    if patch == nil then
        return false
    end

    if
        kind == 'discard'
        and vim.fn.confirm('Discard current hunk?', '&Discard\n&Cancel', 2)
            ~= 1
    then
        return false
    end

    local cursor_state = selection.capture_cursor_state(self)
    local ok, err = git.apply_hunk(patch, kind)

    if not ok then
        common.notify_error(err, 'Git hunk action failed')
        return false
    end

    callbacks.refresh(cursor_state)

    if callbacks.has_open_diff() then
        callbacks.focus_open_diff()
    end

    return true
end

return M
