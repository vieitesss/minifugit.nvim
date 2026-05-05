local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local render = require('minifugit.ui.render')
local formatting = require('minifugit.ui.status.formatting')
local log = require('minifugit.log')
local actions = require('minifugit.ui.status.actions')
local common = require('minifugit.ui.status.common')
local keymaps = require('minifugit.ui.status.keymaps')
local preview = require('minifugit.ui.status.preview')
local selection = require('minifugit.ui.status.selection')
local window = require('minifugit.ui.status.window')
local git = require('minifugit.git')

---@class GitStatusWindow
---@field buf Buffer
---@field diff_buf Buffer?
---@field diff_win number?
---@field diff_prev_buf number?
---@field diff_created_win boolean
---@field diff_preview_key string?
---@field diff_prev_winopts GitStatusWindowOptions?
---@field win number?
---@field win_prev_winopts GitStatusWindowOptions?
---@field target_win number?
---@field groups table<string, string>
---@field highlights table<string, { ensure: fun() }>
---@field lines MiniFugitRenderLine[]
---@field show_help boolean
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

local HIGHLIGHT_NAMESPACE = 'GitStatusWindow'

local DIFF_HEADER_GROUP = 'MiniFugitDiffHeader'
local DIFF_HUNK_HEADER_GROUP = 'MiniFugitDiffHunkHeader'

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
        sources = { 'DiffAdd', 'Added', 'String' },
        fallback_bg = 0x2E4D33,
    },
    diff_removed = {
        name = 'MiniFugitDiffRemoved',
        sources = { 'DiffDelete', 'Removed', 'Error' },
        fallback_bg = 0x5A2D34,
    },
    unpushed = {
        name = 'MiniFugitUnpushed',
        sources = { 'Constant', 'Number' },
        fallback_fg = 0xD19A66,
    },
}

---@return vim.api.keyset.highlight
local function diff_header_style()
    if vim.o.background == 'light' then
        return {
            fg = 0x8A8A8A,
            ctermfg = 245,
        }
    end

    return {
        fg = 0x6C7086,
        ctermfg = 243,
    }
end

---@return vim.api.keyset.highlight
local function diff_hunk_header_style()
    if vim.o.background == 'light' then
        return {
            fg = 0x5F6B7A,
            ctermfg = 60,
        }
    end

    return {
        fg = 0x7A88A1,
        ctermfg = 67,
    }
end

---@param name string
---@param style fun(): vim.api.keyset.highlight
---@return { ensure: fun() }
local function create_fixed_highlight(name, style)
    return {
        ensure = function()
            vim.api.nvim_set_hl(0, name, style())
        end,
    }
end

---@return table<string, string>
local function create_highlight_groups()
    local groups = {}

    for key, spec in pairs(HIGHLIGHT_SPECS) do
        groups[key] = spec.name
    end

    groups.diff_header = DIFF_HEADER_GROUP
    groups.diff_hunk_header = DIFF_HUNK_HEADER_GROUP

    return groups
end

---@return table<string, { ensure: fun() }>
local function create_highlights()
    local highlights = {}

    for key, spec in pairs(HIGHLIGHT_SPECS) do
        highlights[key] = Highlight.new({
            namespace = HIGHLIGHT_NAMESPACE,
            name = spec.name,
            sources = spec.sources,
            fallback_fg = spec.fallback_fg,
            fallback_bg = spec.fallback_bg,
        })
    end

    highlights.diff_header =
        create_fixed_highlight(DIFF_HEADER_GROUP, diff_header_style)
    highlights.diff_hunk_header =
        create_fixed_highlight(DIFF_HUNK_HEADER_GROUP, diff_hunk_header_style)

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
local function release_status_win(self)
    if self.win == nil then
        return
    end

    local win = self.win

    if common.is_valid_win(win) then
        if vim.api.nvim_win_get_buf(win) == self.buf.id then
            return
        end

        window.restore_winopts(win, self.win_prev_winopts)
    end

    self.win = nil
    self.win_prev_winopts = nil
