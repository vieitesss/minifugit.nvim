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

---@param hunk MiniFugitDiffHunk
---@param side MiniFugitDiffSide
---@param row integer
---@return integer
local function hunk_offset_for_split_row(hunk, side, row)
    local start = side == 'left' and hunk.old_start or hunk.new_start
    local count = side == 'left' and hunk.old_count or hunk.new_count

    if count <= 0 then
        return 0
    end

    return math.min(math.max(row - start, 0), count - 1)
end

---@param hunks MiniFugitDiffHunk[]?
---@param side MiniFugitDiffSide
---@param row integer
---@return MiniFugitDiffHunk?
---@return integer
local function hunk_at_split_row(hunks, side, row)
    for _, hunk in ipairs(hunks or {}) do
        local start = side == 'left' and hunk.old_start or hunk.new_start
        local count = side == 'left' and hunk.old_count or hunk.new_count
        local stop = side == 'left' and hunk.old_end or hunk.new_end

        if count > 0 and row >= start and row <= stop then
            return hunk, hunk_offset_for_split_row(hunk, side, row)
        end

        -- count == 0 means a pure insertion or pure deletion; Vim's
        -- diff-filler may anchor the cursor at `start` or `start - 1` on the
        -- empty side.
        if count == 0 and (row == start or row == start - 1) then
            return hunk, 0
        end
    end

    return nil, 0
end

---@param hunks MiniFugitDiffHunk[]?
---@param side MiniFugitDiffSide
---@param row integer
---@return MiniFugitDiffHunkPosition?
function M.hunk_position_for_split_row(hunks, side, row)
    local hunk, offset = hunk_at_split_row(hunks, side, row)

    if hunk == nil then
        return nil
    end

    return { hunk_index = hunk.index, side = side, offset = offset }
end

---@param line MiniFugitDiffLine?
---@return integer?
local function surviving_new_number(line)
    if line == nil then
        return nil
    end

    if line.kind == 'context' or line.kind == 'added' then
        return line.new_number
    end

    return nil
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

---@param hunks MiniFugitDiffHunk[]?
---@param old_line integer
---@return integer
---@param hunks MiniFugitDiffHunk[]?
---@param old_line integer
---@return integer
function M.old_line_to_new_line(hunks, old_line)
    local delta = 0

    for _, hunk in ipairs(hunks or {}) do
        if old_line < hunk.old_start then
            return old_line + delta
        end

        if hunk.old_count > 0 and old_line <= hunk.old_end then
            return hunk.new_start
        end

        delta = delta + hunk.new_count - hunk.old_count
    end

    return old_line + delta
end

---@param raw_lines string[]?
---@param hunk MiniFugitDiffHunk
---@param offset integer
---@return integer?
local function source_line_for_left_hunk(raw_lines, hunk, offset)
    local lines, by_raw_row = parsed_lines(raw_lines)

    if hunk.old_count <= 0 then
        return nearest_surviving_new_number(
            by_raw_row,
            hunk,
            hunk.raw_header_row
        )
    end

    local old_number = hunk.old_start + offset

    for _, line in ipairs(lines) do
        if
            line.raw_row >= hunk.raw_start_row
            and line.raw_row <= hunk.raw_end_row
            and line.kind ~= 'hunk'
            and line.old_number == old_number
        then
            return source_line_for_diff_line(by_raw_row, hunk, line)
        end
    end

    return nearest_surviving_new_number(by_raw_row, hunk, hunk.raw_header_row)
end

---@param raw_lines string[]?
---@param hunk MiniFugitDiffHunk
---@param offset integer
---@return integer?
local function source_line_for_right_hunk(raw_lines, hunk, offset)
    if hunk.new_count > 0 then
        return hunk.new_start + math.min(offset, hunk.new_count - 1)
    end

    local _, by_raw_row = parsed_lines(raw_lines)

    return nearest_surviving_new_number(by_raw_row, hunk, hunk.raw_header_row)
end

---@param raw_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@param side MiniFugitDiffSide
---@param row integer
---@return integer?
function M.source_line_for_split_row(raw_lines, hunks, side, row)
    local hunk, offset = hunk_at_split_row(hunks, side, row)

    if hunk == nil then
        if side == 'left' then
            return M.old_line_to_new_line(hunks, row)
        end

        return row
    end

    if side == 'left' then
        return source_line_for_left_hunk(raw_lines, hunk, offset)
    end

    return source_line_for_right_hunk(raw_lines, hunk, offset)
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

---@param hunk MiniFugitDiffHunk
---@param position MiniFugitDiffHunkPosition
---@return MiniFugitDiffSide
---@return integer
function M.split_row_for_hunk_position(hunk, position)
    local side = position.side
    local start = side == 'left' and hunk.old_start or hunk.new_start
    local count = side == 'left' and hunk.old_count or hunk.new_count

    if count <= 0 then
        side = side == 'left' and 'right' or 'left'
        start = side == 'left' and hunk.old_start or hunk.new_start
        count = side == 'left' and hunk.old_count or hunk.new_count
    end

    if count <= 0 then
        return side, 1
    end

    return side, start + math.min(position.offset, count - 1)
end

return M
