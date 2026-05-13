---@class MiniFugitDiffLine
---@field kind 'header'|'hunk'|'context'|'added'|'removed'
---@field old_number integer?
---@field new_number integer?
---@field raw_row integer
---@field text string

---@class MiniFugitDiffHunk
---@field index integer
---@field raw_header_row integer
---@field raw_start_row integer
---@field raw_end_row integer
---@field old_start integer
---@field old_count integer
---@field old_end integer
---@field new_start integer
---@field new_count integer
---@field new_end integer
---@field stacked_row integer?

local M = {}

local DIFF_HEADER_PREFIXES = {
    'diff ',
    'index ',
    '--- ',
    '+++ ',
    'old mode ',
    'new mode ',
    'deleted file mode ',
    'new file mode ',
    'similarity index ',
    'dissimilarity index ',
    'rename from ',
    'rename to ',
    'copy from ',
    'copy to ',
    'Binary files ',
    'GIT binary patch',
}

local DIFF_HEADER_EXACT = {
    '---',
}

---@param text string
---@return boolean
local function is_diff_header(text)
    for _, prefix in ipairs(DIFF_HEADER_PREFIXES) do
        if vim.startswith(text, prefix) then
            return true
        end
    end

    for _, exact in ipairs(DIFF_HEADER_EXACT) do
        if text == exact then
            return true
        end
    end

    return false
end

---@param hunk_header string
---@return integer?, integer?, integer?, integer?
function M.parse_hunk_header(hunk_header)
    local old_start, old_count, new_start, new_count =
        hunk_header:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')

    if old_start == nil or new_start == nil then
        return nil, nil, nil, nil
    end

    return tonumber(old_start),
        old_count == '' and 1 or tonumber(old_count),
        tonumber(new_start),
        new_count == '' and 1 or tonumber(new_count)
end

---@param lines string[]
---@return MiniFugitDiffLine[]
function M.parse_lines(lines)
    local parsed = {}
    local old_number
    local new_number

    for raw_row, text in ipairs(lines) do
        if text == '' then
            goto continue
        end

        if vim.startswith(text, '\\ No newline') then
            goto continue
        end

        if vim.startswith(text, '@@') then
            local old_start, _, new_start = M.parse_hunk_header(text)
            old_number, new_number = old_start, new_start
            table.insert(parsed, {
                kind = 'hunk',
                old_number = old_number,
                new_number = new_number,
                raw_row = raw_row,
                text = text,
            })
        elseif is_diff_header(text) then
            table.insert(
                parsed,
                { kind = 'header', raw_row = raw_row, text = text }
            )
        elseif vim.startswith(text, '+') then
            table.insert(parsed, {
                kind = 'added',
                old_number = nil,
                new_number = new_number,
                raw_row = raw_row,
                text = text,
            })

            if new_number ~= nil then
                new_number = new_number + 1
            end
        elseif vim.startswith(text, '-') then
            table.insert(parsed, {
                kind = 'removed',
                old_number = old_number,
                new_number = nil,
                raw_row = raw_row,
                text = text,
            })

            if old_number ~= nil then
                old_number = old_number + 1
            end
        else
            table.insert(parsed, {
                kind = 'context',
                old_number = old_number,
                new_number = new_number,
                raw_row = raw_row,
                text = text,
            })

            if old_number ~= nil then
                old_number = old_number + 1
            end

            if new_number ~= nil then
                new_number = new_number + 1
            end
        end

        ::continue::
    end

    return parsed
end

---@param start integer
---@param count integer
---@return integer
local function range_end(start, count)
    return count > 0 and start + count - 1 or start
end

---@param lines string[]
---@return MiniFugitDiffHunk[]
function M.parse_hunks(lines)
    local hunks = {}
    local current

    for raw_row, text in ipairs(lines) do
        if vim.startswith(text, '@@') then
            if current ~= nil then
                current.raw_end_row = raw_row - 1
            end

            local old_start, old_count, new_start, new_count =
                M.parse_hunk_header(text)

            if
                old_start ~= nil
                and old_count ~= nil
                and new_start ~= nil
                and new_count ~= nil
            then
                current = {
                    index = #hunks + 1,
                    raw_header_row = raw_row,
                    raw_start_row = raw_row,
                    raw_end_row = #lines,
                    old_start = old_start,
                    old_count = old_count,
                    old_end = range_end(old_start, old_count),
                    new_start = new_start,
                    new_count = new_count,
                    new_end = range_end(new_start, new_count),
                }
                table.insert(hunks, current)
            end
        elseif current ~= nil and vim.startswith(text, 'diff ') then
            current.raw_end_row = raw_row - 1
            current = nil
        end
    end

    return hunks
end

---@param raw_lines string[]?
---@param raw_row integer?
---@return MiniFugitDiffLine?
function M.line_at_raw_row(raw_lines, raw_row)
    if raw_lines == nil or raw_row == nil then
        return nil
    end

    for _, line in ipairs(M.parse_lines(raw_lines)) do
        if line.raw_row == raw_row then
            return line
        end
    end

    return nil
end

---@param hunks MiniFugitDiffHunk[]
---@param raw_rows integer[]?
function M.assign_stacked_rows(hunks, raw_rows)
    if raw_rows == nil then
        return
    end

    for _, hunk in ipairs(hunks) do
        hunk.stacked_row = nil
    end

    for row, raw_row in ipairs(raw_rows) do
        for _, hunk in ipairs(hunks) do
            if raw_row == hunk.raw_header_row then
                hunk.stacked_row = row
                break
            end
        end
    end
end

return M
