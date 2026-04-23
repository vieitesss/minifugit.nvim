---@class MiniFugitHighlight
---@field group string
---@field start_col integer
---@field end_col integer

---@class MiniFugitLine
---@field text string
---@field highlights MiniFugitHighlight[]
---@field data GitStatusEntry?

---@class MiniFugitHighlightModule
---@field groups table<string, string>
---@field ensure function Defines highlight groups used by minifugit
---@field line function Creates a line with optional highlights
---@field plain_line function Creates a line without highlights
---@field add function Adds a highlight range to a line
---@field apply function Applies highlights to a buffer

local namespace = vim.api.nvim_create_namespace('minifugit.ui')

---@type MiniFugitHighlightModule
local highlight = {
    groups = {
        staged = 'MiniFugitStage',
        unstaged = 'MiniFugitUnstage',
        untracked = 'MiniFugitUntracked',
        ignored = 'MiniFugitIgnored',
        conflict = 'MiniFugitConflict',
        head = 'MiniFugitHead',
    },
    ensure = function() end,
    line = function() end,
    plain_line = function() end,
    add = function() end,
    apply = function() end,
}

---@param names string[]
---@return vim.api.keyset.get_hl_info
local function get_highlight(names)
    for _, name in ipairs(names) do
        local ok, source = pcall(vim.api.nvim_get_hl, 0, {
            name = name,
            link = false,
        })

        if ok and next(source) ~= nil then
            return source
        end
    end

    return {}
end

---@param target string
---@param sources string[]
---@param fallback integer
local function set_foreground_highlight(target, sources, fallback)
    local source = get_highlight(sources)

    vim.api.nvim_set_hl(0, target, {
        default = true,
        fg = source.fg or fallback,
        bold = source.bold,
        italic = source.italic,
        underline = source.underline,
    })
end

function highlight.ensure()
    set_foreground_highlight(
        highlight.groups.staged,
        { 'Added', 'String' },
        0x98C379
    )
    set_foreground_highlight(
        highlight.groups.unstaged,
        { 'Removed', 'Error' },
        0xE06C75
    )
    set_foreground_highlight(
        highlight.groups.untracked,
        { 'DiagnosticInfo', 'Directory', 'Identifier' },
        0x61AFEF
    )
    set_foreground_highlight(highlight.groups.ignored, { 'Comment' }, 0x5C6370)
    set_foreground_highlight(
        highlight.groups.conflict,
        { 'DiagnosticError', 'ErrorMsg', 'Error' },
        0xE06C75
    )
    set_foreground_highlight(
        highlight.groups.head,
        { 'Identifier', 'Keyword' },
        0x61AFEF
    )
end

---@param text string
---@param highlights MiniFugitHighlight[]?
---@param data GitStatusEntry?
---@return MiniFugitLine
function highlight.line(text, highlights, data)
    return {
        text = text,
        highlights = highlights or {},
        data = data,
    }
end

---@param line string
---@return MiniFugitLine
function highlight.plain_line(line)
    return highlight.line(line)
end

---@param line MiniFugitLine
---@param group string?
---@param start_col integer
---@param end_col integer?
function highlight.add(line, group, start_col, end_col)
    if not group then
        return
    end

    table.insert(line.highlights, {
        group = group,
        start_col = start_col,
        end_col = end_col or (start_col + 1),
    })
end

---@param buf integer
---@param lines MiniFugitLine[]
function highlight.apply(buf, lines)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

    for index, line in ipairs(lines) do
        local line_number = index - 1

        for _, range in ipairs(line.highlights) do
            vim.api.nvim_buf_set_extmark(
                buf,
                namespace,
                line_number,
                range.start_col,
                {
                    end_col = range.end_col,
                    hl_group = range.group,
                }
            )
        end
    end
end

return highlight
