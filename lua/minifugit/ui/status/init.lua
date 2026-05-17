local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local render = require('minifugit.ui.render')
local formatting = require('minifugit.ui.status.formatting')
local help = require('minifugit.ui.status.help')
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
---@field diff_left_buf Buffer?
---@field diff_right_buf Buffer?
---@field diff_left_win number?
---@field diff_right_win number?
---@field diff_prev_buf number?
---@field diff_left_prev_buf number?
---@field diff_right_prev_buf number?
---@field diff_created_win boolean
---@field diff_left_created_win boolean
---@field diff_right_created_win boolean
---@field diff_preview_key string?
---@field diff_raw_lines string[]?
---@field diff_raw_rows integer[]?
---@field diff_hunks MiniFugitDiffHunk[]?
---@field diff_section GitStatusSectionName?
---@field diff_entry GitStatusEntry?
---@field diff_prev_winopts GitStatusWindowOptions?
---@field diff_left_prev_winopts GitStatusWindowOptions?
---@field diff_right_prev_winopts GitStatusWindowOptions?
---@field diff_wrap boolean
---@field diff_show_headers boolean
---@field diff_show_numbers boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_layout_override 'stacked'|'split'?
---@field help_buf Buffer?
---@field help_win number?
---@field help_prev_win number?
---@field win number?
---@field win_prev_winopts GitStatusWindowOptions?
---@field target_win number?
---@field options MinifugitOptions
---@field groups table<string, string>
---@field highlights table<string, { ensure: fun() }>
---@field lines MiniFugitRenderLine[]
---@field snapshot GitStatusSnapshot?
---@field filter string
---@field loading_message string?
---@field loading_frame integer
---@field loading_timer uv.uv_timer_t?
---@field autocmd_group integer?
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

local HIGHLIGHT_NAMESPACE = 'GitStatusWindow'

local OWNED_BUFFER_FIELDS = {
    'buf',
    'diff_buf',
    'diff_left_buf',
    'diff_right_buf',
    'help_buf',
}

local DIFF_HEADER_GROUP = 'MiniFugitDiffHeader'
local DIFF_HUNK_HEADER_GROUP = 'MiniFugitDiffHunkHeader'
local SPINNER_FRAMES = { '-', '\\', '|', '/' }

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
    loading = {
        name = 'MiniFugitLoading',
        sources = { 'DiagnosticInfo', 'Identifier' },
        fallback_fg = 0x61AFEF,
    },
    diff_line_nr = {
        name = 'MiniFugitDiffLineNr',
        sources = { 'LineNr', 'Comment' },
        fallback_fg = 0x5C6370,
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
    if self.autocmd_group ~= nil then
        pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
    end

    self.autocmd_group = vim.api.nvim_create_augroup(
        string.format('minifugit_status_%d', self.buf.id),
        { clear = true }
    )

    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = self.autocmd_group,
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
        group = self.autocmd_group,
        callback = function()
            refresh_highlights(self)
        end,
    })

    vim.api.nvim_create_autocmd('OptionSet', {
        group = self.autocmd_group,
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

    self.win, self.win_prev_winopts =
        window.create_status_win(self.buf, self.options.status)
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
    local commit_item = selection.current_commit_item(self)

    if commit_item ~= nil then
        return preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })
    end

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
    local commit_item = selection.current_commit_item(self)

    if commit_item ~= nil then
        return preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })
    end

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
    help.toggle(self)
end

---@return boolean closed
function GitStatusWindow:close()
    self:stop_loading()
    help.close(self)

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    if self.win ~= nil and common.is_valid_win(self.win) then
        window.restore_winopts(self.win, self.win_prev_winopts)

        local tabpage = vim.api.nvim_win_get_tabpage(self.win)

        if #vim.api.nvim_tabpage_list_wins(tabpage) <= 1 then
            common.notify_warn('Cannot close the last window')
            return false
        end

        local ok = pcall(vim.api.nvim_win_close, self.win, true)

        if not ok then
            common.notify_warn('Cannot close status window')
            return false
        end
    end

    self.win = nil
    self.win_prev_winopts = nil

    return true
