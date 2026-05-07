---@class MinifugitPreviewOptions
---@field wrap boolean
---@field show_line_numbers boolean
---@field show_metadata boolean

---@class MinifugitStatusOptions
---@field width number
---@field min_width integer

---@class MinifugitOptions
---@field preview MinifugitPreviewOptions
---@field status MinifugitStatusOptions

local defaults = {
    preview = {
        wrap = false,
        show_line_numbers = true,
        show_metadata = true,
    },
    status = {
        width = 0.4,
        min_width = 20,
    },
}

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
        local gsw = GitStatusWindow.new(M.options)
        M.gsw = gsw
    end

    log.info(
        string.format('Window opened win=%d buf=%d', M.gsw.win, M.gsw.buf.id)
    )
end

---@param opts MinifugitOptions?
function M.setup(opts)
    vim.validate('opts', opts, 'table', true, '`opts` should be a table')

    opts = opts or {}
    vim.validate('opts.preview', opts.preview, 'table', true)
    vim.validate('opts.status', opts.status, 'table', true)

    if opts.preview ~= nil then
        vim.validate('opts.preview.wrap', opts.preview.wrap, 'boolean', true)
        vim.validate(
            'opts.preview.show_line_numbers',
            opts.preview.show_line_numbers,
            'boolean',
            true
        )
        vim.validate(
            'opts.preview.show_metadata',
            opts.preview.show_metadata,
            'boolean',
            true
        )
    end

    if opts.status ~= nil then
        vim.validate('opts.status.width', opts.status.width, 'number', true)
        vim.validate('opts.status.min_width', opts.status.min_width, 'number', true)

        if opts.status.width ~= nil then
            if opts.status.width <= 0 or opts.status.width > 1 then
                error('opts.status.width must be a number between 0 and 1')
            end
        end

        if opts.status.min_width ~= nil then
            if opts.status.min_width < 1 then
                error('opts.status.min_width must be >= 1')
            end
        end
    end

    M.did_setup = true
    M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

    return M
end

return M
