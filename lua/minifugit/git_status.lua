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

function git_status.ensure_highlights()
    vim.api.nvim_set_hl(0, status_groups.staged, { default = true, link = 'DiffAdd' })
    vim.api.nvim_set_hl(
        0,
        status_groups.unstaged,
        { default = true, link = 'DiffDelete' }
    )
    vim.api.nvim_set_hl(
        0,
        status_groups.untracked,
        { default = true, link = 'DiagnosticWarn' }
    )
    vim.api.nvim_set_hl(0, status_groups.ignored, { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(
        0,
        status_groups.conflict,
        { default = true, link = 'DiagnosticError' }
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