end

---@param buf Buffer?
local function delete_owned_buffer(buf)
    if buf == nil or buf.id == nil or not vim.api.nvim_buf_is_valid(buf.id) then
        return
    end

    pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
end

function GitStatusWindow:delete_owned_buffers()
    for _, field in ipairs(OWNED_BUFFER_FIELDS) do
        delete_owned_buffer(self[field])
        self[field] = nil
    end
end

---@return boolean destroyed
function GitStatusWindow:destroy()
    if self.autocmd_group ~= nil then
        pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
        self.autocmd_group = nil
    end

    if not self:close() then
        return false
    end

    self:delete_owned_buffers()

    return true
end

function GitStatusWindow:filter_entries()
    vim.ui.input({
        prompt = 'Filter git status entries: ',
        default = self.filter,
    }, function(input)
        if input == nil then
            return
        end

        local state = selection.capture_cursor_state(self)
        state.follow_entry = false
        self.filter = vim.trim(input)
        self:refresh(state)
    end)
end

function GitStatusWindow:clear_filter()
    if self.filter == '' then
        return
    end

    local state = selection.capture_cursor_state(self)
    state.follow_entry = false
    self.filter = ''
    self:refresh(state)
end

function GitStatusWindow:render_cached()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    self.snapshot = self.snapshot or git.status_snapshot()
    local loading_frame

    if self.loading_message ~= nil then
        loading_frame = SPINNER_FRAMES[self.loading_frame]
    end

    self.lines = formatting.render(self.snapshot, self.groups, {
        filter = self.filter,
        loading_message = self.loading_message,
        loading_frame = loading_frame,
    })

    vim.bo[self.buf.id].modifiable = true
    self.buf:set_lines(render.text_lines(self.lines))
    vim.bo[self.buf.id].modifiable = false
    render.apply(self.buf.id, self.lines)
end

function GitStatusWindow:render()
    self.snapshot = git.status_snapshot()
    self:render_cached()
end

---@param message string
function GitStatusWindow:start_loading(message)
    if self.loading_message ~= nil then
        return
    end

    self.loading_message = message
    self.loading_frame = 1
    self:render_cached()

    self.loading_timer = vim.uv.new_timer()

    if self.loading_timer == nil then
        return
    end

    self.loading_timer:start(
        120,
        120,
        vim.schedule_wrap(function()
            if self.loading_message == nil then
                return
            end

            self.loading_frame = (self.loading_frame % #SPINNER_FRAMES) + 1

            if self.buf ~= nil and self.buf:is_valid() then
                self:render_cached()
            end
        end)
    )
end

function GitStatusWindow:stop_loading()
    self.loading_message = nil

    if self.loading_timer ~= nil then
        self.loading_timer:stop()

        if not self.loading_timer:is_closing() then
            self.loading_timer:close()
        end

        self.loading_timer = nil
    end
end

---@param opts MinifugitOptions
---@return GitStatusWindow
function GitStatusWindow.new(opts)
    local self = setmetatable({}, GitStatusWindow)

    self.options = opts
    self.groups = create_highlight_groups()
    self.highlights = create_highlights()
    self.lines = {}
    self.diff_created_win = false
    self.diff_left_created_win = false
    self.diff_right_created_win = false
    self.diff_wrap = opts.preview.wrap
    self.diff_show_headers = opts.preview.show_metadata
    self.diff_show_numbers = opts.preview.show_line_numbers
    self.diff_layout = opts.preview.diff_layout
    self.filter = ''
    self.loading_frame = 1
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

    self.win, self.win_prev_winopts =
        window.create_status_win(self.buf, self.options.status)
    selection.move_to_first_entry(self)
    ensure_autocmds(self)

    return self
end

return GitStatusWindow
