local Buffer = require('minifugit.ui.buffer')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local window = require('minifugit.ui.status.window')
local selection = require('minifugit.ui.status.selection')

local M = {}

---@param lines string[]
---@param groups table<string, string>
---@return MiniFugitRenderLine[]
local function diff_render_lines(lines, groups)
    return vim.tbl_map(function(text)
        local line = render.line(text)

        if vim.startswith(text, '+') and not vim.startswith(text, '+++') then
            render.add_highlight(line, groups.diff_added, 0, #text)
        elseif vim.startswith(text, '-') and not vim.startswith(text, '---') then
            render.add_highlight(line, groups.diff_removed, 0, #text)
        end

        return line
    end, lines)
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and common.is_valid_win(self.diff_win)
        and vim.api.nvim_win_get_buf(self.diff_win) == self.diff_buf.id
end

---@param self GitStatusWindow
function M.close_diff(self)
    local current_win = vim.api.nvim_get_current_win()
    local diff_win = current_win

    if not self.diff_buf
        or not self.diff_buf:is_valid()
        or vim.api.nvim_win_get_buf(diff_win) ~= self.diff_buf.id
    then
        if not common.is_valid_win(self.diff_win) then
            return
        end

        diff_win = self.diff_win

        if vim.api.nvim_win_get_buf(diff_win) ~= self.diff_buf.id then
            return
        end
    end

    if self.diff_created_win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(diff_win, true)
    elseif self.diff_prev_buf and vim.api.nvim_buf_is_valid(self.diff_prev_buf) then
        vim.api.nvim_win_set_buf(diff_win, self.diff_prev_buf)
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(diff_win, true)
    end

    self.diff_win = nil
    self.diff_prev_buf = nil
    self.diff_created_win = false
    self.diff_preview_key = nil

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end
end

---@param self GitStatusWindow
---@return Buffer
function M.ensure_diff_buf(self)
    if self.diff_buf and self.diff_buf:is_valid() then
        return self.diff_buf
    end

    self.diff_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Minifugit diff',
    })

    vim.bo[self.diff_buf.id].buftype = 'nofile'
    vim.bo[self.diff_buf.id].bufhidden = 'hide'
    vim.bo[self.diff_buf.id].swapfile = false
    vim.bo[self.diff_buf.id].filetype = 'diff'

    vim.keymap.set('n', 'q', function()
        M.close_diff(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    return self.diff_buf
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean? }
---@return boolean
function M.open_diff(self, entry, section, opts)
    opts = opts or {}

    local preview_key = table.concat(
        { section or '', entry.orig_path or '', entry.path },
        '\0'
    )

    if not opts.force and M.has_open_diff(self) and self.diff_preview_key == preview_key then
        return true
    end

    local lines, err = git.diff(entry, section)
    local diff_lines

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    if #lines == 0 then
        diff_lines = { render.line('No diff for ' .. entry.path) }
    else
        diff_lines = diff_render_lines(lines, self.groups)
    end

    local buf = M.ensure_diff_buf(self)

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local target_win = window.find_target_win(self)
    local created_win = false

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
        created_win = true
    else
        vim.api.nvim_set_current_win(target_win)
    end

    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id and self.diff_win == target_win

    if not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_created_win = created_win
    end

    vim.api.nvim_win_set_buf(target_win, buf.id)
    window.configure_diff_win(target_win)
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function M.preview_current_entry(self, opts)
    opts = opts or {}

    local item = selection.current_entry_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No git status entry under cursor')
        end

        return false
    end

    return M.open_diff(self, item.entry, item.section, {
        force = opts.force,
    })
end

---@param self GitStatusWindow
function M.refresh_current_entry(self)
    if M.has_open_diff(self) then
        M.preview_current_entry(self, {
            force = true,
            notify = false,
        })
    end
end

return M
