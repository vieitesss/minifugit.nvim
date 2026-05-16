---@class MinifugitPreviewOptions
---@field wrap boolean
---@field show_line_numbers boolean
---@field show_metadata boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_auto_threshold integer

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
        diff_layout = 'stacked',
        diff_auto_threshold = 120,
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

---@param gsw GitStatusWindow?
---@return boolean
local function has_valid_status_buffer(gsw)
    if gsw == nil or gsw.buf == nil or gsw.buf.id == nil then
        return false
    end

    local bufnr = gsw.buf.id

    return vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.bo[bufnr].buftype == 'nofile'
        and vim.bo[bufnr].filetype == 'minifugit'
end

---@param gsw GitStatusWindow
local function delete_owned_buffers(gsw)
    for _, field in ipairs({
        'buf',
        'diff_buf',
        'diff_left_buf',
        'diff_right_buf',
        'help_buf',
    }) do
        local buf = gsw[field]

        if
            buf ~= nil
            and buf.id ~= nil
            and vim.api.nvim_buf_is_valid(buf.id)
        then
            pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
        end
    end
end

function M.reset()
    if M.gsw == nil then
        return
    end

    local gsw = M.gsw
    pcall(function()
        gsw:close()
    end)
    delete_owned_buffers(gsw)
    M.gsw = nil
end

---@param gsw GitStatusWindow
local function attach_status_buffer_autocmd(gsw)
    vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = gsw.buf.id,
        once = true,
        callback = function()
            if M.gsw ~= gsw then
                return
            end

            vim.schedule(function()
                if M.gsw == gsw then
                    M.reset()
                end
            end)
        end,
    })
end

function M.status()
    log.info('status command called')

    if M.gsw ~= nil and not has_valid_status_buffer(M.gsw) then
        M.reset()
    end

    if M.gsw then
        M.gsw:refresh()
        M.gsw:show()
    else
        local GitStatusWindow = require('minifugit.ui.status')
        local gsw = GitStatusWindow.new(M.options)
        attach_status_buffer_autocmd(gsw)
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
        vim.validate(
            'opts.preview.diff_layout',
            opts.preview.diff_layout,
            'string',
            true
        )
        vim.validate(
            'opts.preview.diff_auto_threshold',
            opts.preview.diff_auto_threshold,
            'number',
            true
        )

        if
            opts.preview.diff_layout ~= nil
            and opts.preview.diff_layout ~= 'stacked'
            and opts.preview.diff_layout ~= 'split'
            and opts.preview.diff_layout ~= 'auto'
        then
            error(
                "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'"
            )
        end

        if
            opts.preview.diff_auto_threshold ~= nil
            and opts.preview.diff_auto_threshold < 1
        then
            error('opts.preview.diff_auto_threshold must be >= 1')
        end
    end

    if opts.status ~= nil then
        vim.validate('opts.status.width', opts.status.width, 'number', true)
        vim.validate(
            'opts.status.min_width',
            opts.status.min_width,
            'number',
            true
        )

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
