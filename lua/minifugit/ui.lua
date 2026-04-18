---@class UI
---@field _win number The window id
---@field _buf number The buffer id
---@field open_win function Opens a new window or enters one already created

---@type UI
local ui = {
    _win = -1,
    _buf = -1,
    open_win = function() end
}

local create_win = function()
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd("botright " .. width .. "vsplit")

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, false)

    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)

    ui._win = win
    ui._buf = buf

    return win
end

---@return number The window id
function ui.open_win()
    if not vim.api.nvim_buf_is_valid(ui._buf) or
        not vim.api.nvim_win_is_valid(ui._win) then
        return create_win()
    end

    vim.api.nvim_set_current_win(ui._win)

    return ui._win
end

return ui
