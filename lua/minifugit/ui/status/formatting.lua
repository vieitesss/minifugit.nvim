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

---@alias GitStatusSection {title:string, entries:GitStatusEntry[]}

---@class GitStatusRenderOpts
---@field show_help boolean?

local mapping_lines = {
    '? hide mappings',
    '<CR> open file',
    '= show diff',
    's stage entry',
    'u unstage entry',
    'S stage all',
    'U unstage all',
    'c commit staged changes',
    'visual s stage selection',
    'visual u unstage selection',
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
    local text = prefix .. (branch ~= '' and branch or '(none)')
    local line = render.line(text)

    render.add_highlight(line, groups.head, 0, #prefix)
    render.add_highlight(line, 'Title', #prefix, #text)

    return line
end

---@param title string
---@param count integer
---@return MiniFugitRenderLine
local function section_line(title, count)
    local text = string.format('%s (%d)', title, count)
    local line = render.line(text)

    render.add_highlight(line, 'Title', 0, #text)

    return line
end

---@param text string
---@param group string
---@return MiniFugitRenderLine
local function message_line(text, group)
    local line = render.line(text)

    render.add_highlight(line, group, 0, #text)

    return line
end

---@param lines MiniFugitRenderLine[]
---@param show_help boolean?
local function append_help(lines, show_help)
    table.insert(lines, render.line(''))

    if not show_help then
        table.insert(lines, message_line('? mappings', 'Comment'))
        return
    end

    table.insert(lines, message_line('Mappings', 'Title'))

    for _, text in ipairs(mapping_lines) do
        table.insert(lines, message_line('  ' .. text, 'Comment'))
    end
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

---@param entry GitStatusEntry
---@return boolean
local function is_conflict(entry)
    return conflict_statuses[entry.staged .. entry.unstaged]
        or entry.staged == 'U'
        or entry.unstaged == 'U'
end

---@param entry GitStatusEntry
---@return boolean
local function is_untracked(entry)
    return entry.staged == '?' or entry.unstaged == '?'
end

---@param entry GitStatusEntry
---@return boolean
local function is_staged(entry)
    return entry.staged ~= ' ' and entry.staged ~= '?' and entry.staged ~= '!'
end

---@param entry GitStatusEntry
---@return boolean
local function is_unstaged(entry)
    return entry.unstaged ~= ' '
        and entry.unstaged ~= '?'
        and entry.unstaged ~= '!'
end

---@param entries GitStatusEntry[]
---@return GitStatusSection[]
local function sections(entries)
    local groups = {
        conflicts = {},
        staged = {},
        unstaged = {},
        untracked = {},
    }

    for _, entry in ipairs(entries) do
        if is_conflict(entry) then
            table.insert(groups.conflicts, entry)
        elseif is_untracked(entry) then
            table.insert(groups.untracked, entry)
        else
            if is_staged(entry) then
                table.insert(groups.staged, entry)
            end

            if is_unstaged(entry) then
                table.insert(groups.unstaged, entry)
            end
        end
    end

    return {
        { title = 'Conflicts', entries = groups.conflicts },
        { title = 'Staged', entries = groups.staged },
        { title = 'Unstaged', entries = groups.unstaged },
        { title = 'Untracked', entries = groups.untracked },
    }
end

---@param lines MiniFugitRenderLine[]
---@param section GitStatusSection
---@param groups table<string, string>
local function append_section(lines, section, groups)
    if #section.entries == 0 then
        return
    end

    table.insert(lines, render.line(''))
    table.insert(lines, section_line(section.title, #section.entries))
    vim.list_extend(lines, M.entry_lines(section.entries, groups))
end

---@param snapshot GitStatusSnapshot
---@param groups table<string, string>
---@param opts? GitStatusRenderOpts
---@return MiniFugitRenderLine[]
function M.render(snapshot, groups, opts)
    opts = opts or {}

    local lines = { M.head_line(snapshot.branch, groups) }

    if snapshot.error ~= nil then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line(snapshot.error, 'WarningMsg'))
        append_help(lines, opts.show_help)
        return lines
    end

    if #snapshot.entries == 0 then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line('Working tree clean', 'Comment'))
        append_help(lines, opts.show_help)
        return lines
    end

    for _, section in ipairs(sections(snapshot.entries)) do
        append_section(lines, section, groups)
    end

    append_help(lines, opts.show_help)

    return lines
end

return M
