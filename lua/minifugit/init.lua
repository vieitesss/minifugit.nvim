local M = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui')
local git = require('minifugit.git')

M.status = function()
    log.info('status command called')

    ui.open_win()

    local content = {}
    table.insert(content, git.branch())

    ui.append_lines(content)
end

return M