end

---@param self GitStatusWindow
local function refresh_highlights(self)
    ensure_highlights(self)

    if self.buf ~= nil and self.buf:is_valid() then
        render.apply(self.buf.id, self.lines)
    end

    if
        self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and preview.has_open_diff(self)
    then
        preview.refresh_current_entry(self)
    end
end

---@param self GitStatusWindow
local function ensure_autocmds(self)
    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        buffer = self.buf.id,
        callback = function()
            vim.schedule(function()
                if self.buf ~= nil and self.buf:is_valid() then
                    release_status_win(self)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd('ColorScheme', {
        callback = function()
            refresh_highlights(self)
        end,
    })

    vim.api.nvim_create_autocmd('OptionSet', {
        pattern = 'background',
        callback = function()
            refresh_highlights(self)
        end,
    })
end

function GitStatusWindow:show()
    if not self.buf or not self.buf:is_valid() then
        log.error('Cannot show invalid GitStatus buffer')
        return
    end

    if
        self.win
        and common.is_valid_win(self.win)
        and vim.api.nvim_win_get_buf(self.win) ~= self.buf.id
    then
        release_status_win(self)
    end

    window.set_target_win(self, vim.api.nvim_get_current_win())

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        return
    end

    self.win, self.win_prev_winopts = window.create_status_win(self.buf)
    selection.move_to_first_entry(self)
end

---@param state? GitStatusCursorState
---@return boolean
function GitStatusWindow:refresh(state)
    state = state or selection.capture_cursor_state(self)

    self:render()
    selection.restore_cursor_state(self, state)
    preview.refresh_current_entry(self, state)

    return true
end

---@return boolean
function GitStatusWindow:diff_entry()
    return preview.preview_current_entry(self, {
        force = true,
        notify = true,
    })
end

---@return boolean
function GitStatusWindow:stage_entry()
    return actions.stage_entry(self)
end

---@return boolean
function GitStatusWindow:unstage_entry()
    return actions.unstage_entry(self)
end

---@return boolean
function GitStatusWindow:stage_all_entries()
    return actions.stage_all_entries(self)
end

---@return boolean
function GitStatusWindow:unstage_all_entries()
    return actions.unstage_all_entries(self)
end

---@return boolean
function GitStatusWindow:stage_selected_entries()
    return actions.stage_selected_entries(self)
end

---@return boolean
function GitStatusWindow:unstage_selected_entries()
    return actions.unstage_selected_entries(self)
end

---@param force boolean
---@return boolean
function GitStatusWindow:discard_entry(force)
    return actions.discard_entry(self, force)
end

---@return boolean
function GitStatusWindow:commit()
    return actions.commit(self)
end

---@return boolean
function GitStatusWindow:push()
    return actions.push(self)
end

---@return boolean
function GitStatusWindow:enter_entry()
    local entry = selection.current_entry(self)

    if entry == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    return window.open_entry(self, entry)
end

function GitStatusWindow:toggle_help()
    self.show_help = not self.show_help
    self:refresh()
end

function GitStatusWindow:render()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    self.lines = formatting.render(git.status_snapshot(), self.groups, {
        show_help = self.show_help,
    })

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
    self.diff_created_win = false
    self.show_help = false
    self.target_win = vim.api.nvim_get_current_win()

    ensure_highlights(self)

    ---@type BufferOpts
    local opts = { listed = false, scratch = true, name = 'Minifugit' }
    self.buf = Buffer.new(opts)
    vim.bo[self.buf.id].buftype = 'nofile'
    vim.bo[self.buf.id].bufhidden = 'hide'
    vim.bo[self.buf.id].swapfile = false
    vim.bo[self.buf.id].filetype = 'minifugit'

    keymaps.attach(self)
    self:render()

    self.win, self.win_prev_winopts = window.create_status_win(self.buf)
    selection.move_to_first_entry(self)
    ensure_autocmds(self)

    return self
end

return GitStatusWindow
