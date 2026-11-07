---@class MinifugitStatusRequest
---@field root string? Explicit root; nil preserves a visible window's pin.
---@field base string? Pinned commit hash; nil selects normal status.
---@field options MinifugitOptions Resolved options including the tab override.
---@field on_close fun()? Scheduled once when the status window stops showing.

---Owns the per-tabpage status instances of one entrypoint.
---@class MinifugitStatusRegistry
---@field windows table<integer, GitStatusWindow>
local StatusRegistry = {}
StatusRegistry.__index = StatusRegistry

---@return MinifugitStatusRegistry
function StatusRegistry.new()
    return setmetatable({ windows = {} }, StatusRegistry)
end

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

---@param self MinifugitStatusRegistry
---@param tabpage integer
---@param gsw GitStatusWindow?
local function unregister_window(self, tabpage, gsw)
    if gsw == nil or self.windows[tabpage] ~= gsw then
        return
    end

    local ok, destroyed = pcall(function()
        return gsw:destroy()
    end)

    if ok and destroyed then
        self.windows[tabpage] = nil
    end
end

---@param self MinifugitStatusRegistry
---@param tabpage integer
---@return GitStatusWindow?
local function status_window(self, tabpage)
    local gsw = self.windows[tabpage]
    if gsw ~= nil and not has_valid_status_buffer(gsw) then
        unregister_window(self, tabpage, gsw)
    end

    return self.windows[tabpage]
end

---@param self MinifugitStatusRegistry
---@param tabpage integer
---@param gsw GitStatusWindow
local function register_window(self, tabpage, gsw)
    self.windows[tabpage] = gsw

    local function update_tabpage()
        if
            self.windows[tabpage] ~= gsw
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

        local previous = self.windows[destination]
        if previous ~= nil and previous ~= gsw then
            previous.tabpage = nil
            unregister_window(self, destination, previous)
        end

        self.windows[tabpage] = nil
        self.windows[destination] = gsw
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
                unregister_window(self, tabpage, gsw)
            end)
        end,
    })
    vim.api.nvim_create_autocmd('TabClosed', {
        group = gsw.autocmd_group,
        callback = function()
            vim.schedule(function()
                update_tabpage()
                if not vim.api.nvim_tabpage_is_valid(tabpage) then
                    unregister_window(self, tabpage, gsw)
                end
            end)
        end,
    })
end

---@param request MinifugitStatusRequest
---@return GitStatusWindow
function StatusRegistry:open(request)
    local git = require('minifugit.git')
    local root = request.root
    local base = request.base
    local open_in_tab = request.options.status.open_in_tab
    local explicit_root = root ~= nil
    local tabpage
    local gsw
    local reusable_tab
    local exposed = false
    -- Destroying an owned tab can expose another registered status window.
    -- Only the instance selected first may be replaced; an exposed one is
    -- reused when it matches and otherwise left alone.
    repeat
        tabpage = vim.api.nvim_get_current_tabpage()
        gsw = status_window(self, tabpage)

        if gsw ~= nil then
            local hidden = #vim.fn.win_findbuf(gsw.buf.id) == 0
            if explicit_root or hidden then
                root = root or git.root()

                if
                    root ~= gsw.root
                    or ((hidden or base ~= nil) and gsw.base ~= base)
                    or (
                        hidden
                        and gsw.options.status.open_in_tab ~= open_in_tab
                    )
                then
                    if exposed then
                        gsw = nil
                        -- The exposed tab keeps its window, so the new one
                        -- needs a tab of its own.
                        open_in_tab = true
                    else
                        local owned_tab = gsw.tabpage
                        local foreign_buffer = gsw.tab_foreign_buffer
                        local repinned = root ~= gsw.root
                        unregister_window(self, tabpage, gsw)
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
        end
        local reselected = false
        if
            gsw == nil
            and open_in_tab
            and tabpage == vim.api.nvim_get_current_tabpage()
        then
            root = root or git.root()
            for owned_tab, candidate in pairs(self.windows) do
                if
                    candidate.tabpage == owned_tab
                    and vim.api.nvim_tabpage_is_valid(owned_tab)
                    and has_valid_status_buffer(candidate)
                    and candidate.root == root
                then
                    -- Re-select in the owned tab so replacement uses the same
                    -- destroy path, including any newly exposed status window.
                    vim.api.nvim_set_current_tabpage(owned_tab)
                    gsw = candidate
                    reselected = true
                    break
                end
            end
        end
        -- A tab change without a re-select came from destroying an owned tab.
        exposed = not reselected
    until tabpage == vim.api.nvim_get_current_tabpage()

    if gsw ~= nil then
        gsw:show()
        gsw:refresh()
    else
        local GitStatusWindow = require('minifugit.ui.status')
        local options = vim.deepcopy(request.options)
        -- Destroying an owned tab may force a new tab for the replacement.
        options.status.open_in_tab = open_in_tab
        gsw = GitStatusWindow.new(options, root, base, reusable_tab)
        register_window(self, gsw.tabpage or tabpage, gsw)
    end

    if request.on_close ~= nil then
        table.insert(gsw.on_close_callbacks, request.on_close)
    end

    return gsw
end

---@param tabpage integer? Tabpage to reset; defaults to the current one.
function StatusRegistry:reset(tabpage)
    tabpage = tabpage or vim.api.nvim_get_current_tabpage()
    unregister_window(self, tabpage, self.windows[tabpage])
end

return StatusRegistry
