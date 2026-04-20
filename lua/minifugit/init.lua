local M = {}

local highlight = require('minifugit.highlight')
local log = require('minifugit.log')
local ui = require('minifugit.ui')
local git = require('minifugit.git')
local git_status = require('minifugit.git_status')

M.status = function()
    log.info('status command called')

    ui.open_win()
    highlight.ensure()

    local content = {}

    local head_line = git_status.head_line(git.branch())
    local status_lines = git_status.lines(git.status())

    table.insert(content, head_line)
    if #status_lines > 0 then
        table.insert(content, "")
        vim.list_extend(content, status_lines)
    end

    ui.set_lines(content)
end

return M
