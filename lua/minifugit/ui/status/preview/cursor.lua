local common = require('minifugit.ui.status.common')
local diff_position = require('minifugit.ui.diff.position')

local M = {}

---@class MiniFugitDiffCursor
---@field layout 'stacked'|'split'
---@field row integer
---@field side MiniFugitDiffSide?

---@param self DiffPreview
---@return MiniFugitDiffCursor?
function M.current_diff_cursor(self)
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)
    local row = vim.api.nvim_win_get_cursor(current_win)[1]

    if self.stacked.buf ~= nil and current_buf == self.stacked.buf.id then
        return { layout = 'stacked', row = row }
    end

    if self.left.buf ~= nil and current_buf == self.left.buf.id then
        return { layout = 'split', side = 'left', row = row }
    end

    if self.right.buf ~= nil and current_buf == self.right.buf.id then
        return { layout = 'split', side = 'right', row = row }
    end

    return nil
end

---For split diff, translate a buffer row to the worktree (new) line number
---using alignment row metadata.
---@param rows MiniFugitSplitRow[]
---@param side MiniFugitDiffSide
---@param buf_row integer
---@param raw_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@return integer?
local function source_line_from_split_row(rows, side, buf_row, raw_lines, hunks)
    local meta = rows[buf_row]

    if meta == nil or meta.kind == 'filler' or meta.kind == 'separator' then
        return nil
    end

    if side == 'left' then
        if meta.old_lnum == nil then
            return nil
        end

        return diff_position.old_line_to_new_line(
            raw_lines,
            hunks,
            meta.old_lnum
        )
    end

    return meta.new_lnum
end

---For split diff, translate a buffer row to a hunk position using alignment
---row metadata.
---@param rows MiniFugitSplitRow[]
---@param side MiniFugitDiffSide
---@param buf_row integer
---@return MiniFugitDiffHunkPosition?
local function hunk_position_from_split_row(rows, side, buf_row)
    local meta = rows[buf_row]

    if meta == nil or meta.hunk_index == nil then
        return nil
    end

    return { hunk_index = meta.hunk_index, side = side, offset = 0 }
end

---For split diff, find the buffer row for a hunk position using alignment row
---metadata.
---@param rows MiniFugitSplitRow[]
---@param side MiniFugitDiffSide
---@param position MiniFugitDiffHunkPosition
---@return integer?
local function buffer_row_for_hunk_position(rows, side, position)
    for buf_row, meta in ipairs(rows) do
        if
            meta.hunk_index == position.hunk_index
            and meta.kind ~= 'filler'
            and meta.kind ~= 'separator'
        then
            return buf_row
        end
    end

    for buf_row, meta in ipairs(rows) do
        if meta.hunk_index == position.hunk_index then
            return buf_row
        end
    end

    return nil
end

---@param self DiffPreview
---@return MiniFugitDiffSourcePosition?
function M.current_source_position(self)
    local entry = self.context_entry

    if entry == nil then
        return nil
    end

    local cursor = M.current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    local line_number

    if cursor.layout == 'stacked' then
        local raw_row = self.raw_rows and self.raw_rows[cursor.row]
        line_number = diff_position.source_line_for_stacked_row(
            self.raw_lines,
            self.hunks,
            raw_row
        )
    elseif cursor.side ~= nil then
        local rows = cursor.side == 'left' and self.left_rows or self.right_rows

        if rows then
            line_number = source_line_from_split_row(
                rows,
                cursor.side,
                cursor.row,
                self.raw_lines,
                self.hunks
            )
        end
    end

    if line_number == nil then
        return nil
    end

    return { path = entry.path, line = math.max(line_number, 1) }
end

---@param self DiffPreview
---@return MiniFugitDiffHunkPosition?
function M.current_hunk_position(self)
    local cursor = M.current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    if cursor.layout == 'stacked' then
        local raw_row = self.raw_rows and self.raw_rows[cursor.row]

        return diff_position.hunk_position_for_raw_row(
            self.raw_lines,
            self.hunks,
            raw_row
        )
    end

    if cursor.side == nil then
        return nil
    end

    local rows = cursor.side == 'left' and self.left_rows or self.right_rows

    if rows then
        return hunk_position_from_split_row(rows, cursor.side, cursor.row)
    end

    return nil
end

---@param win number
---@param row integer?
function M.set_cursor_row(win, row)
    if row == nil then
        return
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
    local clamped = math.min(math.max(row, 1), line_count)

    pcall(vim.api.nvim_win_set_cursor, win, { clamped, 0 })
end

---@param self DiffPreview
---@param position MiniFugitDiffHunkPosition?
function M.restore_hunk_position(self, position)
    if position == nil then
        return
    end

    local hunk = diff_position.hunk_by_index(self.hunks, position.hunk_index)

    if hunk == nil then
        return
    end

    if common.is_valid_win(self.stacked.win) then
        local row = diff_position.stacked_row_for_hunk_position(
            self.raw_lines,
            self.raw_rows,
            hunk,
            position.side,
            position.offset
        )

        local win = assert(self.stacked.win)
        M.set_cursor_row(win, row)

        return
    end

    local rows = position.side == 'left' and self.left_rows or self.right_rows

    local row = rows
        and buffer_row_for_hunk_position(rows, position.side, position)

    if row == nil then
        return
    end

    local win = position.side == 'left' and self.left.win or self.right.win

    if common.is_valid_win(win) then
        win = assert(win)
        M.set_cursor_row(win, row)

        local paired = position.side == 'left' and self.right.win
            or self.left.win

        if common.is_valid_win(paired) then
            M.set_cursor_row(paired, row)
        end
    end
end

return M
