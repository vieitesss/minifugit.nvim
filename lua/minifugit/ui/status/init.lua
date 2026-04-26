local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local render = require('minifugit.ui.render')
local formatting = require('minifugit.ui.status.formatting')
local log = require('minifugit.log')
local git = require('minifugit.git')

---@class GitStatusWindow
---@field buf Buffer
---@field diff_buf Buffer?
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
    diff_added = {
        name = 'MiniFugitDiffAdded',
        sources = { 'Added', 'String' },
        fallback_fg = 0x98C379,
    },
    diff_removed = {
        name = 'MiniFugitDiffRemoved',
        sources = { 'Removed', 'Error' },
        fallback_fg = 0xE06C75,
    },
}

---@param win number?
---@return boolean
local function is_valid_win(win)
    return type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win)
end

---@return integer
local function status_win_height()
    return math.max(math.floor(vim.o.lines * 0.3), 5)
end

---@param buf Buffer
---@return number
local function create_win(buf)
    local height = status_win_height()

    vim.cmd('botright ' .. height .. 'split')

    local win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixheight = true

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

---@param lines string[]
---@param groups table<string, string>
---@return MiniFugitRenderLine[]
local function diff_render_lines(lines, groups)
    return vim.tbl_map(function(text)
        local line = render.line(text)

        if vim.startswith(text, '+') and not vim.startswith(text, '+++') then
            render.add_highlight(line, groups.diff_added, 0, #text)
        elseif
            vim.startswith(text, '-') and not vim.startswith(text, '---')
        then
            render.add_highlight(line, groups.diff_removed, 0, #text)
        end

        return line
    end, lines)
end

---@return table<string, string>
local function create_highlight_groups()
    local groups = {}

    for key, spec in pairs(HIGHLIGHT_SPECS) do
        groups[key] = spec.name
    end

    return groups
end

---@return table<string, Highlight>
local function create_highlights()
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

---@param self GitStatusWindow
local function ensure_highlights(self)
    assert(self.highlights ~= nil)

    for _, h in pairs(self.highlights) do
        h:ensure()
    end
end

---@param self GitStatusWindow
---@param win number?
local function set_target_win(self, win)
    if is_valid_win(win) and win ~= self.win then
        self.target_win = win
    end
end

---@param self GitStatusWindow
---@return number?
local function find_target_win(self)
    if
        is_valid_win(self.target_win)
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
---@return MiniFugitRenderLine?
local function current_line(self)
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

---@param self GitStatusWindow
---@return GitStatusEntry?
local function current_entry(self)
    local line = current_line(self)

    if line == nil or type(line.data) ~= 'table' then
        return nil
    end

    return line.data
end

---@param self GitStatusWindow
---@param start_row integer
---@param end_row integer
---@return GitStatusEntry[]
local function entries_in_range(self, start_row, end_row)
    local entries = {}
    local first = math.min(start_row, end_row)
    local last = math.max(start_row, end_row)

    for row = first, last do
        local line = self.lines[row]

        if line ~= nil and type(line.data) == 'table' then
            table.insert(entries, line.data)
        end
    end

    return entries
end

---@param self GitStatusWindow
---@return GitStatusEntry[]
local function all_entries(self)
    return entries_in_range(self, 1, #self.lines)
end

---@param self GitStatusWindow
---@return integer?
local function first_entry_row(self)
    for row, line in ipairs(self.lines) do
        if type(line.data) == 'table' then
            return row
        end
    end

    return nil
end

---@param self GitStatusWindow
---@return GitStatusEntry[]
local function selected_entries(self)
    local mode = vim.fn.mode()
    local start_row
    local end_row

    if mode == 'v' or mode == 'V' or mode == '\22' then
        start_row = vim.fn.line('v')
        end_row = vim.fn.line('.')
    else
        start_row = vim.fn.getpos("'<")[2]
        end_row = vim.fn.getpos("'>")[2]
    end

    return entries_in_range(self, start_row, end_row)
end

---@param self GitStatusWindow
local function ensure_keymaps(self)
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    vim.keymap.set('n', '<CR>', function()
        self:enter_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Open git status entry',
        silent = true,
    })

    vim.keymap.set('n', '=', function()
        self:diff_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Show git status entry diff',
        silent = true,
    })

    vim.keymap.set('n', 's', function()
        self:stage_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Stage git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'u', function()
        self:unstage_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'S', function()
        self:stage_all_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Stage all git status entries',
        silent = true,
    })

    vim.keymap.set('n', 'U', function()
        self:unstage_all_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage all git status entries',
        silent = true,
    })

    vim.keymap.set('n', 'c', function()
        self:commit()
    end, {
        buffer = self.buf.id,
        desc = 'Commit staged changes',
        silent = true,
    })

    vim.keymap.set('x', 's', function()
        self:stage_selected_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Stage selected git status entries',
        silent = true,
    })

    vim.keymap.set('x', 'u', function()
        self:unstage_selected_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage selected git status entries',
        silent = true,
    })
end

local move_to_first_entry

function GitStatusWindow:show()
    if not self.buf or not self.buf:is_valid() then
        log.error('Cannot show invalid GitStatus buffer')
        return
    end

    set_target_win(self, vim.api.nvim_get_current_win())

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        move_to_first_entry(self)
        return
    end

    self.win = create_win(self.buf)
    move_to_first_entry(self)
end

