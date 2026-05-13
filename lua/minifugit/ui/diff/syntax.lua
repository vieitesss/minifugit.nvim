---@class MiniFugitSyntaxSpan
---@field group string
---@field start_col integer
---@field end_col integer

---@class MiniFugitDiffSyntaxSource
---@field filetype string
---@field left_lines string[]
---@field right_lines string[]

local M = {}

local VIM_SYNTAX_MAX_LINES = 2000
local VIM_SYNTAX_MAX_BYTES = 200000

---@param lines string[]
---@return table<integer, MiniFugitSyntaxSpan[]>
local function empty_spans(lines)
    local spans = {}

    for index = 1, #lines do
        spans[index] = {}
    end

    return spans
end

---@param spans table<integer, MiniFugitSyntaxSpan[]>
---@return boolean
local function has_spans(spans)
    for _, line_spans in pairs(spans) do
        if #line_spans > 0 then
            return true
        end
    end

    return false
end

---@param name string
---@return boolean
local function highlight_exists(name)
    return vim.fn.hlexists(name) == 1
end

---@param capture string
---@param lang string
---@return string?
local function treesitter_capture_group(capture, lang)
    local lang_group = '@' .. capture .. '.' .. lang

    if highlight_exists(lang_group) then
        return lang_group
    end

    local group = '@' .. capture

    if highlight_exists(group) then
        return group
    end

    return nil
end

---@param spans table<integer, MiniFugitSyntaxSpan[]>
---@param lines string[]
---@param row integer
---@param start_col integer
---@param end_col integer
---@param group string?
local function add_span(spans, lines, row, start_col, end_col, group)
    if group == nil or row < 1 or row > #lines or end_col <= start_col then
        return
    end

    table.insert(spans[row], {
        group = group,
        start_col = start_col,
        end_col = end_col,
    })
end

---@param buf integer
---@param filetype string
---@param lines string[]
---@param rows table<integer, true>?
---@return table<integer, MiniFugitSyntaxSpan[]>?
local function treesitter_spans(buf, filetype, lines, rows)
    if
        vim.treesitter == nil
        or vim.treesitter.get_parser == nil
        or vim.treesitter.query == nil
        or vim.treesitter.query.get == nil
    then
        return nil
    end

    local lang = filetype

    if vim.treesitter.language ~= nil then
        local ok, matched_lang =
            pcall(vim.treesitter.language.get_lang, filetype)

        if ok and matched_lang ~= nil then
            lang = matched_lang
        end
    end

    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, lang)

    if not ok_parser or parser == nil then
        return nil
    end

    local ok_query, query = pcall(vim.treesitter.query.get, lang, 'highlights')

    if not ok_query or query == nil then
        return nil
    end

    local ok_parse, trees = pcall(function()
        return parser:parse()
    end)

    if not ok_parse or trees == nil then
        return nil
    end

    local spans = empty_spans(lines)
    ---@type integer?
    local start_row = 0
    ---@type integer?
    local end_row = -1

    if rows ~= nil then
        start_row = nil
        end_row = nil

        for row in pairs(rows) do
            local zero_indexed = row - 1
            start_row = start_row == nil and zero_indexed
                or math.min(start_row, zero_indexed)
            end_row = end_row == nil and row or math.max(end_row, row)
        end
    end

    for _, tree in ipairs(trees) do
        for id, node in query:iter_captures(
            tree:root(),
            buf,
            start_row or 0,
            end_row or -1
        ) do
            local capture = query.captures[id]
            local group = treesitter_capture_group(capture, lang)
            local node_start_row, start_col, node_end_row, end_col =
                node:range()

            for row = node_start_row + 1, node_end_row + 1 do
                if rows == nil or rows[row] then
                    add_span(
                        spans,
                        lines,
                        row,
                        row == node_start_row + 1 and start_col or 0,
                        row == node_end_row + 1 and end_col
                            or #(lines[row] or ''),
                        group
                    )
                end
            end
        end
    end

    return has_spans(spans) and spans or nil
end

---@param lines string[]
---@return boolean
local function vim_fallback_allowed(lines)
    if #lines > VIM_SYNTAX_MAX_LINES then
        return false
    end

    local bytes = 0

    for _, line in ipairs(lines) do
        bytes = bytes + #line

        if bytes > VIM_SYNTAX_MAX_BYTES then
            return false
        end
    end

    return true
end

---@param buf integer
---@param filetype string
---@param lines string[]
---@param rows table<integer, true>?
---@return table<integer, MiniFugitSyntaxSpan[]>
local function vim_spans(buf, filetype, lines, rows)
    local spans = empty_spans(lines)

    if not vim_fallback_allowed(lines) then
        return spans
    end

    pcall(vim.api.nvim_buf_call, buf, function()
        vim.bo[buf].syntax = filetype
        vim.cmd('syntax sync fromstart')

        local scan_rows = rows or {}

        if rows == nil then
            for row = 1, #lines do
                scan_rows[row] = true
            end
        end

        for row in pairs(scan_rows) do
            local text = lines[row]

            if text ~= nil then
                local current_group
                local start_col = 0

                for col = 1, #text do
                    local id = vim.fn.synIDtrans(vim.fn.synID(row, col, 1))
                    local group = vim.fn.synIDattr(id, 'name')

                    if group == '' then
                        group = nil
                    end

                    if group ~= current_group then
                        add_span(
                            spans,
                            lines,
                            row,
                            start_col,
                            col - 1,
                            current_group
                        )
                        current_group = group
                        start_col = col - 1
                    end
                end

                add_span(spans, lines, row, start_col, #text, current_group)
            end
        end
    end)

    return spans
end

---@param filetype string
---@param lines string[]
---@param rows table<integer, true>?
---@return table<integer, MiniFugitSyntaxSpan[]>
local function spans_by_line(filetype, lines, rows)
    if
        filetype == ''
        or #lines == 0
        or (rows ~= nil and next(rows) == nil)
    then
        return empty_spans(lines)
    end

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype

    local spans = treesitter_spans(buf, filetype, lines, rows)
        or vim_spans(buf, filetype, lines, rows)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    return spans
end

---@param parsed MiniFugitDiffLine[]
---@return table<'left'|'right', table<integer, true>>
local function referenced_rows(parsed)
    local rows = { left = {}, right = {} }

    for _, diff_line in ipairs(parsed) do
        if diff_line.kind == 'removed' and diff_line.old_number ~= nil then
            rows.left[diff_line.old_number] = true
        elseif diff_line.kind == 'added' and diff_line.new_number ~= nil then
            rows.right[diff_line.new_number] = true
        elseif diff_line.kind == 'context' then
            local source_row = diff_line.new_number or diff_line.old_number

            if source_row ~= nil then
                rows.right[source_row] = true
            end
        end
    end

    return rows
end

---@param source MiniFugitDiffSyntaxSource?
---@param parsed MiniFugitDiffLine[]
---@return table<string, table<integer, MiniFugitSyntaxSpan[]>>?
function M.spans_for_diff(source, parsed)
    if source == nil or source.filetype == '' then
        return nil
    end

    local rows = referenced_rows(parsed)

    return {
        left = spans_by_line(source.filetype, source.left_lines, rows.left),
        right = spans_by_line(source.filetype, source.right_lines, rows.right),
    }
end

return M
