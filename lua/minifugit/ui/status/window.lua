local log = require('minifugit.log')
local common = require('minifugit.ui.status.common')

local M = {}

---@class GitStatusWindowOptions
---@field number boolean
---@field relativenumber boolean
---@field signcolumn string
---@field foldcolumn string
---@field wrap boolean
---@field cursorline boolean
---@field winfixwidth boolean
---@field winbar string
---@field diff boolean
---@field fillchars string
---@field statuscolumn string
---@field scrollbind boolean
---@field cursorbind boolean

---@param opts MinifugitStatusOptions
---@return integer
function M.status_win_width(opts)
    return math.max(math.floor(vim.o.columns * opts.width), opts.min_width)
end

---@param tabpage number
---@return integer
function M.normal_window_count(tabpage)
    local count = 0

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_get_config(win).relative == '' then
            count = count + 1
        end
    end

    return count
end

---@param entry GitStatusEntry
---@param root string
---@return string
local function entry_path(entry, root)
    if root == '' then
        return vim.fn.fnamemodify(entry.path, ':p')
    end

    return vim.fs.normalize(vim.fs.joinpath(root, entry.path))
end

---Set a window-local option WITHOUT touching the global default.
---`vim.wo[win].opt = val` clobbers the global value of a window-local option
---when `win` is the current window, which would leak the status/diff window's
---stripped settings (nonumber, etc.) onto every window opened afterwards.
---@param win number
---@param name string
---@param value any
local function set_win_local(win, name, value)
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
end

---@param win number
function M.configure_status_win(win)
    set_win_local(win, 'number', false)
    set_win_local(win, 'relativenumber', false)
    set_win_local(win, 'signcolumn', 'no')
    set_win_local(win, 'foldcolumn', '0')
    set_win_local(win, 'wrap', false)
    set_win_local(win, 'cursorline', true)
    set_win_local(win, 'winfixwidth', true)
    set_win_local(win, 'winbar', '')
end

---@param buf Buffer
---@param opts MinifugitStatusOptions
---@param tabpage number? Existing owned tabpage to reuse.
---@return number
---@return GitStatusWindowOptions
---@return number? target_win
---@return number? placeholder_buf
function M.create_status_win(buf, opts, tabpage)
    local width = M.status_win_width(opts)
    local target_win
    local placeholder_buf

    if opts.open_in_tab then
        if tabpage ~= nil and vim.api.nvim_tabpage_is_valid(tabpage) then
            vim.api.nvim_set_current_tabpage(tabpage)
        else
            vim.cmd('tabnew')
            target_win = vim.api.nvim_get_current_win()
            placeholder_buf = vim.api.nvim_get_current_buf()
        end
    end

    vim.cmd('topleft ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()
    local prev_winopts = M.capture_winopts(win)

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)
    M.configure_status_win(win)

    log.info(string.format('created status window win=%d buf=%d', win, buf.id))

    return win, prev_winopts, target_win, placeholder_buf
end

---@param win number
---@return boolean
local function has_winfixbuf(win)
    local ok, value = pcall(function()
        return vim.wo[win].winfixbuf
    end)

    return ok and value
end

---@param win number
---@return boolean
local function is_normal_edit_window(win)
    local config = vim.api.nvim_win_get_config(win)

    if config.relative ~= '' then
        return false
    end

    if
        vim.wo[win].previewwindow
        or vim.wo[win].winfixwidth
        or has_winfixbuf(win)
    then
        return false
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.bo[buf].buftype
    local filetype = vim.bo[buf].filetype

    if buftype ~= '' and buftype ~= 'acwrite' then
        return false
    end

    if filetype == 'gitcommit' or filetype == 'gitrebase' then
        return false
    end

    return true
end

---@param self GitStatusWindow
---@param win number?
---@return boolean
local function is_usable_target_win(self, win)
    if win == nil or not common.is_valid_win(win) or win == self.win then
        return false
    end

    ---@type integer
    local target_win = win
    local is_current_tab = vim.api.nvim_win_get_tabpage(target_win)
        == vim.api.nvim_get_current_tabpage()

    if not is_current_tab then
        return false
    end

    return is_normal_edit_window(target_win)
end

---@param self GitStatusWindow
---@param win number?
function M.set_target_win(self, win)
    if is_usable_target_win(self, win) then
        self.target_win = win
    end
end

