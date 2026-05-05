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

---@alias GitStatusSectionName 'conflicts'|'staged'|'unstaged'|'untracked'|'unpushed'

---@class GitStatusSection
---@field name GitStatusSectionName
---@field title string
---@field entries GitStatusEntry[]

---@class GitStatusLineData
---@field entry GitStatusEntry
---@field section GitStatusSectionName

---@class GitStatusRenderOpts
---@field show_help boolean?
---@field loading_message string?
---@field loading_frame string?

local mapping_lines = {
    '? hide mappings',
    '<CR> or o open file',
    '= show diff preview',
    'r refresh status',
    's stage or unstage entry',
    'u unstage entry',
    'S stage all',
    'U unstage all',
    'd discard unstaged or untracked',
    'D force discard unstaged or untracked',
    'c commit staged changes',
    'p push unpushed commits',
    'visual s stage selection',
    'visual u unstage selection',
}

---@param commit GitCommit
---@param groups table<string, string>
---@return MiniFugitRenderLine
function M.commit_line(commit, groups)
    local text = commit.short_hash .. ' ' .. commit.message
    local line = render.line(text, {
        commit = commit,
        section = 'unpushed',
    })

    render.add_highlight(line, groups.unpushed, 0, #commit.short_hash + 1)

    return line
end

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

---@param message string
---@param frame string
---@param groups table<string, string>
---@return MiniFugitRenderLine
local function loading_line(message, frame, groups)
    local text = frame .. ' ' .. message
    local line = render.line(text)

    render.add_highlight(line, groups.loading, 0, #text)

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
---@param section GitStatusSectionName
---@return MiniFugitRenderLine
function M.entry_line(entry, groups, section)
    local line = render.line(entry_text(entry), {
        entry = entry,
        section = section,
    })

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
---@param section GitStatusSectionName
---@return MiniFugitRenderLine[]
function M.entry_lines(entries, groups, section)
    local lines = {}

    for _, entry in ipairs(entries) do
        table.insert(lines, M.entry_line(entry, groups, section))
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
        { name = 'conflicts', title = 'Conflicts', entries = groups.conflicts },
        { name = 'unstaged', title = 'Unstaged', entries = groups.unstaged },
        { name = 'staged', title = 'Staged', entries = groups.staged },
        { name = 'untracked', title = 'Untracked', entries = groups.untracked },
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
    vim.list_extend(lines, M.entry_lines(section.entries, groups, section.name))
end

---@param snapshot GitStatusSnapshot
---@param groups table<string, string>
---@param opts? GitStatusRenderOpts
---@return MiniFugitRenderLine[]
function M.render(snapshot, groups, opts)
    opts = opts or {}

    local lines = { M.head_line(snapshot.branch, groups) }

    if opts.loading_message ~= nil and opts.loading_frame ~= nil then
        table.insert(
            lines,
            loading_line(opts.loading_message, opts.loading_frame, groups)
        )
    end

    if snapshot.error ~= nil then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line(snapshot.error, 'WarningMsg'))
        append_help(lines, opts.show_help)
        return lines
    end

    if #snapshot.entries == 0 and #snapshot.unpushed_commits == 0 then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line('Working tree clean', 'Comment'))
        append_help(lines, opts.show_help)
        return lines
    end

    for _, section in ipairs(sections(snapshot.entries)) do
        append_section(lines, section, groups)
    end

    if #snapshot.unpushed_commits > 0 then
        table.insert(lines, render.line(''))
        table.insert(lines, section_line('Unpushed', #snapshot.unpushed_commits))

        for _, commit in ipairs(snapshot.unpushed_commits) do
            table.insert(lines, M.commit_line(commit, groups))
        end
    end

    append_help(lines, opts.show_help)

    return lines
end

return M
