local common = require('minifugit.ui.status.common')

local M = {}

local OWNED_BUFFER_FIELDS = {
    'buf',
    'help_buf',
}

---@param tabpage number?
---@return boolean
local function is_valid_tabpage(tabpage)
    if tabpage == nil then
        return false
    end

    for _, existing in ipairs(vim.api.nvim_list_tabpages()) do
        if existing == tabpage then
            return true
        end
    end

    return false
end

---@param self GitStatusWindow
---@return boolean
function M.uses(self)
    return self.options.status.open_in_tab == true
end

---@param self GitStatusWindow
---@param bufnr number
---@return boolean
local function is_placeholder_buffer(self, bufnr)
    return bufnr == self.tab_placeholder_buf
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_name(bufnr) == ''
        and vim.bo[bufnr].buftype == ''
end

---@param self GitStatusWindow
---@param bufnr number
---@return boolean
local function is_owned_buffer(self, bufnr)
    for _, field in ipairs(OWNED_BUFFER_FIELDS) do
        local buf = self[field]

        if buf ~= nil and buf.id == bufnr then
            return true
        end
    end

    for _, dw in ipairs({
        self.preview.stacked,
        self.preview.left,
        self.preview.right,
    }) do
        if dw ~= nil and dw.buf ~= nil and dw.buf.id == bufnr then
            return true
        end
    end

    return false
end

---@param self GitStatusWindow
---@param bufnr number
---@return boolean
local function is_related_buffer(self, bufnr)
    return is_owned_buffer(self, bufnr)
        or is_placeholder_buffer(self, bufnr)
        or (
            self.tab_related_buffers ~= nil
            and self.tab_related_buffers[bufnr] == true
        )
end

---@param tabpage number
---@param bufnr number
---@return boolean
local function tabpage_has_buffer(tabpage, bufnr)
    if not is_valid_tabpage(tabpage) then
        return false
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            return true
        end
    end

    return false
end

---@param self GitStatusWindow
---@return boolean
local function tabpage_has_workflow_buffer(self)
    if not is_valid_tabpage(self.tabpage) then
        return false
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(self.tabpage)) do
        local bufnr = vim.api.nvim_win_get_buf(win)

        if
            is_related_buffer(self, bufnr)
            and not is_placeholder_buffer(self, bufnr)
        then
            return true
        end
    end

    return false
end

---@param self GitStatusWindow
function M.setup_state(self)
    self.tab_foreign_buffer = false
    self.tab_suppress_foreign = 0
    self.tab_closing = false
    self.tab_related_buffers = {}
end

---@param self GitStatusWindow
---@param bufnr number?
function M.mark_related_buffer(self, bufnr)
    if bufnr == nil or not M.uses(self) then
        return
    end

    self.tab_related_buffers = self.tab_related_buffers or {}
    self.tab_related_buffers[bufnr] = true
end

---@param self GitStatusWindow
---@return fun(bufnr: number?)
function M.begin_related_buffer_open(self)
    if not M.uses(self) then
        return function() end
    end

    self.tab_suppress_foreign = self.tab_suppress_foreign + 1

    return function(bufnr)
        M.mark_related_buffer(self, bufnr)
        self.tab_suppress_foreign = math.max(0, self.tab_suppress_foreign - 1)
    end
end

---@param self GitStatusWindow
---@return boolean
function M.close_owned_tab(self)
    if
        not M.uses(self)
        or self.tab_foreign_buffer
        or self.tab_closing
        or not is_valid_tabpage(self.tabpage)
    then
        return false
    end

    self.tab_closing = true
    local ok = pcall(function()
        local tabnr = vim.api.nvim_tabpage_get_number(self.tabpage)
        vim.cmd(tabnr .. 'tabclose')
    end)
    self.tab_closing = false

    return ok
end

---@param self GitStatusWindow
---@return boolean
function M.maybe_close(self)
    if tabpage_has_workflow_buffer(self) then
        return false
    end

    return M.close_owned_tab(self)
end

---@param self GitStatusWindow
---@param target_win number?
---@param placeholder_buf number?
function M.attach(self, target_win, placeholder_buf)
    if not M.uses(self) or self.win == nil then
        return
    end

    M.setup_state(self)
    self.tabpage = vim.api.nvim_win_get_tabpage(self.win)
    self.tab_placeholder_buf = placeholder_buf
    M.mark_related_buffer(self, self.buf.id)

    if target_win ~= nil and common.is_valid_win(target_win) then
        self.target_win = target_win
    end
end

---@param self GitStatusWindow
function M.install_autocmds(self)
    if not M.uses(self) then
        return
    end

    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'BufReadPost' }, {
        group = self.autocmd_group,
        callback = function(args)
            local bufnr = args.buf

            vim.schedule(function()
                if
                    self.tab_foreign_buffer
                    or self.tab_suppress_foreign > 0
                    or not is_valid_tabpage(self.tabpage)
                    or not tabpage_has_buffer(self.tabpage, bufnr)
                    or is_related_buffer(self, bufnr)
                then
                    return
                end

                self.tab_foreign_buffer = true
            end)
        end,
    })

    vim.api.nvim_create_autocmd({ 'WinClosed', 'BufDelete', 'BufWipeout' }, {
        group = self.autocmd_group,
        callback = function()
            vim.schedule(function()
                M.maybe_close(self)
            end)
        end,
    })
end

return M
