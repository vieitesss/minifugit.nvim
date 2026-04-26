local M = {}

---@param win number?
---@return boolean
function M.is_valid_win(win)
    return type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win)
end

---@param message string
---@param level integer
function M.notify(message, level)
    vim.notify('[minifugit] ' .. message, level)
end

---@param message string?
---@param fallback string
function M.notify_error(message, fallback)
    if message == nil or message == '' then
        message = fallback
    end

    M.notify(message, vim.log.levels.ERROR)
end

---@param message string
function M.notify_warn(message)
    M.notify(message, vim.log.levels.WARN)
end

return M