---@param self GitStatusWindow
move_to_first_entry = function(self)
    local row = first_entry_row(self)

    if row ~= nil and self.win ~= nil and is_valid_win(self.win) then
        vim.api.nvim_win_set_cursor(self.win, { row, 0 })
    end
end

---@param entry GitStatusEntry
---@return boolean
local function open_entry(self, entry)
    local path = entry_path(entry)

    if vim.uv.fs_stat(path) == nil then
        log.error('Cannot open missing worktree path: ' .. path)
        vim.notify(
            '[minifugit] Cannot open missing worktree path: ' .. entry.path,
            vim.log.levels.WARN
        )
        return false
    end

    local target_win = find_target_win(self)

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

---@param self GitStatusWindow
---@return Buffer
local function ensure_diff_buf(self)
    if self.diff_buf and self.diff_buf:is_valid() then
        return self.diff_buf
    end

    self.diff_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Minifugit diff',
    })

    vim.bo[self.diff_buf.id].buftype = 'nofile'
    vim.bo[self.diff_buf.id].bufhidden = 'hide'
    vim.bo[self.diff_buf.id].swapfile = false

    return self.diff_buf
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@return boolean
local function open_diff(self, entry)
    local lines = git.diff(entry)
    local diff_lines

    if #lines == 0 then
        diff_lines = { render.line('No diff for ' .. entry.path) }
    else
        diff_lines = diff_render_lines(lines, self.groups)
    end

    local buf = ensure_diff_buf(self)

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local target_win = find_target_win(self)

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
    else
        vim.api.nvim_set_current_win(target_win)
    end

    vim.api.nvim_win_set_buf(target_win, buf.id)

    return true
end

---@return boolean
function GitStatusWindow:diff_entry()
    local entry = current_entry(self)

    if entry == nil then
        return false
    end

    return open_diff(self, entry)
end

---@param action fun(entries: GitStatusEntry[]): boolean
---@param entries GitStatusEntry[]
---@return boolean
local function update_entries(self, action, entries)
    local win = self.win

    if #entries == 0 or not win or not is_valid_win(win) then
        return false
    end

    local row = vim.api.nvim_win_get_cursor(win)[1]

    if not action(entries) then
        return false
    end

    self:render()
    vim.api.nvim_win_set_cursor(win, { math.min(row, #self.lines), 0 })

    return true
end

---@param action fun(entries: GitStatusEntry[]): boolean
---@return boolean
local function update_entry(self, action)
    local entry = current_entry(self)

    if entry == nil then
        return false
    end

    return update_entries(self, action, { entry })
end

---@return boolean
function GitStatusWindow:stage_entry()
    return update_entry(self, git.stage_entries)
end

---@return boolean
function GitStatusWindow:unstage_entry()
    return update_entry(self, git.unstage_entries)
end

---@return boolean
function GitStatusWindow:stage_all_entries()
    return update_entries(self, git.stage_entries, all_entries(self))
end

---@return boolean
function GitStatusWindow:unstage_all_entries()
    return update_entries(self, git.unstage_entries, all_entries(self))
end

---@return boolean
function GitStatusWindow:stage_selected_entries()
    return update_entries(self, git.stage_entries, selected_entries(self))
end

---@return boolean
function GitStatusWindow:unstage_selected_entries()
    return update_entries(self, git.unstage_entries, selected_entries(self))
end

function GitStatusWindow:commit()
    if self.win == nil or not is_valid_win(self.win) then
        return false
    end

    local path = vim.fn.tempname() .. '.gitcommit'
    vim.fn.writefile(git.commit_template(), path)

    vim.api.nvim_set_current_win(self.win)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.bo.filetype = 'gitcommit'

    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = vim.api.nvim_get_current_buf(),
        callback = function(args)
            local ok, output = git.commit_file(path)
            local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR

            vim.notify('[minifugit] ' .. output, level)

            if not ok then
                return false
            end

            self:render()

            if self.win ~= nil and is_valid_win(self.win) then
                vim.api.nvim_win_set_buf(self.win, self.buf.id)
            end

            if vim.api.nvim_buf_is_valid(args.buf) then
                vim.api.nvim_buf_delete(args.buf, { force = true })
            end

            vim.fn.delete(path)

            return true
        end,
    })

    return true
end

---@return boolean
function GitStatusWindow:enter_entry()
    local entry = current_entry(self)

    if entry == nil then
        return false
    end

    return open_entry(self, entry)
end

function GitStatusWindow:render()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    self.lines = formatting.render(git.status_snapshot(), self.groups)

    vim.bo[self.buf.id].modifiable = true
    self.buf:set_lines(render.text_lines(self.lines))
    vim.bo[self.buf.id].modifiable = false
    render.apply(self.buf.id, self.lines)
end

---@return GitStatusWindow
function GitStatusWindow.new()
    local self = setmetatable({}, GitStatusWindow)

    self.groups = create_highlight_groups()
    self.highlights = create_highlights()
    self.lines = {}
    self.target_win = vim.api.nvim_get_current_win()

    ensure_highlights(self)

    ---@type BufferOpts
    local opts = { listed = false, scratch = true, name = 'Minifugit' }
    self.buf = Buffer.new(opts)
    vim.bo[self.buf.id].buftype = 'nofile'
    vim.bo[self.buf.id].bufhidden = 'hide'
    vim.bo[self.buf.id].swapfile = false
    vim.bo[self.buf.id].filetype = 'minifugit'

    ensure_keymaps(self)
    self:render()

    self.win = create_win(self.buf)

    return self
end

return GitStatusWindow
