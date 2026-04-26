local render = require('minifugit.ui.render')

local M = {}

local conflict_statuses = {
    AA = true,
    AU = true,
    DD = true,
    DU = true,
    UA = true,
    UD = true,
    UU = true,
}

---@param entry GitStatusEntry
---@return string
local function entry_text(entry)
    if entry.orig_path ~= nil then
        return entry.staged
            .. entry.unstaged
            .. ' '
            .. entry.orig_path
            .. ' -> '
            .. entry.path
    end

    return entry.staged .. entry.unstaged .. ' ' .. entry.path
end

---@param stage string
---@param unstage string
---@param is_staged boolean
---@param groups table<string, string>
---@return string?
local function status_group_for(stage, unstage, is_staged, groups)
    if conflict_statuses[stage .. unstage] then
        return groups.conflict
    end

    local code = is_staged and stage or unstage

    if code == ' ' then
        return nil
    end

    if code == '?' then
        return groups.untracked
    end

    if code == '!' then
        return groups.ignored
    end

    if code == 'U' then
        return groups.conflict
    end

    return is_staged and groups.staged or groups.unstaged
end

---@param branch string
---@param groups table<string, string>
---@return MiniFugitRenderLine
function M.head_line(branch, groups)
    local prefix = 'HEAD: '
    local text = prefix .. branch
    local line = render.line(text)

    render.add_highlight(line, groups.head, 0, #prefix)
    render.add_highlight(line, 'Title', #prefix, #text)

    return line
end

---@param entry GitStatusEntry
---@param groups table<string, string>
---@return MiniFugitRenderLine
function M.entry_line(entry, groups)
    local line = render.line(entry_text(entry), entry)

    render.add_highlight(
        line,
        status_group_for(entry.staged, entry.unstaged, true, groups),
        0
    )
    render.add_highlight(
        line,
        status_group_for(entry.staged, entry.unstaged, false, groups),
        1
    )

    return line
end

---@param entries GitStatusEntry[]
---@param groups table<string, string>
---@return MiniFugitRenderLine[]
function M.entry_lines(entries, groups)
    local lines = {}

    for _, entry in ipairs(entries) do
        table.insert(lines, M.entry_line(entry, groups))
    end

    return lines
end

---@param branch string
---@param entries GitStatusEntry[]
---@param groups table<string, string>
---@return MiniFugitRenderLine[]
function M.render(branch, entries, groups)
    local lines = { M.head_line(branch, groups) }
    local status_lines = M.entry_lines(entries, groups)

    if #status_lines > 0 then
        table.insert(lines, render.line(''))
        vim.list_extend(lines, status_lines)
    end

    return lines
end

return M
