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

---@param win number
---@param buf integer
---@param opts? { created: boolean?, inherit_from: DiffWindow? }
---@return boolean ok
---@return string? err
function DiffWindow:open(win, buf, opts)
    vim.validate('win', win, 'number')
    vim.validate('buf', buf, 'number')
    vim.validate('opts', opts, 'table', true)
    opts = opts or {}
    vim.validate('opts.created', opts.created, 'boolean', true)
    vim.validate('opts.inherit_from', opts.inherit_from, 'table', true)

    local current_buf = vim.api.nvim_win_get_buf(win)
    local inherit = opts.inherit_from

    if inherit ~= nil then
        self.prev_buf = inherit.prev_buf or current_buf
        self.prev_winopts = inherit.prev_winopts or window.capture_winopts(win)
        self.created = inherit.created == true
    elseif not (current_buf == buf and self.win == win) then
        self.prev_buf = current_buf
        self.prev_winopts = window.capture_winopts(win)
        self.created = opts.created == true
    end

    local prev_winfixwidth = vim.wo[win].winfixwidth
    vim.wo[win].winfixwidth = false

    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)

    if not ok then
        if common.is_valid_win(win) then
            pcall(function()
                vim.wo[win].winfixwidth = prev_winfixwidth
            end)
        end

        if self.created and #vim.api.nvim_tabpage_list_wins(0) > 1 then
            pcall(vim.api.nvim_win_close, win, true)
        end

        self:clear()
        return false, tostring(err)
    end

    if inherit ~= nil then
        inherit:clear()
    end

    self.win = win
    return true
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
