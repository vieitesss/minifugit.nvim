---@class MinifugitPreviewOptions
---@field wrap boolean
---@field show_line_numbers boolean
---@field show_metadata boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_auto_threshold integer

---@class MinifugitStatusOptions
---@field width number
---@field min_width integer
---@field open_in_tab boolean

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
        open_in_tab = false,
    },
}

---@class Minifugit
---@field did_setup boolean
---@field options MinifugitOptions
local M = {
    did_setup = false,
    options = vim.deepcopy(defaults),
}

local log = require('minifugit.log')

---@type table<integer, GitStatusWindow>
local windows = {}

---@param opts MinifugitOptions?
local function validate_options(opts)
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
        vim.validate(
            'opts.status.open_in_tab',
            opts.status.open_in_tab,
            'boolean',
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
end

---@param opts MinifugitOptions?
---@return MinifugitOptions
local function resolve_options(opts)
    validate_options(vim.g.minifugit)
    validate_options(opts)

    return vim.tbl_deep_extend(
        'force',
        vim.deepcopy(defaults),
        vim.g.minifugit or {},
        opts or {}
    )
end

M.options = resolve_options()

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

---@param tabpage integer
---@param gsw GitStatusWindow?
local function unregister_window(tabpage, gsw)
    if gsw == nil or windows[tabpage] ~= gsw then
        return
    end

    local ok, destroyed = pcall(function()
        return gsw:destroy()
    end)

    if ok and destroyed then
        windows[tabpage] = nil
    end
end

---@param tabpage integer
---@return GitStatusWindow?
local function status_window(tabpage)
    local gsw = windows[tabpage]
    if gsw ~= nil and not has_valid_status_buffer(gsw) then
        unregister_window(tabpage, gsw)
    end

    return windows[tabpage]
end

function M.reset()
    local tabpage = vim.api.nvim_get_current_tabpage()
    unregister_window(tabpage, windows[tabpage])
end

---@param tabpage integer
---@param gsw GitStatusWindow
local function register_window(tabpage, gsw)
    windows[tabpage] = gsw
    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
        group = gsw.autocmd_group,
        buffer = gsw.buf.id,
        once = true,
        callback = function()
            vim.schedule(function()
                unregister_window(tabpage, gsw)
            end)
        end,
    })
    vim.api.nvim_create_autocmd('TabClosed', {
        group = gsw.autocmd_group,
        callback = function()
            vim.schedule(function()
                if not vim.api.nvim_tabpage_is_valid(tabpage) then
                    unregister_window(tabpage, gsw)
                end
            end)
        end,
    })
end

---@param path string?
---@return GitFileChangeCounts
---@return string?
function M.file_change_counts(path)
    return require('minifugit.git').file_change_counts(path)
end

---@return GitFileChangeCounts
---@return string?
function M.current_file_change_counts()
    return require('minifugit.git').current_file_change_counts()
end

function M.status()
    log.info('status command called')

    if not M.did_setup then
        M.options = resolve_options()
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    local gsw = status_window(tabpage)

    if gsw == nil and M.options.status.open_in_tab then
        local root = require('minifugit.git').root()
        for owned_tab, candidate in pairs(windows) do
            if
                candidate.tabpage == owned_tab
                and vim.api.nvim_tabpage_is_valid(owned_tab)
                and has_valid_status_buffer(candidate)
                and candidate.root == root
            then
                tabpage = owned_tab
                gsw = candidate
                break
            end
        end
    end

    if gsw ~= nil and #vim.fn.win_findbuf(gsw.buf.id) == 0 then
        local git = require('minifugit.git')

        if git.root() ~= gsw.root then
            unregister_window(tabpage, gsw)
            gsw = nil
        end
    end

    if gsw ~= nil then
        gsw:refresh()
        gsw:show()
        if gsw.tabpage ~= nil and gsw.tabpage ~= tabpage then
            windows[tabpage] = nil
            register_window(gsw.tabpage, gsw)
        end
    else
        local GitStatusWindow = require('minifugit.ui.status')
        gsw = GitStatusWindow.new(M.options)
        register_window(gsw.tabpage or tabpage, gsw)
    end

    log.info(string.format('Window opened win=%d buf=%d', gsw.win, gsw.buf.id))
end

---@param opts MinifugitOptions?
function M.setup(opts)
    M.did_setup = true
    M.options = resolve_options(opts)

    return M
end

return M
