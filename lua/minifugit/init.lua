local M = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui')
local git = require('minifugit.git')

M.status = function()
    log.info('status command called')

    ui.open_win()

    local content = {}

    local branch = "HEAD: " .. git.branch()
    table.insert(content, branch)

    ui.append_lines(content)
end

return M
