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

---@class MinifugitOpenOptions
---@field cwd string? Directory inside the requested repository or worktree.
---@field open_in_tab boolean? Override the global setting for this window.
---@field on_close fun()? Scheduled once when the status window stops showing.

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

    local function update_tabpage()
        if
            windows[tabpage] ~= gsw
            or gsw.win == nil
            or not vim.api.nvim_win_is_valid(gsw.win)
            or not has_valid_status_buffer(gsw)
            or vim.api.nvim_win_get_buf(gsw.win) ~= gsw.buf.id
        then
            return
        end

        local destination = vim.api.nvim_win_get_tabpage(gsw.win)
        if destination == tabpage then
            return
        end

        local previous = windows[destination]
        if previous ~= nil and previous ~= gsw then
            previous.tabpage = nil
            unregister_window(destination, previous)
        end

        windows[tabpage] = nil
        windows[destination] = gsw
        if gsw.tabpage ~= nil then
            gsw.tabpage = destination
            if previous ~= nil then
                gsw.tab_foreign_buffer = true
            end
        end
        tabpage = destination
    end

    vim.api.nvim_create_autocmd(
        { 'WinEnter', 'TabEnter', 'BufEnter', 'BufWinEnter' },
        {
            group = gsw.autocmd_group,
            callback = update_tabpage,
        }
    )
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
                update_tabpage()
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

---@param opts MinifugitOpenOptions?
---@return true? success
---@return string? error
function M.open(opts)
    vim.validate('opts', opts, 'table', true, '`opts` should be a table')
    opts = opts or {}
    vim.validate('opts.cwd', opts.cwd, 'string', true)
    vim.validate('opts.open_in_tab', opts.open_in_tab, 'boolean', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    log.info('status command called')

    if not M.did_setup then
        M.options = resolve_options()
    end

    local git = require('minifugit.git')
    local root
    if opts.cwd ~= nil then
        local cwd = vim.fs.normalize(vim.fn.fnamemodify(opts.cwd, ':p'))
        if vim.fn.isdirectory(cwd) == 0 then
            return nil, 'Not an existing directory: ' .. cwd
        end
        root = git.root(cwd)
        if root == '' then
            return nil, 'Not inside a git repository: ' .. cwd
        end
    end

    local open_in_tab = opts.open_in_tab
    if open_in_tab == nil then
        open_in_tab = M.options.status.open_in_tab
    end

    local tabpage
    local gsw
    local reusable_tab
    repeat
        tabpage = vim.api.nvim_get_current_tabpage()
        gsw = status_window(tabpage)

        if gsw ~= nil then
            local hidden = #vim.fn.win_findbuf(gsw.buf.id) == 0
            if opts.cwd ~= nil or hidden then
                root = root or git.root()

                if
                    root ~= gsw.root
                    or (
                        hidden
                        and gsw.options.status.open_in_tab ~= open_in_tab
                    )
                then
                    local owned_tab = gsw.tabpage
                    local foreign_buffer = gsw.tab_foreign_buffer
                    local repinned = root ~= gsw.root
                    unregister_window(tabpage, gsw)
                    gsw = nil
                    if
                        repinned
                        and open_in_tab
                        and owned_tab ~= nil
                        and vim.api.nvim_tabpage_is_valid(owned_tab)
                    then
                        reusable_tab = {
                            tabpage = owned_tab,
                            foreign_buffer = foreign_buffer,
                        }
                    end
                end
            end
        end
    until tabpage == vim.api.nvim_get_current_tabpage()

    if gsw == nil and open_in_tab then
        root = root or git.root()
        for owned_tab, candidate in pairs(windows) do
            if
                candidate.tabpage == owned_tab
                and vim.api.nvim_tabpage_is_valid(owned_tab)
                and has_valid_status_buffer(candidate)
                and candidate.root == root
            then
                gsw = candidate
                break
            end
        end
    end

    if gsw ~= nil then
        gsw:show()
        gsw:refresh()
    else
        local GitStatusWindow = require('minifugit.ui.status')
        local options = vim.tbl_deep_extend('force', vim.deepcopy(M.options), {
            status = { open_in_tab = open_in_tab },
        })
        if reusable_tab ~= nil then
            options._status_tab = reusable_tab
        end
        gsw = GitStatusWindow.new(options, root)
        register_window(gsw.tabpage or tabpage, gsw)
    end

    if opts.on_close ~= nil then
        table.insert(gsw.on_close_callbacks, opts.on_close)
    end

    log.info(string.format('Window opened win=%d buf=%d', gsw.win, gsw.buf.id))
    return true
end

function M.status()
    M.open({})
end

---@param opts MinifugitOptions?
function M.setup(opts)
    M.did_setup = true
    M.options = resolve_options(opts)

    return M
end

return M