---@param start_win number?
---@return number[]
local function windows_before(start_win)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local start = 1

    for i, win in ipairs(wins) do
        if win == start_win then
            start = i
            break
        end
    end

    local ordered = {}

    for offset = 1, #wins do
        local index = ((start - offset - 1) % #wins) + 1
        table.insert(ordered, wins[index])
    end

    return ordered
end

---@param self GitStatusWindow
---@return number?
function M.find_target_win(self)
    if is_usable_target_win(self, self.target_win) then
        return self.target_win
    end

    self.target_win = nil

    for _, win in ipairs(windows_before(self.win)) do
        if is_usable_target_win(self, win) then
            self.target_win = win
            return win
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@return boolean
function M.open_entry(self, entry)
    local path = entry_path(entry, self.root)

    if vim.uv.fs_stat(path) == nil then
        log.error('Cannot open missing worktree path: ' .. path)
        vim.notify(
            '[minifugit] Cannot open missing worktree path: ' .. entry.path,
            vim.log.levels.WARN
        )
        return false
    end

    local target_win = M.find_target_win(self)

    if target_win == nil then
        vim.cmd('rightbelow vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
    else
        vim.api.nvim_set_current_win(target_win)
    end

    local current_path = vim.fs.normalize(
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win))
    )

    if current_path ~= path then
        local finish_related_open = self:begin_related_buffer_open()
        local ok, err = pcall(function()
            vim.cmd('edit ' .. vim.fn.fnameescape(path))
        end)
        finish_related_open(ok and vim.api.nvim_get_current_buf() or nil)

        if not ok then
            common.notify_error(tostring(err), 'Cannot open worktree path')
            return false
        end
    else
        self:mark_related_buffer(vim.api.nvim_win_get_buf(target_win))
    end

    return true
end

---@param win number
function M.configure_diff_win(win)
    set_win_local(win, 'number', false)
    set_win_local(win, 'relativenumber', false)
    set_win_local(win, 'signcolumn', 'no')
    set_win_local(win, 'foldcolumn', '0')
    set_win_local(win, 'wrap', false)
    set_win_local(win, 'cursorline', false)
    set_win_local(win, 'winfixwidth', false)
end

---@param win number
function M.configure_split_diff_win(win)
    set_win_local(win, 'number', true)
    set_win_local(win, 'relativenumber', false)
    set_win_local(win, 'signcolumn', 'yes:1')
    set_win_local(win, 'foldcolumn', '0')
    set_win_local(win, 'statuscolumn', '%l %s ')
    set_win_local(win, 'wrap', false)
    set_win_local(win, 'cursorline', false)
    set_win_local(win, 'winfixwidth', false)
end

---@param win number
---@return GitStatusWindowOptions
function M.capture_winopts(win)
    return {
        number = vim.wo[win].number,
        relativenumber = vim.wo[win].relativenumber,
        signcolumn = vim.wo[win].signcolumn,
        foldcolumn = vim.wo[win].foldcolumn,
        wrap = vim.wo[win].wrap,
        cursorline = vim.wo[win].cursorline,
        winfixwidth = vim.wo[win].winfixwidth,
        winbar = vim.wo[win].winbar,
        diff = vim.wo[win].diff,
        fillchars = vim.wo[win].fillchars,
        statuscolumn = vim.wo[win].statuscolumn,
        scrollbind = vim.wo[win].scrollbind,
        cursorbind = vim.wo[win].cursorbind,
    }
end

---@param win number
---@param opts GitStatusWindowOptions?
function M.restore_winopts(win, opts)
    if opts == nil or not common.is_valid_win(win) then
        return
    end

    set_win_local(win, 'number', opts.number)
    set_win_local(win, 'relativenumber', opts.relativenumber)
    set_win_local(win, 'signcolumn', opts.signcolumn)
    set_win_local(win, 'foldcolumn', opts.foldcolumn)
    set_win_local(win, 'wrap', opts.wrap)
    set_win_local(win, 'cursorline', opts.cursorline)
    set_win_local(win, 'winfixwidth', opts.winfixwidth)
    set_win_local(win, 'winbar', opts.winbar)
    set_win_local(win, 'diff', opts.diff)
    set_win_local(win, 'fillchars', opts.fillchars)
    set_win_local(win, 'statuscolumn', opts.statuscolumn)
    set_win_local(win, 'scrollbind', opts.scrollbind)
    set_win_local(win, 'cursorbind', opts.cursorbind)
end

return M
