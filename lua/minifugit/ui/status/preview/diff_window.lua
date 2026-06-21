local common = require('minifugit.ui.status.common')
local preview_util = require('minifugit.ui.status.preview.util')
local window = require('minifugit.ui.status.window')

---@class DiffWindow
---@field win number?
---@field buf Buffer?
---@field prev_buf number?
---@field prev_winopts GitStatusWindowOptions?
---@field created boolean
---@field is_split boolean
local DiffWindow = {}
DiffWindow.__index = DiffWindow

---@param is_split boolean
---@return DiffWindow
function DiffWindow.new(is_split)
    vim.validate('is_split', is_split, 'boolean')
    return setmetatable({
        win = nil,
        buf = nil,
        prev_buf = nil,
        prev_winopts = nil,
        created = false,
        is_split = is_split,
    }, DiffWindow)
end

---@return boolean
function DiffWindow:has_open()
    if
        self.buf == nil
        or not self.buf:is_valid()
        or not common.is_valid_win(self.win)
    then
        return false
    end

    return vim.api.nvim_win_get_buf(self.win) == self.buf.id
end

function DiffWindow:clear()
    self.win = nil
    self.prev_buf = nil
    self.prev_winopts = nil
    self.created = false
end

---@param keep_win boolean
---@return boolean
function DiffWindow:restore_or_close(keep_win)
    if not common.is_valid_win(self.win) then
        self:clear()
        return false
    end

    if self.is_split then
        preview_util.diffoff(self.win)
    end

    if keep_win then
        window.restore_winopts(self.win, self.prev_winopts)
        self:clear()
        return true
    end

    if self.created and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(self.win, true)
    elseif
        self.prev_buf ~= nil
        and vim.api.nvim_buf_is_valid(self.prev_buf)
    then
        vim.api.nvim_win_set_buf(self.win, self.prev_buf)
        window.restore_winopts(self.win, self.prev_winopts)
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(self.win, true)
    else
        window.restore_winopts(self.win, self.prev_winopts)
    end

    self:clear()
    return true
end

return DiffWindow
