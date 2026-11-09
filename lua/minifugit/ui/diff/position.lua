local parser = require('minifugit.ui.diff.parser')

---@alias MiniFugitDiffSide 'left'|'right'

---@class MiniFugitDiffHunkPosition
---@field hunk_index integer
---@field side MiniFugitDiffSide
---@field offset integer

local M = {}

---@param hunks MiniFugitDiffHunk[]?
---@param index integer?
---@return MiniFugitDiffHunk?
function M.hunk_by_index(hunks, index)
    if index == nil then
        return nil
    end

    for _, hunk in ipairs(hunks or {}) do
        if hunk.index == index then
            return hunk
        end
    end

    return nil
end

---@param hunks MiniFugitDiffHunk[]?
---@param raw_row integer?
---@return MiniFugitDiffHunk?
local function hunk_at_raw_row(hunks, raw_row)
    if raw_row == nil then
        return nil
    end

    for _, hunk in ipairs(hunks or {}) do
        if raw_row >= hunk.raw_start_row and raw_row <= hunk.raw_end_row then
            return hunk
        end
    end

    return nil
end

---@param hunk MiniFugitDiffHunk
---@param line MiniFugitDiffLine?
---@return MiniFugitDiffSide
---@return integer
local function hunk_position_from_diff_line(hunk, line)
    if line == nil then
        return 'right', 0
    end

    if line.kind == 'removed' and line.old_number ~= nil then
        return 'left', math.max(0, line.old_number - hunk.old_start)
    end

    if line.new_number ~= nil then
        return 'right', math.max(0, line.new_number - hunk.new_start)
    end

    if line.old_number ~= nil then
        return 'left', math.max(0, line.old_number - hunk.old_start)
    end

    return 'right', 0
end

---@param raw_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@param raw_row integer?
---@return MiniFugitDiffHunkPosition?
function M.hunk_position_for_raw_row(raw_lines, hunks, raw_row)
    local hunk = hunk_at_raw_row(hunks, raw_row)

    if hunk == nil then
        return nil
    end

    local line = parser.line_at_raw_row(raw_lines, raw_row)
    local side, offset = hunk_position_from_diff_line(hunk, line)

    return { hunk_index = hunk.index, side = side, offset = offset }
end

---Worktree line of a row, whichever side highlights it: conflict rows count
---too, while removed parents and headers hold no worktree line.
---@param line MiniFugitDiffLine?
---@return integer?
local function surviving_new_number(line)
    if line == nil or line.kind == 'removed' then
        return nil
    end

    return line.new_number
end

---@param raw_lines string[]?
---@return MiniFugitDiffLine[]
---@return table<integer, MiniFugitDiffLine>
local function parsed_lines(raw_lines)
    local lines = parser.parse_lines(raw_lines or {})
    local by_raw_row = {}

    for _, line in ipairs(lines) do
        by_raw_row[line.raw_row] = line
    end

    return lines, by_raw_row
end

---@param by_raw_row table<integer, MiniFugitDiffLine>
---@param hunk MiniFugitDiffHunk
---@param raw_row integer
---@return integer?
local function nearest_surviving_new_number(by_raw_row, hunk, raw_row)
    for row = raw_row + 1, hunk.raw_end_row do
        local new_number = surviving_new_number(by_raw_row[row])

        if new_number ~= nil then
            return new_number
        end
    end

    for row = raw_row - 1, hunk.raw_start_row, -1 do
        local new_number = surviving_new_number(by_raw_row[row])

        if new_number ~= nil then
            return new_number
        end
    end

    return hunk.new_start
end

---@param by_raw_row table<integer, MiniFugitDiffLine>
---@param hunk MiniFugitDiffHunk
---@param line MiniFugitDiffLine
---@return integer?
local function source_line_for_diff_line(by_raw_row, hunk, line)
    if line.kind == 'hunk' then
        return line.new_number
    end

    if line.new_number ~= nil then
        return line.new_number
    end

    return nearest_surviving_new_number(by_raw_row, hunk, line.raw_row)
end

---@param raw_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@param raw_row integer?
---@return integer?
function M.source_line_for_stacked_row(raw_lines, hunks, raw_row)
    if raw_row == nil then
        return nil
    end

    local _, by_raw_row = parsed_lines(raw_lines)
    local line = by_raw_row[raw_row]

    if line == nil then
        return nil
    end

    local hunk = hunk_at_raw_row(hunks, raw_row)

    if hunk == nil then
        return line.new_number
    end

    return source_line_for_diff_line(by_raw_row, hunk, line)
end

---@param raw_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@param old_line integer
---@return integer
function M.old_line_to_new_line(raw_lines, hunks, old_line)
    local lines, by_raw_row = parsed_lines(raw_lines)
    local delta = 0

    for _, hunk in ipairs(hunks or {}) do
        if old_line < hunk.old_start then
            return old_line + delta
        end

        if hunk.old_count > 0 and old_line <= hunk.old_end then
            for _, line in ipairs(lines) do
                if
                    line.raw_row >= hunk.raw_start_row
                    and line.raw_row <= hunk.raw_end_row
                    and line.kind ~= 'hunk'
                    and line.old_number == old_line
                then
                    if line.new_number ~= nil then
                        return line.new_number
                    end

                    return nearest_surviving_new_number(
                        by_raw_row,
                        hunk,
                        line.raw_row
                    ) or hunk.new_start
                end
            end

            return nearest_surviving_new_number(
                by_raw_row,
                hunk,
                hunk.raw_header_row
            ) or hunk.new_start
        end

        if hunk.old_count == 0 and old_line <= hunk.old_start then
            return old_line + delta
        end

        delta = delta + hunk.new_count - hunk.old_count
    end

    return old_line + delta
end

---@param raw_lines string[]?
---@param raw_rows integer[]?
---@param hunk MiniFugitDiffHunk
---@param side MiniFugitDiffSide
---@param offset integer
---@return integer?
function M.stacked_row_for_hunk_position(
    raw_lines,
    raw_rows,
    hunk,
    side,
    offset
)
    if raw_rows == nil then
        return hunk.stacked_row
    end

    local target = side == 'left' and hunk.old_start + offset
        or hunk.new_start + offset

    -- Parse once and index by raw_row to avoid an O(n) re-parse on every
    -- iteration of the loop below (which would make cursor restores O(n²)).
    local _, parsed_by_row = parsed_lines(raw_lines)

    for row, raw_row in ipairs(raw_rows) do
        if raw_row >= hunk.raw_start_row and raw_row <= hunk.raw_end_row then
            local line = parsed_by_row[raw_row]
            local line_number

            if line ~= nil then
                if side == 'left' then
                    line_number = line.old_number
                else
                    line_number = line.new_number
                end
            end

            if line_number == target then
                return row
            end
        end
    end

    return hunk.stacked_row
end

return M
