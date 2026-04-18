local M = {}

local state = require('minifugit.state')

M.status = function()
    state.open_win()
end

return M
