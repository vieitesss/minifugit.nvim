local M = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui')

M.status = function()
    log.info('status command called')
    ui.open_win()
    local status = {
        "hola",
        "qué tal"
    }
    ui.append_lines(status)
    status = {
        "adios"
    }
    ui.append_lines(status)
end

return M
