local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local selection = require('minifugit.ui.status.selection')

local M = {}

local function stop_visual_mode()
    local mode = vim.fn.mode()

    if mode == 'v' or mode == 'V' or mode == '\22' then
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes('<Esc>', true, false, true),
            'nx',
            false
        )
    end
end

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

---@param items GitStatusEntryItem[]
---@return boolean
local function all_items_in_section(items, section)
    for _, item in ipairs(items) do
        if item.section ~= section then
            return false
        end
    end

    return #items > 0
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
    cursor_state.follow_entry = false
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

    stop_visual_mode()

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
        return M.update_entry_items(
            self,
            git.unstage_entries,
            { item },
            'unstage'
        )
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
    return M.update_entries(
        self,
        git.stage_entries,
        selection.all_entries(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_all_entries(self)
    return M.update_entries(
        self,
        git.unstage_entries,
        selection.all_entries(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.stage_selected_entries(self)
    local items = selection.selected_entry_items(self)

    if all_items_in_section(items, 'staged') then
        return M.update_entry_items(self, git.unstage_entries, items, 'unstage')
    end

    return M.update_entry_items(self, git.stage_entries, items, 'stage')
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

    if
        not force
        and vim.fn.confirm(discard_message(item), '&Discard\n&Cancel', 2)
            ~= 1
    then
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

---@param buf integer
---@param path string
local function delete_commit_resources(buf, path)
    if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    vim.fn.delete(path)
end

---@param buf integer
---@param force boolean
---@return boolean
local function can_close_commit_buffer(buf, force)
    if
        force
        or not vim.api.nvim_buf_is_valid(buf)
        or not vim.bo[buf].modified
    then
        return true
    end

    common.notify_warn('No write since last change (add ! to override)')
    return false
end

---@param self GitStatusWindow
---@param win integer
---@param buf integer
---@param path string
---@param force boolean
---@return boolean
local function return_to_status_from_commit(self, win, buf, path, force)
    if not can_close_commit_buffer(buf, force) then
        return false
    end

    if self.buf == nil or not self.buf:is_valid() then
        delete_commit_resources(buf, path)
        return true
    end

    if common.is_valid_win(win) then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_buf(win, self.buf.id)
    else
        self:show()
    end

    self:refresh()
    delete_commit_resources(buf, path)

    return true
end

---@param self GitStatusWindow
---@param win integer
---@param buf integer
---@param path string
---@return fun()
local function return_to_status_on_commit_close(self, win, buf, path)
    local enabled = true

    local autocmd = vim.api.nvim_create_autocmd('WinClosed', {
        group = self.autocmd_group,
        pattern = tostring(win),
        once = true,
        callback = function()
            if not enabled then
                return
            end

            autocmd = nil
            vim.schedule(function()
                return_to_status_from_commit(self, win, buf, path, false)
            end)
        end,
    })

    return function()
        enabled = false

        if autocmd ~= nil then
            pcall(vim.api.nvim_del_autocmd, autocmd)
            autocmd = nil
        end
    end
end

---@class CommitCloseCommand
---@field kind 'close'|'write'|'write_modified'
---@field force boolean

---@param cmdline string
---@return CommitCloseCommand?
local function parse_commit_close_command(cmdline)
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmdline, {})

    if not ok or parsed.nextcmd ~= '' then
        return nil
    end

    if parsed.cmd == 'quit' then
        return { kind = 'close', force = parsed.bang }
    end

    if #parsed.args > 0 then
        return nil
    end

    if parsed.cmd == 'wq' then
        return { kind = 'write', force = parsed.bang }
    end

    if parsed.cmd == 'xit' or parsed.cmd == 'exit' then
        return { kind = 'write_modified', force = parsed.bang }
    end

    return nil
end

---@param buf integer
---@param force boolean
local function write_commit_buffer(buf, force)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local ok, err = pcall(vim.cmd, force and 'write!' or 'write')

    if not ok then
        common.notify_error(err, 'Cannot write commit message')
    end
end

---@param buf integer
---@param command CommitCloseCommand
---@param close fun(force: boolean)
local function run_commit_close_command(buf, command, close)
    if command.kind == 'close' then
        close(command.force)
        return
    end

    if
        command.kind == 'write_modified'
        and vim.api.nvim_buf_is_valid(buf)
        and not vim.bo[buf].modified
    then
        close(command.force)
        return
    end

    write_commit_buffer(buf, command.force)
end

---@param buf integer
---@param close fun(force: boolean)
local function install_commit_close_mapping(buf, close)
    -- Quit-like commands close the window by default. Intercept command-line
    -- Enter instead of expanding :q, so no replacement command is echoed.
    vim.keymap.set('c', '<CR>', function()
        if vim.fn.getcmdtype() ~= ':' then
            return '<CR>'
        end

        local command = parse_commit_close_command(vim.fn.getcmdline())

        if command ~= nil then
            vim.schedule(function()
                run_commit_close_command(buf, command, close)
            end)
            return '<C-c>'
        end

        return '<CR>'
    end, { buffer = buf, expr = true, replace_keycodes = true })
end

---@param self GitStatusWindow
---@return boolean
function M.commit(self)
    if self.win == nil or not common.is_valid_win(self.win) then
        common.notify_error(nil, 'Status window is not open')
        return false
    end

    local has_staged_changes, err = git.has_staged_changes()

    if err ~= nil then
        common.notify_error(err, 'Cannot inspect staged changes')
        return false
    end

    if not has_staged_changes then
        common.notify_warn('No staged files to commit')
        return false
    end

    local path = vim.fn.tempname() .. '.gitcommit'
    vim.fn.writefile(git.commit_template(), path)

    vim.api.nvim_set_current_win(self.win)
    vim.wo[self.win].winbar = ''
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo.filetype = 'gitcommit'
    vim.wo.winbar = ''
    local stop_return_on_close =
        return_to_status_on_commit_close(self, win, buf, path)

    ---@param force boolean
    local close_commit = function(force)
        if not return_to_status_from_commit(self, win, buf, path, force) then
            return
        end

        stop_return_on_close()
    end

    vim.api.nvim_buf_create_user_command(
        buf,
        'MinifugitCommitClose',
        function(opts)
            close_commit(opts.bang)
        end,
        { bang = true }
    )
    install_commit_close_mapping(buf, close_commit)

    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = buf,
        callback = function()
            local ok, output = git.commit_file(path)
            local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR

            vim.notify('[minifugit] ' .. output, level)

            if not ok then
                return false
            end

            stop_return_on_close()

            vim.schedule(function()
                return_to_status_from_commit(self, win, buf, path, true)
            end)

            return true
        end,
    })

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.push(self)
    if self.win == nil or not common.is_valid_win(self.win) then
        common.notify_error(nil, 'Status window is not open')
        return false
    end

    if self.loading_message ~= nil then
        common.notify_warn('Git command already running')
        return false
    end

    self:start_loading('Pushing commits')

    git.push_async(function(ok, output)
        output = output or ''
        self:stop_loading()

        if not ok then
            if
                output == 'No unpushed commits to push'
                or output:match('^No upstream')
                or output:match('^Cannot push')
            then
                common.notify_warn(output)
            else
                common.notify_error(output, 'Push failed')
            end

            self:render_cached()
            return
        end

        common.notify(
            output ~= '' and output or 'Pushed commits',
            vim.log.levels.INFO
        )
        self:refresh()
    end)

    return true
end

return M
