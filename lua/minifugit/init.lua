---@class MinifugitOptions

local defaults = {}

---@class Minifugit
---@field gsw GitStatusWindow?
---@field did_setup boolean
---@field options MinifugitOptions
local M = {
    gsw = nil,
    did_setup = false,
    options = vim.deepcopy(defaults),
}

local log = require('minifugit.log')

function M.status()
    log.info('status command called')

    if M.gsw then
        M.gsw:refresh()
        M.gsw:show()
    else
        local GitStatusWindow = require('minifugit.ui.status')
        local gsw = GitStatusWindow.new()
        M.gsw = gsw
    end

    log.info(
        string.format('Window opened win=%d buf=%d', M.gsw.win, M.gsw.buf.id)
    )
end

---@param opts MinifugitOptions?
function M.setup(opts)
    vim.validate('opts', opts, 'table', true, '`opts` should be a table')

    M.did_setup = true
    M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

return M
