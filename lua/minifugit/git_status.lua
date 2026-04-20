---@class GitStatus
---@field head_line function Returns highlighted branch line
---@field lines function Formats raw git status output into highlighted lines

local highlight = require('minifugit.highlight')

---@type GitStatus
local git_status = {
    head_line = function() end,
    lines = function() end,
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

---@param stage string
---@param unstage string
---@param is_staged boolean
---@return string?
local status_group_for = function(stage, unstage, is_staged)
    if conflict_statuses[stage .. unstage] then
        return highlight.groups.conflict
    end

    local code = is_staged and stage or unstage

    if code == ' ' then
        return nil
    end

    if code == '?' then
        return highlight.groups.untracked
    end

    if code == '!' then
        return highlight.groups.ignored
    end

    if code == 'U' then
        return highlight.groups.conflict
    end

    return is_staged and highlight.groups.staged or highlight.groups.unstaged
end

---@param branch string
---@return MiniFugitLine
function git_status.head_line(branch)
    local prefix = 'HEAD: '
    local text = prefix .. branch
    local line = highlight.plain_line(text)

    highlight.add(line, highlight.groups.head, 0, 4)
    highlight.add(line, 'Title', #prefix, #text)

    return line
end

---@param status string
---@return MiniFugitLine[]
function git_status.lines(status)
    local lines = vim.split(status, '\n', { plain = true, trimempty = true })
    local formatted_lines = {}

    for _, line in ipairs(lines) do
        if not line:match('^.. ') then
            table.insert(formatted_lines, highlight.plain_line(line))
        else
            local stage = line:sub(1, 1)
            local unstage = line:sub(2, 2)
            local formatted_line = highlight.plain_line(line)

            highlight.add(formatted_line, status_group_for(stage, unstage, true), 0)
            highlight.add(formatted_line, status_group_for(stage, unstage, false), 1)

            table.insert(formatted_lines, formatted_line)
        end
    end

    return formatted_lines
end

return git_status
