local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local render = require('minifugit.ui.render')
local formatting = require('minifugit.ui.status.formatting')
local log = require('minifugit.log')
local git = require('minifugit.git')

---@class GitStatusWindow
---@field buf Buffer
---@field win number?
---@field target_win number?
---@field groups table<string, string>
---@field highlights table<string, Highlight>
---@field lines MiniFugitRenderLine[]
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

local HIGHLIGHT_NAMESPACE = 'GitStatusWindow'

local HIGHLIGHT_SPECS = {
    staged = {
        name = 'MiniFugitStage',
        sources = { 'Added', 'String' },
        fallback_fg = 0x98C379,
    },
    unstaged = {
        name = 'MiniFugitUnstage',
        sources = { 'Removed', 'Error' },
        fallback_fg = 0xE06C75,
    },
    untracked = {
        name = 'MiniFugitUntracked',
        sources = { 'DiagnosticInfo', 'Directory', 'Identifier' },
        fallback_fg = 0x61AFEF,
    },
    ignored = {
        name = 'MiniFugitIgnored',
        sources = { 'Comment' },
        fallback_fg = 0x5C6370,
    },
    conflict = {
        name = 'MiniFugitConflict',
        sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
        fallback_fg = 0xE06C75,
    },
    head = {
        name = 'MiniFugitHead',
        sources = { 'Identifier', 'Keyword' },
        fallback_fg = 0x61AFEF,
    },
}

---@param win number?
---@return boolean
local function is_valid_win(win)
    return type(win) == 'number'
        and win > 0
        and vim.api.nvim_win_is_valid(win)
end

---@param buf Buffer
---@return number
local function create_win(buf)
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd('botright ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)

    log.info(string.format('created status window win=%d buf=%d', win, buf.id))

    return win
end

---@param entry GitStatusEntry
---@return string
local function entry_path(entry)
    local root = git.root()

    if root == '' then
        return vim.fn.fnamemodify(entry.path, ':p')
    end

    return vim.fs.normalize(vim.fs.joinpath(root, entry.path))
end

---@return table<string, string>
function GitStatusWindow:create_highlight_groups()
    local groups = {}

    for key, spec in pairs(HIGHLIGHT_SPECS) do
        groups[key] = spec.name
    end

    return groups
end

---@return table<string, Highlight>
function GitStatusWindow:create_highlights()
    local highlights = {}

    for key, spec in pairs(HIGHLIGHT_SPECS) do
        highlights[key] = Highlight.new({
            namespace = HIGHLIGHT_NAMESPACE,
            name = spec.name,
            sources = spec.sources,
            fallback_fg = spec.fallback_fg,
        })
    end

    return highlights
end

function GitStatusWindow:highlights_ensure()
    assert(self.highlights ~= nil)

    for _, h in pairs(self.highlights) do
        h:ensure()
    end
end

---@param win number?
function GitStatusWindow:set_target_win(win)
    if is_valid_win(win) and win ~= self.win then
        self.target_win = win
    end
end

---@return number?
function GitStatusWindow:find_target_win()
    if is_valid_win(self.target_win)
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

---@return MiniFugitRenderLine?
function GitStatusWindow:current_line()
    if not self.buf or not self.buf:is_valid() then
        return nil
    end

    local win = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_get_buf(win) ~= self.buf.id then
        if not is_valid_win(self.win) then
            return nil
        end

        win = self.win
    end

    assert(win ~= nil, 'Cannot get current line from nil window')

    local row = vim.api.nvim_win_get_cursor(win)[1]

    return self.lines[row]
end

---@return GitStatusEntry?
function GitStatusWindow:current_entry()
    local line = self:current_line()

    if line == nil or type(line.data) ~= 'table' then
        return nil
    end

    return line.data
end

function GitStatusWindow:ensure_keymaps()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    vim.keymap.set('n', '<CR>', function()
        self:enter_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Open git status entry',
        silent = true,
    })
end

function GitStatusWindow:show()
    if not self.buf or not self.buf:is_valid() then
        log.error('Cannot show invalid GitStatus buffer')
        return
    end

    self:set_target_win(vim.api.nvim_get_current_win())

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        return
    end

    self.win = create_win(self.buf)
end

---@param entry GitStatusEntry
---@return boolean
function GitStatusWindow:open_entry(entry)
    local path = entry_path(entry)

    if vim.uv.fs_stat(path) == nil then
        log.error('Cannot open missing worktree path: ' .. path)
        vim.notify(
            '[minifugit] Cannot open missing worktree path: ' .. entry.path,
            vim.log.levels.WARN
        )
        return false
    end

    local target_win = self:find_target_win()

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
    else
        vim.api.nvim_set_current_win(target_win)
    end

    vim.cmd('edit ' .. vim.fn.fnameescape(path))

    return true
end

---@return boolean
function GitStatusWindow:enter_entry()
    local entry = self:current_entry()

    if entry == nil then
        return false
    end

    return self:open_entry(entry)
end

function GitStatusWindow:render()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    self.lines = formatting.render(git.branch(), git.status(), self.groups)

    self.buf:set_lines(render.text_lines(self.lines))
    render.apply(self.buf.id, self.lines)
end

---@return GitStatusWindow
function GitStatusWindow.new()
    local self = setmetatable({}, GitStatusWindow)

    self.groups = self:create_highlight_groups()
    self.highlights = self:create_highlights()
    self.lines = {}
    self.target_win = vim.api.nvim_get_current_win()

    self:highlights_ensure()

    ---@type BufferOpts
    local opts = { listed = true, scratch = true, name = 'Minifugit' }
    self.buf = Buffer.new(opts)

    self:ensure_keymaps()
    self:render()

    self.win = create_win(self.buf)

    return self
end

return GitStatusWindow
