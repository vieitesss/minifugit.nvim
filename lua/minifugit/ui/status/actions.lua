local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local selection = require('minifugit.ui.status.selection')

local M = {}

---@param item GitStatusEntryItem
---@param kind 'stage'|'unstage'
---@return boolean
local function should_apply_action(item, kind)
    if kind == 'stage' then
        return item.section ~= 'staged'
    end

    return item.section ~= 'unstaged' and item.section ~= 'untracked'
end

---@param items GitStatusEntryItem[]
---@param kind 'stage'|'unstage'
---@return GitStatusEntry[]
local function entries_for_action(items, kind)
    local entries = {}

    for _, item in ipairs(items) do
        if should_apply_action(item, kind) then
            table.insert(entries, item.entry)
        end
    end

    return entries
end

---@param item GitStatusEntryItem
---@return boolean
local function can_discard_item(item)
    return item.section == 'unstaged' or item.section == 'untracked'
end

---@param item GitStatusEntryItem
---@return string
local function discard_message(item)
    if item.section == 'untracked' then
        return 'Delete untracked path ' .. item.entry.path .. '?'
    end

    return 'Discard changes in ' .. item.entry.path .. '?'
end

---@param item GitStatusEntryItem
---@return boolean
---@return string?
local function discard_item(item)
    if item.section == 'unstaged' then
        return git.discard_unstaged_entries({ item.entry })
    end

    if item.section == 'untracked' then
        return git.discard_untracked_entries({ item.entry })
    end

    return false, 'Nothing to discard'
end

---@param self GitStatusWindow
---@param action fun(entries: GitStatusEntry[]): boolean, string?
---@param entries GitStatusEntry[]
---@return boolean
function M.update_entries(self, action, entries)
    local win = self.win

    if #entries == 0 then
        common.notify_warn('No git status entries selected')
        return false
    end

    if not win or not common.is_valid_win(win) then
        common.notify_error(nil, 'Status window is not open')
        return false
    end

    local cursor_state = selection.capture_cursor_state(self)
    local ok, err = action(entries)

    if not ok then
        common.notify_error(err, 'Git action failed')
        return false
    end

    self:refresh(cursor_state)

    return true
end

---@param self GitStatusWindow
---@param action fun(entries: GitStatusEntry[]): boolean, string?
---@param items GitStatusEntryItem[]
---@param kind 'stage'|'unstage'
---@return boolean
function M.update_entry_items(self, action, items, kind)
    if #items == 0 then
        common.notify_warn('No git status entries selected')
        return false
    end

    local entries = entries_for_action(items, kind)

    if #entries == 0 then
        local message = kind == 'stage' and 'Nothing to stage'
            or 'Nothing to unstage'

        common.notify_warn(message)
        return false
    end

    return M.update_entries(self, action, entries)
end

---@param self GitStatusWindow
---@param action fun(entries: GitStatusEntry[]): boolean, string?
---@param kind 'stage'|'unstage'
---@return boolean
function M.update_entry(self, action, kind)
    local item = selection.current_entry_item(self)

    if item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    return M.update_entry_items(self, action, { item }, kind)
end

---@param self GitStatusWindow
---@return boolean
function M.stage_entry(self)
    local item = selection.current_entry_item(self)

    if item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if item.section == 'staged' then
        return M.update_entry_items(self, git.unstage_entries, { item }, 'unstage')
    end

    return M.update_entry_items(self, git.stage_entries, { item }, 'stage')
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_entry(self)
    return M.update_entry(self, git.unstage_entries, 'unstage')
end

---@param self GitStatusWindow
---@return boolean
function M.stage_all_entries(self)
    return M.update_entries(self, git.stage_entries, selection.all_entries(self))
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_all_entries(self)
    return M.update_entries(self, git.unstage_entries, selection.all_entries(self))
end

---@param self GitStatusWindow
---@return boolean
function M.stage_selected_entries(self)
    return M.update_entry_items(
        self,
        git.stage_entries,
        selection.selected_entry_items(self),
        'stage'
    )
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_selected_entries(self)
    return M.update_entry_items(
        self,
        git.unstage_entries,
        selection.selected_entry_items(self),
        'unstage'
    )
end

---@param self GitStatusWindow
---@param force boolean
---@return boolean
function M.discard_entry(self, force)
    local item = selection.current_entry_item(self)

    if item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if not can_discard_item(item) then
        common.notify_warn('Nothing to discard')
        return false
    end

    if not force and vim.fn.confirm(discard_message(item), '&Discard\n&Cancel', 2) ~= 1 then
        return false
    end

    local cursor_state = selection.capture_cursor_state(self)
    local ok, err = discard_item(item)

    if not ok then
        common.notify_error(err, 'Cannot discard changes')
        return false
    end

    self:refresh(cursor_state)

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.commit(self)
    if self.win == nil or not common.is_valid_win(self.win) then
        common.notify_error(nil, 'Status window is not open')
        return false
    end

    local path = vim.fn.tempname() .. '.gitcommit'
    vim.fn.writefile(git.commit_template(), path)

    vim.api.nvim_set_current_win(self.win)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.bo.filetype = 'gitcommit'

    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = vim.api.nvim_get_current_buf(),
        callback = function(args)
            local ok, output = git.commit_file(path)
            local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR

            vim.notify('[minifugit] ' .. output, level)

            if not ok then
                return false
            end

            self:render()

            if self.win ~= nil and common.is_valid_win(self.win) then
                vim.api.nvim_win_set_buf(self.win, self.buf.id)
            end

            if vim.api.nvim_buf_is_valid(args.buf) then
                vim.api.nvim_buf_delete(args.buf, { force = true })
            end

            vim.fn.delete(path)

            return true
        end,
    })

    return true
end

return M
