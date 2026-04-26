---@class Minifugit
---@field gsw GitStatusWindow?
---@field did_setup boolean
local M = {
    gsw = nil,
    did_setup = false,
}

local log = require('minifugit.log')
local GitStatusWindow = require('minifugit.ui.status')

function M.status()
    log.info('status command called')

    if M.gsw then
        M.gsw:render()
        M.gsw:show()
    else
        local gsw = GitStatusWindow.new()
        M.gsw = gsw
    end

    log.info(
        string.format('Window opened win=%d buf=%d', M.gsw.win, M.gsw.buf.id)
    )
end

function M.setup()
    if M.did_setup then
        return
    end

    M.did_setup = true

    vim.api.nvim_create_user_command('Minifugit', function()
        M.status()
    end, {
        desc = 'Open Minifugit status',
        force = true,
    })

    vim.api.nvim_create_user_command('MinifugitStatus', function()
        M.status()
    end, {
        desc = 'Open Minifugit status',
        force = true,
    })
end

return M
