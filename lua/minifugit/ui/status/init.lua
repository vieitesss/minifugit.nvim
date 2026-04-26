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
---@field win number?
---@field target_win number?
---@field groups table<string, string>
---@field highlights table<string, Highlight>
---@field lines MiniFugitRenderLine[]
---@field show_help boolean
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

function GitStatusWindow:show()
    if not self.buf or not self.buf:is_valid() then
        log.error('Cannot show invalid GitStatus buffer')
        return
    end

    window.set_target_win(self, vim.api.nvim_get_current_win())

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        return
    end

    self.win = window.create_status_win(self.buf)
    selection.move_to_first_entry(self)
end

---@param state? GitStatusCursorState
---@return boolean
function GitStatusWindow:refresh(state)
    state = state or selection.capture_cursor_state(self)

    self:render()
    selection.restore_cursor_state(self, state)
    preview.refresh_current_entry(self)

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
function GitStatusWindow:enter_entry()
    local entry = selection.current_entry(self)

    if entry == nil then
        common.notify_warn('No git status entry under cursor')
        return false
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

    self.win = window.create_status_win(self.buf)
    selection.move_to_first_entry(self)

    return self
end

return GitStatusWindow
