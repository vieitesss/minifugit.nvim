local common = require('minifugit.ui.status.common')
local preview_util = require('minifugit.ui.status.preview.util')
local window = require('minifugit.ui.status.window')

local M = {}

---@param self GitStatusWindow
local function clear_diff_context(self)
    self.diff_raw_lines = nil
    self.diff_raw_rows = nil
    self.diff_hunks = nil
    self.diff_section = nil
    self.diff_context_entry = nil
end

---@param self GitStatusWindow
---@return DiffWindow[]
local function diff_windows(self)
    return { self.diff_stacked, self.diff_left, self.diff_right }
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_split_diff(self)
    return self.diff_left:has_open() and self.diff_right:has_open()
end

---@param self GitStatusWindow
---@return boolean
function M.has_any_split_diff(self)
    return self.diff_left:has_open() or self.diff_right:has_open()
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_stacked_diff(self)
    return self.diff_stacked:has_open()
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return M.has_open_stacked_diff(self) or M.has_any_split_diff(self)
end

---@param self GitStatusWindow
---@param buf integer
---@return DiffWindow?
function M.diff_window_for_buf(self, buf)
    for _, dw in ipairs(diff_windows(self)) do
        if dw.buf ~= nil and dw.buf.id == buf then
            return dw
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param win number
---@return DiffWindow?
function M.diff_window_for_win(self, win)
    for _, dw in ipairs(diff_windows(self)) do
        if dw.win == win then
            return dw
        end
    end

    return nil
end

---@param self GitStatusWindow
function M.clear_missing_diff_window_states(self)
    for _, dw in ipairs(diff_windows(self)) do
        if not dw:has_open() then
            dw:clear()
        end
    end

    -- Clear alignment metadata when no split diff remains.
    if not M.has_any_split_diff(self) then
        self.diff_left_rows = nil
        self.diff_right_rows = nil
        self.diff_anchors = nil
    end
end

---@param self GitStatusWindow
---@param buf integer
function M.restore_replaced_diff_window(self, buf)
    local dw = M.diff_window_for_buf(self, buf)

    if dw == nil then
        return
    end

    if not common.is_valid_win(dw.win) then
        dw:clear()
        return
    end

    if vim.api.nvim_win_get_buf(dw.win) == buf then
        return
    end

    if dw.is_split then
        preview_util.diffoff(dw.win)
    end

    window.restore_winopts(dw.win, dw.prev_winopts)
    dw:clear()
end

---@param self GitStatusWindow
---@param buf integer
function M.attach_autocmds(self, buf)
    if self.autocmd_group == nil then
        return
    end

    vim.api.nvim_clear_autocmds({
        group = self.autocmd_group,
        buffer = buf,
    })
    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = self.autocmd_group,
        buffer = buf,
        callback = function(args)
            vim.schedule(function()
                M.restore_replaced_diff_window(self, args.buf)
            end)
        end,
    })
end

---@param self GitStatusWindow
---@return Buffer[]
function M.diff_buffers(self)
    local buffers = {}

    for _, dw in ipairs(diff_windows(self)) do
        if dw.buf ~= nil and dw.buf:is_valid() then
            table.insert(buffers, dw.buf)
        end
    end

    return buffers
end

---@param self GitStatusWindow
function M.clear_diff_buffers(self)
    for _, dw in ipairs(diff_windows(self)) do
        dw.buf = nil
    end
end

---@param buffers Buffer[]
function M.delete_diff_buffers(buffers)
    for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
    end
end

---@param self GitStatusWindow
---@param current_dw DiffWindow
---@return DiffWindow
function M.code_window_for_diff(self, current_dw)
    if not current_dw.is_split then
        return current_dw
    end

    if common.is_valid_win(self.diff_left.win) then
        return self.diff_left
    end

    return current_dw
end

---@param self GitStatusWindow
---@param current_dw DiffWindow
---@return Buffer[]
---@return number
function M.close_diff_windows_for_code(self, current_dw)
    local buffers = M.diff_buffers(self)
    local code_dw = M.code_window_for_diff(self, current_dw)
    local code_win = code_dw.win

    for _, dw in ipairs(diff_windows(self)) do
        if dw == code_dw then
            dw:restore_or_close(true)
        elseif current_dw.is_split and dw.is_split then
            dw:restore_or_close(false)
        end
    end

    self.diff_preview_key = nil
    clear_diff_context(self)
    M.clear_diff_buffers(self)
    M.clear_missing_diff_window_states(self)

    return buffers, code_win
end

return M
