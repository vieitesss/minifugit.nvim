local log = require('minifugit.log')
local git = require('minifugit.git')
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

---@param opts MinifugitStatusOptions
---@return integer
local function status_win_width(opts)
    return math.max(math.floor(vim.o.columns * opts.width), opts.min_width)
end

---@param entry GitStatusEntry
---@return string
local function entry_path(entry)
    local root = git.root();

    if root == '' then
        return vim.fn.fnamemodify(entry.path, ':p')
    end

    return vim.fs.normalize(vim.fs.joinpath(root, entry.path))
end

---@param buf Buffer
---@param opts MinifugitStatusOptions
---@return number, GitStatusWindowOptions
function M.create_status_win(buf, opts)
    local width = status_win_width(opts)

    vim.cmd('topleft ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()
    local prev_winopts = M.capture_winopts(win)

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixwidth = true

    log.info(string.format('created status window win=%d buf=%d', win, buf.id))

    return win, prev_winopts
end

---@param self GitStatusWindow
---@param win number?
function M.set_target_win(self, win)
    if common.is_valid_win(win) and win ~= self.win then
        self.target_win = win
    end
end

---@param self GitStatusWindow
---@return number?
function M.find_target_win(self)
    if
        common.is_valid_win(self.target_win)
        and self.target_win ~= self.win
        and vim.api.nvim_win_get_tabpage(self.target_win)
            == vim.api.nvim_get_current_tabpage()
    then
        return self.target_win
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= self.win and vim.api.nvim_win_is_valid(win) then
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
    local path = entry_path(entry)

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

    vim.cmd('edit ' .. vim.fn.fnameescape(path))

    return true
end

---@param win number
function M.configure_diff_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
end

---@param win number
function M.configure_split_diff_win(win)
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'yes:1'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].statuscolumn = '%l %s '
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.api.nvim_win_call(win, function()
        vim.opt_local.fillchars:append({ diff = ' ' })
    end)
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
    }
end

---@param win number
---@param opts GitStatusWindowOptions?
function M.restore_winopts(win, opts)
    if opts == nil or not common.is_valid_win(win) then
        return
    end

    vim.wo[win].number = opts.number
    vim.wo[win].relativenumber = opts.relativenumber
    vim.wo[win].signcolumn = opts.signcolumn
    vim.wo[win].foldcolumn = opts.foldcolumn
    vim.wo[win].wrap = opts.wrap
    vim.wo[win].cursorline = opts.cursorline
    vim.wo[win].winfixwidth = opts.winfixwidth
    vim.wo[win].winbar = opts.winbar
    vim.wo[win].diff = opts.diff
    vim.wo[win].fillchars = opts.fillchars
    vim.wo[win].statuscolumn = opts.statuscolumn
end

return M
