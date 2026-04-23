local ui = require('minifugit.ui.utils')
local uis = require('minifugit.ui.status')
local log = require('minifugit.log')
local git = require('minifugit.git')

---@class GitStatusActions
---@field go_to_file function
---@field diff_file function

---@type GitStatusActions
local gsa = {
    go_to_file = function() end,
    diff_file = function() end,
}

---@param status_win integer
---@return MiniFugitLine?
local function get_current_line(status_win)
    local pos = vim.api.nvim_win_get_cursor(status_win)
    local row = pos[1]
    local line = uis.get_line(row)

    log.debug("line=" .. line.text)
    return line
end

---@return number, MiniFugitLine?
local function get_win_and_line()
    local status_win = vim.api.nvim_get_current_win()
    local line = get_current_line(status_win)

    return status_win, line
end

function gsa.go_to_file()
    local status_win, line = get_win_and_line()

    if line == nil or line.data == nil then
        return
    end

    local file = vim.fn.fnamemodify(line.data.path, ':p')

    ui.focus_edit_target(status_win)

    vim.cmd('edit ' .. vim.fn.fnameescape(file))
end

function gsa.diff_file()
    local status_win, line = get_win_and_line()

    if line == nil or line.data == nil then
        return
    end

    local file = vim.fn.fnamemodify(line.data.path, ':p')

    local diff = git.diff(file)

    local diff_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(diff_buf, 'Minifugit diff')
    uis.set_lines(diff, diff_buf)

    ui.focus_edit_target(status_win)
    vim.api.nvim_win_set_buf(0, diff_buf)
end

return gsa
