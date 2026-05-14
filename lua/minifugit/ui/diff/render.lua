local parser = require('minifugit.ui.diff.parser')
local source_syntax = require('minifugit.ui.diff.syntax')
local render = require('minifugit.ui.render')

---@class MiniFugitDiffRenderOpts
---@field show_headers boolean?
---@field show_numbers boolean?
---@field syntax MiniFugitDiffSyntaxSource?

local M = {}

---@param number integer?
---@param width integer
---@return string
local function format_number(number, width)
    if number == nil then
        return string.rep(' ', width)
    end

    return string.format('%' .. width .. 'd', number)
end

---@param line MiniFugitDiffLine
---@param width integer
---@param opts MiniFugitDiffRenderOpts
---@return string
local function format_diff_line(line, width, opts)
    if line.kind == 'header' or line.kind == 'hunk' then
        return line.text
    end

    if opts.show_numbers == false then
        return line.text
    end

    return string.format(
        '%s %s %s',
        format_number(line.old_number, width),
        format_number(line.new_number, width),
        line.text
    )
end

---@param lines MiniFugitDiffLine[]
---@return integer
local function diff_number_width(lines)
    local max_number = 0

    for _, line in ipairs(lines) do
        if line.old_number ~= nil then
            max_number = math.max(max_number, line.old_number)
        end

        if line.new_number ~= nil then
            max_number = math.max(max_number, line.new_number)
        end
    end

    return math.max(#tostring(max_number), 1)
end

---@param line MiniFugitRenderLine
---@param spans MiniFugitSyntaxSpan[]?
---@param start_col integer
local function add_source_highlights(line, spans, start_col)
    for _, span in ipairs(spans or {}) do
        render.add_highlight(
            line,
            span.group,
            start_col + span.start_col,
            start_col + span.end_col
        )
    end
end

---@param diff_line MiniFugitDiffLine
---@return 'left'|'right'?
---@return integer?
local function syntax_side_and_row(diff_line)
    if diff_line.kind == 'removed' then
        return 'left', diff_line.old_number
    end

    if diff_line.kind == 'added' then
        return 'right', diff_line.new_number
    end

    if diff_line.kind == 'context' then
        return 'right', diff_line.new_number or diff_line.old_number
    end

    return nil, nil
end

---@param line MiniFugitRenderLine
---@param diff_line MiniFugitDiffLine
---@param groups table<string, string>
local function add_diff_highlights(line, diff_line, groups)
    if diff_line.kind == 'added' then
        line.line_hl_group = groups.diff_added
    elseif diff_line.kind == 'removed' then
        line.line_hl_group = groups.diff_removed
    elseif diff_line.kind == 'header' then
        render.add_highlight(line, groups.diff_header, 0, #line.text)
    elseif diff_line.kind == 'hunk' then
        render.add_highlight(line, groups.diff_hunk_header, 0, #line.text)
    end
end

---@param line MiniFugitRenderLine
---@param diff_line MiniFugitDiffLine
---@param source_spans table<string, table<integer, MiniFugitSyntaxSpan[]>>?
---@param width integer
---@param opts MiniFugitDiffRenderOpts
local function add_source_syntax(line, diff_line, source_spans, width, opts)
    if source_spans == nil then
        return
    end

    local side, source_row = syntax_side_and_row(diff_line)

    if side == nil or source_row == nil then
        return
    end

    local text_start = (opts.show_numbers ~= false) and (2 * width + 2) or 0

    add_source_highlights(line, source_spans[side][source_row], text_start + 1)
end

---@param lines string[]
---@param groups table<string, string>
---@param opts? MiniFugitDiffRenderOpts
---@return MiniFugitRenderLine[]
---@return integer[]
function M.render_lines(lines, groups, opts)
    opts = opts or {}

    local parsed = parser.parse_lines(lines)
    local width = diff_number_width(parsed)
    local diff_lines = {}
    local raw_rows = {}
    local source_spans = source_syntax.spans_for_diff(opts.syntax, parsed)

    for _, diff_line in ipairs(parsed) do
        if diff_line.kind == 'header' and opts.show_headers == false then
            goto continue
        end

        local line = render.line(format_diff_line(diff_line, width, opts))

        add_diff_highlights(line, diff_line, groups)

        -- Highlight the old/new number prefix so it reads as a gutter, not
        -- plain text. Applies only to context/added/removed rows (headers and
        -- hunk lines have no prepended numbers).
        if
            opts.show_numbers ~= false
            and diff_line.kind ~= 'header'
            and diff_line.kind ~= 'hunk'
        then
            render.add_highlight(line, groups.diff_line_nr, 0, 2 * width + 2)
        end

        add_source_syntax(line, diff_line, source_spans, width, opts)

        table.insert(diff_lines, line)
        table.insert(raw_rows, diff_line.raw_row)

        ::continue::
    end

    if #diff_lines == 0 then
        table.insert(
            diff_lines,
            render.line('(No diff content — only headers)')
        )
    end

    return diff_lines, raw_rows
end

return M
