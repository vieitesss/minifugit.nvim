local render = require('minifugit.ui.render')

---@alias GitStatusSectionName 'conflicts'|'staged'|'unstaged'|'untracked'|'unpushed'|'base'

---@class GitStatusSection
---@field name GitStatusSectionName
---@field title string
---@field entries GitStatusEntry[]

---Data carried by a rendered status entry row.
---@class GitStatusEntryLineData
---@field entry GitStatusEntry
---@field section GitStatusSectionName

---Data carried by a rendered unpushed commit row.
---@class GitStatusCommitLineData
---@field commit GitCommit
---@field section GitStatusSectionName

---@alias GitStatusLineData GitStatusEntryLineData|GitStatusCommitLineData

---@class StatusDocumentOptions
---@field filter string?
---@field base string? Pinned commit hash.
---@field loading_message string?
---@field loading_frame string?

---@class GitStatusEntryItem
---@field kind 'entry'
---@field key string
---@field entry GitStatusEntry
---@field section GitStatusSectionName?

---@class GitStatusCommitItem
---@field kind 'commit'
---@field key string
---@field commit GitCommit

---@alias StatusItem GitStatusEntryItem|GitStatusCommitItem

---@class GitStatusCursorState
---@field row integer?
---@field item_key string?
---@field entry_key string?
---@field commit_key string?
---@field follow_entry boolean?

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
            .. vim.fn.strtrans(entry.orig_path)
            .. ' -> '
            .. vim.fn.strtrans(entry.path)
    end

    return entry.staged .. entry.unstaged .. ' ' .. vim.fn.strtrans(entry.path)
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

