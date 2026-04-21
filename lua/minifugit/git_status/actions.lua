local ui = require('minifugit.ui')
local log = require('minifugit.log')

---@class GitStatusActions
---@field go_to_file function

---@type GitStatusActions
local gsa = {
    go_to_file = function() end,
}

function gsa.go_to_file()
    local status_win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_cursor(status_win)
    local row = pos[1]
    local line = ui.get_line(row)

    if line == nil or line.data == nil then
        return
    end

    log.debug("line=" .. line.text)

    local file = vim.fn.fnamemodify(line.data.path, ':p')

    ui.focus_edit_target(status_win)

    vim.cmd('edit ' .. vim.fn.fnameescape(file))

end

return gsa
