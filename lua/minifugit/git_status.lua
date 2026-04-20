---@class GitStatus
---@field ensure_highlights function Defines highlight groups for git status columns
---@field lines function Formats raw git status output into highlighted lines

---@class GitStatusHighlight
---@field group string
---@field start_col integer
---@field end_col integer

---@class GitStatusLine
---@field text string
---@field highlights GitStatusHighlight[]

---@type GitStatus
local git_status = {
    ensure_highlights = function() end,
    lines = function() end,
}

local status_groups = {
    staged = 'MiniFugitStage',
    unstaged = 'MiniFugitUnstage',
    untracked = 'MiniFugitUntracked',
    ignored = 'MiniFugitIgnored',
    conflict = 'MiniFugitConflict',
}

local conflict_statuses = {
    AA = true,
    AU = true,
    DD = true,
    DU = true,
    UA = true,
    UD = true,
    UU = true,
}

---@param names string[]
---@return vim.api.keyset.get_hl_info
local get_highlight = function(names)
    for _, name in ipairs(names) do
        local ok, highlight = pcall(vim.api.nvim_get_hl, 0, {
            name = name,
            link = false,
        })

        if ok and next(highlight) ~= nil then
            return highlight
        end
    end

    return {}
end

---@param target string
---@param sources string[]
---@param fallback integer
local set_foreground_highlight = function(target, sources, fallback)
    local source = get_highlight(sources)
    local foreground = source.fg or fallback

    vim.api.nvim_set_hl(0, target, {
        default = true,
        fg = foreground,
        bold = source.bold,
        italic = source.italic,
        underline = source.underline,
    })
end

function git_status.ensure_highlights()
    set_foreground_highlight(status_groups.staged, { 'Added', 'String' }, 0x98C379)
    set_foreground_highlight(status_groups.unstaged, { 'Removed', 'Error' }, 0xE06C75)
    set_foreground_highlight(
        status_groups.untracked,
        { 'Changed', 'DiagnosticWarn', 'WarningMsg' },
        0xE5C07B
    )
    set_foreground_highlight(status_groups.ignored, { 'Comment' }, 0x5C6370)
    set_foreground_highlight(
        status_groups.conflict,
        { 'DiagnosticError', 'ErrorMsg', 'Error' },
        0xE06C75
    )
end

---@param stage string
---@param unstage string
---@param is_staged boolean
---@return string?
local status_group_for = function(stage, unstage, is_staged)
    if conflict_statuses[stage .. unstage] then
        return status_groups.conflict
    end

    local code = is_staged and stage or unstage

    if code == ' ' then
        return nil
    end

    if code == '?' then
        return status_groups.untracked
    end

    if code == '!' then
        return status_groups.ignored
    end

    if code == 'U' then
        return status_groups.conflict
    end

    return is_staged and status_groups.staged or status_groups.unstaged
end

---@param line GitStatusLine
---@param group string?
---@param start_col integer
local add_highlight = function(line, group, start_col)
    if not group then
        return
    end

    table.insert(line.highlights, {
        group = group,
        start_col = start_col,
        end_col = start_col + 1,
    })
end

---@param line string
---@return GitStatusLine
local plain_line = function(line)
    return { text = line, highlights = {} }
end

---@param status string
---@return GitStatusLine[]
function git_status.lines(status)
    local lines = vim.split(status, '\n', { plain = true, trimempty = true })
    local formatted_lines = {}

    for _, line in ipairs(lines) do
        if not line:match('^.. ') then
            table.insert(formatted_lines, plain_line(line))
        else
            local stage = line:sub(1, 1)
            local unstage = line:sub(2, 2)
            local formatted_line = plain_line(line)

            add_highlight(formatted_line, status_group_for(stage, unstage, true), 0)
            add_highlight(formatted_line, status_group_for(stage, unstage, false), 1)

            table.insert(formatted_lines, formatted_line)
        end
    end

    return formatted_lines
end

return git_status
