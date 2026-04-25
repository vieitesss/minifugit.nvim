---@class Minifugit
---@field gsw GitStatusWindow?
local M = {
    gsw = nil,
}

local log = require('minifugit.log')
local GitStatusWindow = require('minifugit.ui.status')

function M.status()
    log.info('status command called')

    if M.gsw then
        M.gsw:show()
    else
        local gsw = GitStatusWindow.new()
        M.gsw = gsw
    end

    log.info(
        string.format('Window opened win=%d buf=%d', M.gsw.win, M.gsw.buf.id)
    )
end

return M
