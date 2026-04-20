local M = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui')
local git = require('minifugit.git')
local git_status = require('minifugit.git_status')

M.status = function()
    log.info('status command called')

    ui.open_win()
    git_status.ensure_highlights()

    local content = {}

    local branch = "HEAD: " .. git.branch()
    local status_lines = git_status.lines(git.status())

    table.insert(content, branch)
    table.insert(content, "")
    vim.list_extend(content, status_lines)

    ui.append_lines(content)
end

return M
