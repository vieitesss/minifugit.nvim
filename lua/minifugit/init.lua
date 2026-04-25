local M = {}

local log = require('minifugit.log')
local GitStatusWindow = require('minifugit.ui.status')

M.status = function()
    log.info('status command called')

    local gsw = GitStatusWindow.new()

    log.info(string.format("Window opened win=%d buf=%d", gsw.win, gsw.buf.id))
end

return M
