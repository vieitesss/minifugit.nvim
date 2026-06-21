local common = require('minifugit.ui.status.common')
local preview_util = require('minifugit.ui.status.preview.util')
local window = require('minifugit.ui.status.window')

local M = {}

---@param self DiffPreview
local function clear_diff_context(self)
    self.raw_lines = nil
    self.raw_rows = nil
    self.hunks = nil
    self.section = nil
    self.context_entry = nil
end

---@param self DiffPreview
---@return DiffWindow[]
local function diff_windows(self)
    return { self.stacked, self.left, self.right }
end

---@param self DiffPreview
---@return boolean
function M.has_open_split_diff(self)
    return self.left:has_open() and self.right:has_open()
end

---@param self DiffPreview
---@return boolean
function M.has_any_split_diff(self)
    return self.left:has_open() or self.right:has_open()
end

---@param self DiffPreview
---@return boolean
function M.has_open_stacked_diff(self)
    return self.stacked:has_open()
end

---@param self DiffPreview
---@return boolean
function M.has_open_diff(self)
    return M.has_open_stacked_diff(self) or M.has_any_split_diff(self)
end

---@param self DiffPreview
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

---@param self DiffPreview
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

---@param self DiffPreview
function M.clear_missing_diff_window_states(self)
    for _, dw in ipairs(diff_windows(self)) do
        if not dw:has_open() then
            dw:clear()
        end
    end

    if not M.has_any_split_diff(self) then
        self.left_rows = nil
        self.right_rows = nil
        self.anchors = nil
    end
end

---@param self DiffPreview
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

---@param self DiffPreview
---@param buf integer
function M.attach_autocmds(self, buf)
    local ag = self.ctx.get_autocmd_group()

    if ag == nil then
        return
    end

    vim.api.nvim_clear_autocmds({
        group = ag,
        buffer = buf,
    })
    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = ag,
        buffer = buf,
        callback = function(args)
            vim.schedule(function()
                M.restore_replaced_diff_window(self, args.buf)
            end)
        end,
    })
end

---@param self DiffPreview
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

---@param self DiffPreview
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

---@param self DiffPreview
---@param current_dw DiffWindow
---@return DiffWindow
function M.code_window_for_diff(self, current_dw)
    if not current_dw.is_split then
        return current_dw
    end

    if common.is_valid_win(self.left.win) then
        return self.left
    end

    return current_dw
end

---@param self DiffPreview
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

    self.preview_key = nil
    clear_diff_context(self)
    M.clear_diff_buffers(self)
    M.clear_missing_diff_window_states(self)

    return buffers, code_win
end

return M
