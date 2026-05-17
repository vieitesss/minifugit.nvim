local common = require('minifugit.ui.status.common')

local M = {}

---@param text string
---@return string
function M.winbar_text(text)
    return (text:gsub('%%', '%%%%'))
end

---@param win number?
function M.diffoff(win)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('diffoff')
        end)
    end
end

return M