---@param commit GitCommit
---@param groups table<string, string>
---@return MiniFugitRenderLine
local function commit_line(commit, groups)
    local text = commit.short_hash .. ' ' .. commit.message
    local line = render.line(text, {
        commit = commit,
        section = 'unpushed',
    })

    render.add_highlight(line, groups.unpushed, 0, #commit.short_hash + 1)

    return line
end

---@param branch string
---@param groups table<string, string>
---@return MiniFugitRenderLine
local function head_line(branch, groups)
    local prefix = 'HEAD: '
    local text = prefix .. (branch ~= '' and branch or '(none)')
    local line = render.line(text)

    render.add_highlight(line, groups.head, 0, #prefix)
    render.add_highlight(line, 'Title', #prefix, #text)

    return line
end

---@param entry GitStatusEntry
---@param groups table<string, string>
---@param section GitStatusSectionName
---@return MiniFugitRenderLine
local function entry_line(entry, groups, section)
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
local function entry_lines(entries, groups, section)
    local lines = {}

    for _, entry in ipairs(entries) do
        table.insert(lines, entry_line(entry, groups, section))
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

---@param entry GitStatusEntry
---@param query string Non-empty filter text.
---@return boolean
local function matches_filter(entry, query)
    local needle = query:lower()
    local path = vim.fn.strtrans(entry.path):lower()
    local orig_path = entry.orig_path
            and vim.fn.strtrans(entry.orig_path):lower()
        or ''

    return path:find(needle, 1, true) ~= nil
        or orig_path:find(needle, 1, true) ~= nil
end

---@param entries GitStatusEntry[]
---@param query string?
---@return GitStatusEntry[]
local function filtered_entries(entries, query)
    if query == nil or query == '' then
        return entries
    end

    return vim.tbl_filter(function(entry)
        return matches_filter(entry, query)
    end, entries)
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
    vim.list_extend(lines, entry_lines(section.entries, groups, section.name))
end

---@param snapshot GitStatusSnapshot
---@param groups table<string, string>
---@param opts StatusDocumentOptions
---@return MiniFugitRenderLine[]
local function render_lines(snapshot, groups, opts)
    local short_base = opts.base and opts.base:sub(1, 7)
    local lines = {
        short_base ~= nil and message_line(
            'Base: ' .. short_base .. ' (read-only)',
            'Title'
        ) or head_line(snapshot.branch, groups),
    }

    if snapshot.root ~= nil and snapshot.root ~= '' then
        table.insert(
            lines,
            message_line(
                'Root: ' .. vim.fn.strtrans(snapshot.root),
                'Directory'
            )
        )
    end

    local entries = filtered_entries(snapshot.entries, opts.filter)

    if opts.loading_message ~= nil and opts.loading_frame ~= nil then
        table.insert(
            lines,
            loading_line(opts.loading_message, opts.loading_frame, groups)
        )
    end

    if snapshot.error ~= nil then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line(snapshot.error, 'WarningMsg'))
        return lines
    end

    if #snapshot.entries == 0 and #snapshot.unpushed_commits == 0 then
        table.insert(lines, render.line(''))
        table.insert(
            lines,
            message_line(
                short_base ~= nil and ('No changes since ' .. short_base)
                    or 'Working tree clean',
                'Comment'
            )
        )
        return lines
    end

    if opts.filter ~= nil and opts.filter ~= '' then
        table.insert(lines, render.line(''))
        table.insert(lines, message_line('filter=' .. opts.filter, 'Comment'))

        if #entries == 0 then
            table.insert(
                lines,
                message_line('No entries match filter', 'Comment')
            )
            return lines
        end
    end

    if short_base ~= nil then
        append_section(lines, {
            name = 'base',
            title = 'Changes since ' .. short_base,
            entries = entries,
        }, groups)
        return lines
    end

    for _, section in ipairs(sections(entries)) do
        append_section(lines, section, groups)
    end

    if
        #snapshot.unpushed_commits > 0
        and (opts.filter == nil or opts.filter == '')
    then
        table.insert(lines, render.line(''))
        table.insert(
            lines,
            section_line('Unpushed', #snapshot.unpushed_commits)
        )

        for _, commit in ipairs(snapshot.unpushed_commits) do
            table.insert(lines, commit_line(commit, groups))
        end
    end

    return lines
end

-- ── Status items ─────────────────────────────────────────────────────────────

---@param entry GitStatusEntry
---@return string
local function entry_key(entry)
    return table.concat({
        entry.orig_path or '',
        entry.path,
    }, '\0')
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@return GitStatusEntryItem
local function entry_item(entry, section)
    return {
        kind = 'entry',
        key = table.concat({
            section or '',
            entry_key(entry),
        }, '\0'),
        entry = entry,
        section = section,
    }
end

---@param commit GitCommit
---@return GitStatusCommitItem
local function commit_item(commit)
    return {
        kind = 'commit',
        key = commit.hash,
        commit = commit,
    }
end

---@param lines MiniFugitRenderLine[]
---@param row integer?
---@param kind 'entry'|'commit'?
---@return StatusItem?
local function item_at(lines, row, kind)
    if type(row) ~= 'number' then
        return nil
    end

    local line = lines[row]

    if line == nil then
        return nil
    end

    ---@type GitStatusLineData?
    local data = line.data

    if type(data) ~= 'table' then
        return nil
    end

    ---@cast data GitStatusEntryLineData
    if kind ~= 'commit' and type(data.entry) == 'table' then
        return entry_item(data.entry, data.section)
    end

    ---@cast data GitStatusCommitLineData
    if kind ~= 'entry' and type(data.commit) == 'table' then
        return commit_item(data.commit)
    end

    return nil
end

---@param lines MiniFugitRenderLine[]
---@param key string?
---@return integer?
local function row_for_item_key(lines, key)
    if key == nil then
        return nil
    end

    for row = 1, #lines do
        local item = item_at(lines, row, 'entry')

        if item ~= nil and item.key == key then
            return row
        end
    end

    return nil
end

---@param lines MiniFugitRenderLine[]
---@param key string?
---@return integer?
local function row_for_entry_key(lines, key)
    if key == nil then
        return nil
    end

    for row = 1, #lines do
        local item = item_at(lines, row, 'entry')

        if item ~= nil and entry_key(item.entry) == key then
            return row
        end
    end

    return nil
end

---@param lines MiniFugitRenderLine[]
---@param key string?
---@return integer?
local function row_for_commit_key(lines, key)
    if key == nil then
        return nil
    end

    for row = 1, #lines do
        local item = item_at(lines, row, 'commit')

        if item ~= nil and item.key == key then
            return row
        end
    end

    return nil
end

---@param lines MiniFugitRenderLine[]
---@return integer?
local function first_entry_row(lines)
    for row = 1, #lines do
        if item_at(lines, row, 'entry') ~= nil then
            return row
        end
    end

    return nil
end

---@param row integer
---@param count integer
---@return integer
local function clamp_row(row, count)
    return math.max(1, math.min(row, count))
end

---@param lines MiniFugitRenderLine[]
---@param row integer
---@return integer
local function resolved_row(lines, row)
    local clamped = clamp_row(row, #lines)

    if item_at(lines, clamped, nil) ~= nil then
        return clamped
    end

    return first_entry_row(lines) or clamped
end

---Row of the item `state` refers to, trying the item key, then the entry
---identity, then the commit key according to the requested `kind`.
---@param lines MiniFugitRenderLine[]
---@param state GitStatusCursorState
---@param kind 'entry'|'commit'? Restricts the item keys considered when given.
---@param entry_fallback boolean Match the entry identity when no item key does.
---@return integer?
local function state_item_row(lines, state, kind, entry_fallback)
    if kind ~= 'commit' then
        local row = row_for_item_key(lines, state.item_key)

        if row == nil and entry_fallback then
            row = row_for_entry_key(lines, state.entry_key)
        end

        if row ~= nil then
            return row
        end
    end

    if kind ~= 'entry' then
        return row_for_commit_key(lines, state.commit_key)
    end

    return nil
end

-- ── Public interface ─────────────────────────────────────────────────────────

---@class StatusDocument
---@field lines MiniFugitRenderLine[] Read-only rendered status lines.
local StatusDocument = {}
StatusDocument.__index = StatusDocument

---@param snapshot GitStatusSnapshot
---@param groups table<string, string>
---@param opts? StatusDocumentOptions
---@return StatusDocument
function StatusDocument.new(snapshot, groups, opts)
    vim.validate('snapshot', snapshot, 'table')
    vim.validate('groups', groups, 'table')
    vim.validate('opts', opts, 'table', true)
    opts = opts or {}
    vim.validate('opts.filter', opts.filter, 'string', true)
    vim.validate('opts.base', opts.base, 'string', true)
    vim.validate('opts.loading_message', opts.loading_message, 'string', true)
    vim.validate('opts.loading_frame', opts.loading_frame, 'string', true)

    return setmetatable({
        lines = render_lines(snapshot, groups, opts),
    }, StatusDocument)
end

---Item under `row`, falling back to `previous_state` keys when the row holds
---no item of the requested kind.
---@param row integer?
---@param kind 'entry'|'commit'?
---@param previous_state GitStatusCursorState?
---@return StatusItem?
function StatusDocument:item(row, kind, previous_state)
    local current = item_at(self.lines, row, kind)

    if current ~= nil or previous_state == nil then
        return current
    end

    local fallback_row =
        state_item_row(self.lines, previous_state, kind, kind ~= 'commit')

    if fallback_row == nil then
        return nil
    end

    return item_at(self.lines, fallback_row, kind)
end

---Visible entry items in the inclusive row range, or in the whole document.
---@param first_row integer?
---@param last_row integer?
---@return GitStatusEntryItem[]
function StatusDocument:entries(first_row, last_row)
    local first = first_row or 1
    local last = last_row or #self.lines

    if first > last then
        first, last = last, first
    end

    local items = {}

    for row = math.max(1, first), math.min(last, #self.lines) do
        local item = item_at(self.lines, row, 'entry')

        if item ~= nil then
            table.insert(items, item)
        end
    end

    return items
end

---Keys for the item at `row` plus a fallback row, never derived from text.
---@param row integer?
---@return GitStatusCursorState
function StatusDocument:capture(row)
    local state = { row = row, follow_entry = true }
    local item = item_at(self.lines, row, nil)

    if item == nil then
        return state
    end

    if item.kind == 'commit' then
        state.commit_key = item.key
    else
        state.item_key = item.key
        state.entry_key = entry_key(item.entry)
    end

    return state
end

---Row to place the cursor on for `state`, or nil when it has no target.
---@param state GitStatusCursorState?
---@return integer?
function StatusDocument:resolve(state)
    state = state or {}

    if state.follow_entry == false and state.row ~= nil then
        return clamp_row(state.row, #self.lines)
    end

    local target =
        state_item_row(self.lines, state, nil, state.follow_entry ~= false)

    if target ~= nil then
        return resolved_row(self.lines, target)
    end

    if state.row ~= nil then
        return resolved_row(self.lines, state.row)
    end

    return first_entry_row(self.lines)
end

return StatusDocument
