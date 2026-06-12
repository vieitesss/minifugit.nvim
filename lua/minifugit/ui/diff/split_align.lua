---@class MiniFugitSplitRow
---@field kind 'context'|'delete'|'add'|'filler'|'separator'
---@field old_lnum integer?
---@field new_lnum integer?
---@field hunk_index integer?

---@class MiniFugitSplitAlignment
---@field left_lines string[]
---@field right_lines string[]
---@field left_rows MiniFugitSplitRow[]
---@field right_rows MiniFugitSplitRow[]
---@field anchors table<integer, integer>  hunk index -> buffer row of first changed line

local parser = require('minifugit.ui.diff.parser')

local M = {}

---Align old (left) and new (right) file contents side by side using parsed
---diff hunks and raw diff lines. Only hunk regions are included; full-file
---context before the first hunk and after the last hunk is omitted. Filler
---rows keep additions and deletions synchronised within each hunk. A
---separator row is inserted between consecutive hunks.
---
---@param old_lines string[]
---@param new_lines string[]
---@param raw_diff_lines string[]
---@param hunks MiniFugitDiffHunk[]
---@return MiniFugitSplitAlignment
function M.align(old_lines, new_lines, raw_diff_lines, hunks)
    local left_lines = {}
    local right_lines = {}
    local left_rows = {}
    local right_rows = {}
    ---@type table<integer, integer>
    local anchors = {}

    local function push(lt, lr, rt, rr)
        table.insert(left_lines, lt)
        table.insert(left_rows, lr)
        table.insert(right_lines, rt)
        table.insert(right_rows, rr)
    end

    local function push_context(old_lnum, new_lnum, hunk_index)
        push(
            old_lines[old_lnum] or '',
            {
                kind = 'context',
                old_lnum = old_lnum,
                new_lnum = new_lnum,
                hunk_index = hunk_index,
            },
            new_lines[new_lnum] or '',
            {
                kind = 'context',
                old_lnum = old_lnum,
                new_lnum = new_lnum,
                hunk_index = hunk_index,
            }
        )
    end

    local function flush_change(dels, adds, hunk_index)
        if
            hunk_index
            and not anchors[hunk_index]
            and (#dels > 0 or #adds > 0)
        then
            anchors[hunk_index] = #left_lines + 1
        end
        for i = 1, math.max(#dels, #adds) do
            local d = dels[i]
            local a = adds[i]
            push(
                d and (old_lines[d] or '') or '',
                d and { kind = 'delete', old_lnum = d, hunk_index = hunk_index }
                    or { kind = 'filler', hunk_index = hunk_index },
                a and (new_lines[a] or '') or '',
                a and { kind = 'add', new_lnum = a, hunk_index = hunk_index }
                    or { kind = 'filler', hunk_index = hunk_index }
            )
        end
    end

    -- Parse raw diff lines so we can classify each line within a hunk's range.
    local parsed = parser.parse_lines(raw_diff_lines or {})

    ---@type table<integer, MiniFugitDiffLine>
    local by_raw_row = {}
    for _, pl in ipairs(parsed) do
        by_raw_row[pl.raw_row] = pl
    end

    local SEP = ('─'):rep(40)

    for i, hunk in ipairs(hunks or {}) do
        -- Separator between hunks (skipped for the first hunk).
        if i > 1 then
            local sep_row = {
                kind = 'separator',
                hunk_index = hunk.index,
            }
            push(SEP, sep_row, SEP, sep_row)
        end

        local dels = {}
        local adds = {}

        local function flush()
            if #dels > 0 or #adds > 0 then
                flush_change(dels, adds, hunk.index)
                dels = {}
                adds = {}
            end
        end

        for raw_row = hunk.raw_start_row, hunk.raw_end_row do
            local dl = by_raw_row[raw_row]

            if dl ~= nil then
                if dl.kind == 'context' then
                    flush()
                    push_context(dl.old_number, dl.new_number, hunk.index)
                elseif dl.kind == 'removed' then
                    table.insert(dels, dl.old_number)
                elseif dl.kind == 'added' then
                    table.insert(adds, dl.new_number)
                end
            end
        end
        flush()
    end

    return {
        left_lines = left_lines,
        right_lines = right_lines,
        left_rows = left_rows,
        right_rows = right_rows,
        anchors = anchors,
    }
end

return M
