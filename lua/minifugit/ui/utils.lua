---@class UI
---@field close_win function Closes the window and deletes the buffer
---@field ensure_buf function Returns whether a buffer is valid or not
---@field ensure_win function Returns whether a window is valid or not
---@field focus_edit_target function Focus previous usable window or create one

---@alias UIBufWin {buf:integer, win:integer}

local log = require('minifugit.log')

---@type UI
local ui = {
    close_win = function() end,
    ensure_buf = function() end,
    ensure_win = function() end,
    focus_edit_target = function() end,
}

---@param win integer
---@param source_win integer
---@return boolean
local function is_usable_edit_target(win, source_win)
    if win == 0 or not vim.api.nvim_win_is_valid(win) or win == source_win then
        return false
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local config = vim.api.nvim_win_get_config(win)
    local buftype = vim.bo[buf].buftype
    local filetype = vim.bo[buf].filetype
    local ok, winfixbuf = pcall(function()
        return vim.wo[win].winfixbuf
    end)

    if config.relative ~= '' then
        return false
    end

    if
        vim.wo[win].previewwindow
        or vim.wo[win].winfixwidth
        or (ok and winfixbuf)
    then
        return false
    end

    if buf == vim.api.nvim_win_get_buf(source_win) then
        return false
    end

    if
        buftype == 'nofile'
        or buftype == 'help'
        or buftype == 'quickfix'
        or buftype == 'terminal'
    then
        return false
    end

    if filetype == 'gitcommit' or filetype == 'gitrebase' then
        return false
    end

    return true
end

---@param source_win integer
---@return integer?
local function pick_edit_target(source_win)
    local previous_win = vim.fn.win_getid(vim.fn.winnr('#'))

    if is_usable_edit_target(previous_win, source_win) then
        return previous_win
    end

    for _, win in
        ipairs(
            vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
        )
    do
        if is_usable_edit_target(win, source_win) then
            return win
        end
    end
end

---@param win? number
---@param buf? number
function ui.close_win(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

---@param buf? integer
function ui.ensure_buf(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        log.error(string.format('buf=%s is not valid', tostring(buf)))
        return false
    end

    return true
end

---@param win? integer
function ui.ensure_win(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        log.error(string.format('win=%s is not valid', tostring(win)))
        return false
    end

    return true
end

---@param source_win integer
function ui.focus_edit_target(source_win)
    local target_win = pick_edit_target(source_win)

    if target_win ~= nil then
        vim.api.nvim_set_current_win(target_win)
        return
    end

    -- Create a new window by default, keeping the Minifugit window on the right
    vim.cmd('aboveleft vnew')
end

return ui
