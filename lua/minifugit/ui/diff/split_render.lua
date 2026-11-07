---@class MiniFugitSplitRow
---@field kind 'context'|'delete'|'add'|'filler'|'separator'
---@field old_lnum integer?
---@field new_lnum integer?
---@field hunk_index integer?

---@class MiniFugitSplitExtmark
---@field row integer 0-based buffer row
---@field col integer 0-based byte column
---@field opts table extmark options

---@class MiniFugitSplitRenderSide
---@field lines string[]
---@field rows MiniFugitSplitRow[]
---@field backgrounds MiniFugitSplitExtmark[]
---@field intraline MiniFugitSplitExtmark[]

---@class MiniFugitSplitRenderPlan
---@field left MiniFugitSplitRenderSide
---@field right MiniFugitSplitRenderSide
---@field anchors table<integer, integer> hunk index -> 1-based buffer row

local parser = require('minifugit.ui.diff.parser')
local word_diff = require('minifugit.ui.diff.word_diff')

local SEPARATOR = ('─'):rep(40)

local M = {}

---Align old (left) and new (right) file contents side by side using parsed
---diff rows and hunks. Only hunk regions are included; full-file context
---before the first hunk and after the last hunk is omitted. Filler rows keep
---additions and deletions synchronised within each hunk. A separator row is
---inserted between consecutive hunks.
---
---@param old_lines string[]
---@param new_lines string[]
---@param by_raw_row table<integer, MiniFugitDiffLine>
---@param hunks MiniFugitDiffHunk[]?
---@return string[] left_lines
---@return string[] right_lines
---@return MiniFugitSplitRow[] left_rows
---@return MiniFugitSplitRow[] right_rows
---@return table<integer, integer> anchors
local function align(old_lines, new_lines, by_raw_row, hunks)
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

    for i, hunk in ipairs(hunks or {}) do
        -- Separator between hunks (skipped for the first hunk).
        if i > 1 then
            local sep_row = {
                kind = 'separator',
                hunk_index = hunk.index,
            }
            push(SEPARATOR, sep_row, SEPARATOR, sep_row)
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

    return left_lines, right_lines, left_rows, right_rows, anchors
end

---Build the full-line highlight descriptions for one side.
---@param lines string[]
---@param rows MiniFugitSplitRow[]
---@param kind 'delete'|'add'
---@param hl_group string
---@return MiniFugitSplitExtmark[]
local function background_marks(lines, rows, kind, hl_group)
    local marks = {}

    for index, meta in ipairs(rows) do
        if meta.kind == kind then
            table.insert(marks, {
                row = index - 1,
                col = 0,
                opts = {
                    end_row = index - 1,
                    end_col = #(lines[index] or ''),
                    hl_eol = true,
                    hl_group = hl_group,
                    priority = 200,
                },
            })
        end
    end

    return marks
end

---Build the intra-line word-change descriptions for one side, pairing the
---removed and added lines of each hunk in raw diff order.
---@param rows MiniFugitSplitRow[]
---@param by_raw_row table<integer, MiniFugitDiffLine>
---@param hunks MiniFugitDiffHunk[]?
---@param side 'left'|'right'
---@param hl_group string
---@return MiniFugitSplitExtmark[]
local function intraline_marks(rows, by_raw_row, hunks, side, hl_group)
    local change_kind = side == 'left' and 'delete' or 'add'
    local lnum_field = side == 'left' and 'old_lnum' or 'new_lnum'
    ---@type table<integer, integer>
    local row_at = {}

    for index, meta in ipairs(rows) do
        local lnum = meta[lnum_field]

        if meta.kind == change_kind and lnum ~= nil and row_at[lnum] == nil then
            row_at[lnum] = index
        end
    end

    local marks = {}

    for _, hunk in ipairs(hunks or {}) do
        local del_lines = {}
        local add_lines = {}
        local in_hunk = false

        for raw_row = hunk.raw_start_row, hunk.raw_end_row do
            local dl = by_raw_row[raw_row]

            if dl ~= nil then
                if dl.kind == 'hunk' and dl.raw_row == hunk.raw_header_row then
                    in_hunk = true
                end

                if in_hunk then
                    if dl.kind == 'removed' then
                        table.insert(del_lines, dl)
                    elseif dl.kind == 'added' then
                        table.insert(add_lines, dl)
                    end
                end
            end
        end

        local pairs_count = math.min(#del_lines, #add_lines)

        for pair_index = 1, pairs_count do
            local del = del_lines[pair_index]
            local add = add_lines[pair_index]

            if del.text and add.text then
                local lnum = side == 'left' and del.old_number or add.new_number
                local row = lnum ~= nil and row_at[lnum] or nil

                if row ~= nil then
                    local ranges = word_diff.changed_ranges(
                        del.text:sub(2),
                        add.text:sub(2),
                        side
                    )

                    for _, range in ipairs(ranges) do
                        table.insert(marks, {
                            row = row - 1,
                            col = range.start_col,
                            opts = {
                                end_col = range.end_col,
                                hl_group = hl_group,
                                priority = 201,
                            },
                        })
                    end
                end
            end
        end
    end

    return marks
end

---Compute the complete split render plan for one diff: aligned lines and row
---metadata for both sides, their highlight descriptions, and hunk anchors.
---Heights, columns and anchors are 1-based in row metadata and 0-based in the
---extmark descriptions, matching Neovim's extmark API.
---
---@param split_diff GitSplitDiff
---@param raw_diff_lines string[]?
---@param hunks MiniFugitDiffHunk[]?
---@param groups table<string, string>
---@return MiniFugitSplitRenderPlan
function M.render(split_diff, raw_diff_lines, hunks, groups)
    ---@type table<integer, MiniFugitDiffLine>
    local by_raw_row = {}

    for _, parsed_line in ipairs(parser.parse_lines(raw_diff_lines or {})) do
        by_raw_row[parsed_line.raw_row] = parsed_line
    end

    local left_lines, right_lines, left_rows, right_rows, anchors =
        align(split_diff.left.lines, split_diff.right.lines, by_raw_row, hunks)

    return {
        left = {
            lines = left_lines,
            rows = left_rows,
            backgrounds = background_marks(
                left_lines,
                left_rows,
                'delete',
                groups.diff_removed
            ),
            intraline = intraline_marks(
                left_rows,
                by_raw_row,
                hunks,
                'left',
                groups.diff_removed_intraline
            ),
        },
        right = {
            lines = right_lines,
            rows = right_rows,
            backgrounds = background_marks(
                right_lines,
                right_rows,
                'add',
                groups.diff_added
            ),
            intraline = intraline_marks(
                right_rows,
                by_raw_row,
                hunks,
                'right',
                groups.diff_added_intraline
            ),
        },
        anchors = anchors,
    }
end

return M
