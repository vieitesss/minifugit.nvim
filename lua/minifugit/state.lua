
---@class State
---@field buf number The current buffer id
---@field win number The current window id

---@type State
local state = {
    buf = -1,
    win = -1
}

---@return number The window id
local create_win = function()
    local buf = vim.api.nvim_create_buf(true, false)

    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)
    local parent_height = vim.api.nvim_win_get_height(parent_win)

    local width = math.max(math.floor(parent_width * 0.5), 40)
    local height = math.max(math.floor(parent_height * 0.5), 10)

    local col = math.floor((parent_width - width) / 2)
    local row = math.floor((parent_height - height) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "win",
        win = parent_win,
        width = width,
        height = height,
        col = col,
        row = row,
        style = "minimal",
        border = "rounded",
    })

    state.buf = buf
    state.win = win

    return win
end

---@return number The window id
function state.open_win()
    if state.buf == -1 or state.win == -1 then
        return create_win()
    end

    if not vim.api.nvim_buf_is_valid(state.buf) or
        not vim.api.nvim_win_is_valid(state.win) then
        return create_win()
    end

    vim.api.nvim_set_current_win(state.win)

    return state.win
end


return state
