local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local render = require('minifugit.ui.render')
local StatusDocument = require('minifugit.ui.status.document')
local help = require('minifugit.ui.status.help')
local log = require('minifugit.log')
local actions = require('minifugit.ui.status.actions')
local common = require('minifugit.ui.status.common')
local keymaps = require('minifugit.ui.status.keymaps')
local DiffPreview = require('minifugit.ui.status.preview.diff_preview')
local session = require('minifugit.ui.status.session')
local status_tab = require('minifugit.ui.status.tab')
local window = require('minifugit.ui.status.window')
local git = require('minifugit.git')

---@class GitStatusWindow
---@field root string Pinned repository root, captured when the window is created.
---@field base string? Pinned commit hash for read-only base mode.
---@field buf Buffer
---@field preview DiffPreview
---@field help_buf Buffer?
---@field help_win number?
---@field help_prev_win number?
---@field win number?
---@field win_prev_winopts GitStatusWindowOptions?
---@field target_win number?
---@field tabpage number?
---@field tab_placeholder_buf number?
---@field tab_related_buffers table<number, boolean>?
---@field tab_foreign_buffer boolean
---@field tab_suppress_foreign integer
---@field tab_closing boolean
---@field options MinifugitOptions
---@field groups table<string, string>
---@field highlights table<string, { ensure: fun() }>
---@field document StatusDocument Rendered status lines and row identities.
---@field lines MiniFugitRenderLine[]
---@field snapshot GitStatusSnapshot? Snapshot rendered by the last full render.
---@field read_generation integer Generation of the newest snapshot read.
---@field reading boolean Whether a snapshot read is in flight.
---@field filter string
---@field loading_message string?
---@field loading_frame integer
---@field loading_timer uv.uv_timer_t?
---@field auto_refresh_timer uv.uv_timer_t?
---@field auto_refresh_token integer Run token of the newest focus debounce.
---@field autocmd_group integer?
---@field on_close_callbacks (fun())[]
---@field on_close_windows table<integer, boolean>
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

local HIGHLIGHT_NAMESPACE = 'GitStatusWindow'

local OWNED_BUFFER_FIELDS = {
    'buf',
    'help_buf',
}

local DIFF_HEADER_GROUP = 'MiniFugitDiffHeader'
local DIFF_HUNK_HEADER_GROUP = 'MiniFugitDiffHunkHeader'
local SPINNER_FRAMES = { '-', '\\', '|', '/' }
local AUTO_REFRESH_DEBOUNCE_MS = 200

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
    diff_conflict_head = {
        name = 'MiniFugitDiffConflictHead',
        sources = { 'DiffChange', 'Identifier' },
        fallback_bg = 0x2E4159,
    },
    diff_conflict_incoming = {
        name = 'MiniFugitDiffConflictIncoming',
        sources = { 'DiffText', 'Special' },
        fallback_bg = 0x4A3A5C,
    },
    diff_conflict_marker = {
        name = 'MiniFugitDiffConflictMarker',
        sources = { 'DiffDelete', 'Removed', 'Error' },
        fallback_bg = 0x5A2D34,
    },
    diff_added_text = {
        name = 'MiniFugitDiffAddedText',
        sources = { 'DiffAdd', 'Added', 'String' },
        fallback_fg = 0x98C379,
        fallback_bg = 0x2E4D33,
    },
    diff_removed_text = {
        name = 'MiniFugitDiffRemovedText',
        sources = { 'DiffDelete', 'Removed', 'Error' },
        fallback_fg = 0xE06C75,
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
    groups.diff_added_intraline = 'MiniFugitDiffAddedIntraline'
    groups.diff_removed_intraline = 'MiniFugitDiffRemovedIntraline'

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
    highlights.diff_added_intraline = create_fixed_highlight(
        'MiniFugitDiffAddedIntraline',
        function()
            return { bg = 0x3D6B44 }
        end
    )
    highlights.diff_removed_intraline = create_fixed_highlight(
        'MiniFugitDiffRemovedIntraline',
        function()
            return { bg = 0x7A3B45 }
        end
    )

    return highlights
end

---@param self GitStatusWindow
local function ensure_highlights(self)
    assert(self.highlights ~= nil)

    for _, h in pairs(self.highlights) do
        h:ensure()
    end
end

---@param win integer
---@param opts GitStatusWindowOptions?
---@return GitStatusWindowOptions?
local function release_winopts(win, opts)
    if opts == nil then
        return nil
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local filetype = vim.bo[buf].filetype

    if filetype ~= 'gitcommit' and filetype ~= 'gitrebase' then
        return opts
    end

    return vim.tbl_extend('force', opts, { winbar = '' })
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

        window.restore_winopts(win, release_winopts(win, self.win_prev_winopts))
    end

    self.win = nil
    self.win_prev_winopts = nil
end

---@param self GitStatusWindow
---@return integer?
local function status_cursor_row(self)
    if not self.buf or not self.buf:is_valid() then
        return nil
    end

    local win = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_get_buf(win) ~= self.buf.id then
        if not common.is_valid_win(self.win) then
            return nil
        end

        win = self.win
    end

    return vim.api.nvim_win_get_cursor(win)[1]
end

---@param self GitStatusWindow
---@return integer?
local function tracked_cursor_row(self)
    if not common.is_valid_win(self.win) then
        return nil
    end

    return vim.api.nvim_win_get_cursor(self.win)[1]
end

---@param self GitStatusWindow
---@param row integer?
local function set_cursor_row(self, row)
    if row == nil or not common.is_valid_win(self.win) then
        return
    end

    vim.api.nvim_win_set_cursor(self.win, { row, 0 })
end

---@param self GitStatusWindow
local function move_to_first_entry(self)
    set_cursor_row(self, self.document:resolve())
end

---Place the tracked cursor for `state`, keeping the baseline fallback: when no
---item sits under the current status view after placement, move the tracked
---view to the first entry. The current view may be another window showing the
---same status buffer, while `state.row` belongs to `self.win`.
---@param self GitStatusWindow
---@param state GitStatusCursorState
local function restore_cursor(self, state)
    local row = self.document:resolve(state)

    if state.follow_entry == false and state.row ~= nil then
        set_cursor_row(self, row)
        return
    end

    if row == nil then
        move_to_first_entry(self)
        return
    end

    set_cursor_row(self, row)

    if self:current_item() == nil then
        move_to_first_entry(self)
    end
end

---@param self GitStatusWindow
local function refresh_highlights(self)
    ensure_highlights(self)

    if self.buf ~= nil and self.buf:is_valid() then
        render.apply(self.buf.id, self.lines)
    end

    if self.preview:has_open() then
        self.preview:refresh()
    end
end

---@param bufnr number?
function GitStatusWindow:mark_related_buffer(bufnr)
    status_tab.mark_related_buffer(self, bufnr)
end

---@return fun(bufnr: number?)
function GitStatusWindow:begin_related_buffer_open()
    return status_tab.begin_related_buffer_open(self)
end

---@return boolean
function GitStatusWindow:close_owned_tab()
    return status_tab.close_owned_tab(self)
end

---@return boolean
function GitStatusWindow:maybe_close_owned_tab()
    return status_tab.maybe_close(self)
end

---@param self GitStatusWindow
local function notify_closed(self)
    local bufnr = self.buf and self.buf.id
    vim.schedule(function()
        if
            bufnr ~= nil
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        then
            if #vim.fn.win_findbuf(bufnr) > 0 then
                return
            end
            for win in pairs(self.on_close_windows) do
                if vim.api.nvim_win_is_valid(win) then
                    return
                end
                self.on_close_windows[win] = nil
            end
        end

        local callbacks = self.on_close_callbacks
        self.on_close_callbacks = {}
        self.on_close_windows = {}
        for _, callback in ipairs(callbacks) do
            local ok, err = pcall(callback)
            if not ok then
                log.error('on_close callback failed: ' .. tostring(err))
            end
        end
    end)
end

---Stop a pending auto-refresh so a manual refresh takes precedence. The run
---token also voids a debounce that already fired but has not run its refresh.
---@param self GitStatusWindow
local function cancel_auto_refresh(self)
    self.auto_refresh_token = self.auto_refresh_token + 1

    if self.auto_refresh_timer ~= nil then
        self.auto_refresh_timer:stop()
    end
end

---@param self GitStatusWindow
local function close_auto_refresh_timer(self)
    local timer = self.auto_refresh_timer

    if timer == nil then
        return
    end

    self.auto_refresh_timer = nil
    timer:stop()

    if not timer:is_closing() then
        timer:close()
    end
end

---Whether the status buffer is shown in a window of the current tabpage.
---Hidden windows and windows of other tabpages do not auto-refresh.
---@param self GitStatusWindow
---@return boolean
local function visible_in_current_tab(self)
    if self.buf == nil or not self.buf:is_valid() then
        return false
    end

    local tabpage = vim.api.nvim_get_current_tabpage()

    for _, win in ipairs(vim.fn.win_findbuf(self.buf.id)) do
        if vim.api.nvim_win_get_tabpage(win) == tabpage then
            return true
        end
    end

    return false
end

---Refresh once unless the window is gone, its buffer is not visible in the
---current tabpage, or an operation spinner is running.
---@param self GitStatusWindow
---@return boolean refreshed
local function auto_refresh(self)
    if not visible_in_current_tab(self) then
        return false
    end

    if self.loading_message ~= nil then
        return false
    end

    return self:refresh()
end

---Start, restart, or coalesce the focus debounce. A burst of focus events
---restarts one timer, so it refreshes once when the burst settles.
---@param self GitStatusWindow
local function schedule_auto_refresh(self)
    local timer = self.auto_refresh_timer

    if timer == nil then
        timer = vim.uv.new_timer()

        if timer == nil then
            log.error('Cannot create the auto-refresh timer')
            return
        end

        self.auto_refresh_timer = timer
    end

    self.auto_refresh_token = self.auto_refresh_token + 1
    local token = self.auto_refresh_token

    timer:start(
        AUTO_REFRESH_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
            if token ~= self.auto_refresh_token then
                return
            end

            auto_refresh(self)
        end)
    )
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

    vim.api.nvim_create_autocmd('BufEnter', {
        group = self.autocmd_group,
        buffer = self.buf.id,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            self.on_close_windows[win] = true

            if self.win ~= win then
                self.win = win
                self.win_prev_winopts = window.capture_winopts(win)
            end

            window.configure_status_win(win)
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
        group = self.autocmd_group,
        buffer = self.buf.id,
        callback = function()
            for _, win in ipairs(vim.fn.win_findbuf(self.buf.id)) do
                self.on_close_windows[win] = true
            end
        end,
    })

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

    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.autocmd_group,
        callback = function(args)
            if self.on_close_windows[tonumber(args.match)] then
                notify_closed(self)
            end
        end,
    })

    vim.api.nvim_create_autocmd({
        'BufWinLeave',
        'BufHidden',
        'BufDelete',
        'BufUnload',
        'BufWipeout',
    }, {
        group = self.autocmd_group,
        buffer = self.buf.id,
        callback = function()
            notify_closed(self)
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

    status_tab.install_autocmds(self)

    if self.options.status.auto_refresh ~= false then
        vim.api.nvim_create_autocmd('FocusGained', {
            group = self.autocmd_group,
            callback = function()
                schedule_auto_refresh(self)
            end,
        })
    end
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

    if not status_tab.uses(self) then
        window.set_target_win(self, vim.api.nvim_get_current_win())
    end

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        return
    end

    local target_win
    local placeholder_buf
    self.win, self.win_prev_winopts, target_win, placeholder_buf =
        window.create_status_win(self.buf, self.options.status, self.tabpage)
    status_tab.attach(self, target_win, placeholder_buf)
    move_to_first_entry(self)
end

---Item under the status cursor, falling back to `state` keys when given.
---@param kind 'entry'|'commit'?
---@param state GitStatusCursorState?
---@return StatusItem?
function GitStatusWindow:current_item(kind, state)
    return self.document:item(status_cursor_row(self), kind, state)
end

---@return GitStatusEntryItem[]
function GitStatusWindow:selected_entry_items()
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

    return self.document:entries(start_row, end_row)
end

---@return GitStatusEntry[]
function GitStatusWindow:all_entries()
    local entries = {}

    for _, item in ipairs(self.document:entries()) do
        table.insert(entries, item.entry)
    end

    return entries
end

---@return GitStatusCursorState
function GitStatusWindow:capture_cursor_state()
    local state = self.document:capture(status_cursor_row(self))
    state.row = tracked_cursor_row(self)

    return state
end

---@param state? GitStatusCursorState
---@return boolean
function GitStatusWindow:refresh(state)
    cancel_auto_refresh(self)
    state = state or self:capture_cursor_state()

    self:read_snapshot(state)

    return true
end

---@return boolean
function GitStatusWindow:diff_entry()
    local commit_item = self:current_item('commit')

    if commit_item ~= nil then
        return self.preview:preview_current_commit({
            force = true,
            notify = true,
        })
    end

    return self.preview:preview_current_entry({
        force = true,
        notify = true,
    })
end

---@return boolean
function GitStatusWindow:reject_read_only()
    if self.base == nil then
        return false
    end

    common.notify_warn('read-only: changes since ' .. self.base:sub(1, 7))
    return true
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
    local commit_item = self:current_item('commit')

    if commit_item ~= nil then
        return self.preview:preview_current_commit({
            force = true,
            notify = true,
        })
    end

    local item = self:current_item('entry')

    if item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if self.preview:has_open() then
        self.preview:close()
    end

    return window.open_entry(self, item.entry)
end

function GitStatusWindow:toggle_help()
    help.toggle(self)
end

---@return boolean closed
function GitStatusWindow:close()
    -- Drop in-flight read results: a closed window must not render them.
    self.read_generation = self.read_generation + 1
    self.reading = false
    cancel_auto_refresh(self)
    close_auto_refresh_timer(self)
    self:stop_loading()
    help.close(self)

    if self.preview:has_open() then
        self.preview:close()
    end

    if self.win ~= nil and common.is_valid_win(self.win) then
        window.restore_winopts(self.win, self.win_prev_winopts)

        local win = self.win
        local buf = self.buf.id
        local tabpage = vim.api.nvim_win_get_tabpage(win)

        if window.normal_window_count(tabpage) <= 1 then
            if tabpage == self.tabpage and self:close_owned_tab() then
                self.win = nil
                self.win_prev_winopts = nil
                notify_closed(self)
                return true
            end

            vim.api.nvim_win_call(win, function()
                vim.cmd('enew!')
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end)
        else
            local ok = pcall(vim.api.nvim_win_close, win, true)

            if not ok then
                common.notify_warn('Cannot close status window')
                return false
            end
        end
    end

    self.win = nil
    self.win_prev_winopts = nil
    self:maybe_close_owned_tab()
    notify_closed(self)

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

    self.preview:delete_owned_buffers()
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

        local state = self:capture_cursor_state()
        state.follow_entry = false
        self.filter = vim.trim(input)
        self:refresh(state)
    end)
end

function GitStatusWindow:clear_filter()
    if self.filter == '' then
        return
    end

    local state = self:capture_cursor_state()
    state.follow_entry = false
    self.filter = ''
    self:refresh(state)
end

function GitStatusWindow:render_cached()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    local loading_frame

    if self.loading_message ~= nil then
        loading_frame = SPINNER_FRAMES[self.loading_frame]
    end

    self.document = StatusDocument.new(self.snapshot, self.groups, {
        filter = self.filter,
        loading_message = self.loading_message,
        loading_frame = loading_frame,
        reading = self.reading,
        pending = self.snapshot == nil,
        base = self.base,
    })
    self.lines = self.document.lines

    self.buf:set_modifiable(true)
    self.buf:set_lines(render.text_lines(self.lines))
    self.buf:set_modifiable(false)
    render.apply(self.buf.id, self.lines)
end

---@param state GitStatusCursorState
---@param snapshot GitStatusSnapshot
local function apply_snapshot(self, state, snapshot)
    if self.buf == nil or not self.buf:is_valid() then
        return
    end

    self.reading = false
    self.snapshot = snapshot
    self:render_cached()
    restore_cursor(self, state)
    self.preview:refresh(state)
end

---Start an asynchronous snapshot read. Only the newest read is applied: an
---older result for a superseded or destroyed window is dropped.
---@param state GitStatusCursorState
function GitStatusWindow:read_snapshot(state)
    self.read_generation = self.read_generation + 1
    local generation = self.read_generation

    self.reading = true
    self:render_cached()

    ---@param snapshot GitStatusSnapshot
    local function apply(snapshot)
        if generation ~= self.read_generation then
            return
        end

        apply_snapshot(self, state, snapshot)
    end

    if self.base ~= nil then
        git.base_entries_async(self.base, self.root, function(entries, err)
            apply({
                branch = '',
                root = self.root,
                entries = entries,
                unpushed_commits = {},
                error = err,
            })
        end)

        return
    end

    git.status_snapshot_async(self.root, apply)
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

---@class MinifugitStatusReusedTab
---@field tabpage integer Owned tabpage to reuse.
---@field foreign_buffer boolean

---@param opts MinifugitOptions
---@param root string? Resolved repository root; defaults to the current cwd's root.
---@param base string? Pinned commit hash for read-only base mode.
---@param reused_tab MinifugitStatusReusedTab? Owned tabpage to reuse.
---@return GitStatusWindow
function GitStatusWindow.new(opts, root, base, reused_tab)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.status', opts.status, 'table')
    vim.validate('root', root, 'string', true)
    vim.validate('base', base, 'string', true)
    vim.validate('reused_tab', reused_tab, 'table', true)
    if reused_tab ~= nil then
        vim.validate('reused_tab.tabpage', reused_tab.tabpage, 'number')
        vim.validate(
            'reused_tab.foreign_buffer',
            reused_tab.foreign_buffer,
            'boolean'
        )
    end

    -- Before the target window is read: a restored leftover may be showing in
    -- it, and its name would collide with the new status buffer's name.
    session.drop_restored()

    local self = setmetatable({}, GitStatusWindow)

    self.root = root or git.root()
    self.base = base
    self.options = opts
    self.on_close_callbacks = {}
    self.on_close_windows = {}
    self.groups = create_highlight_groups()
    self.highlights = create_highlights()
    self.lines = {}
    self.filter = ''
    self.loading_frame = 1
    self.read_generation = 0
    self.reading = false
    self.auto_refresh_token = 0
    self.target_win = vim.api.nvim_get_current_win()
    status_tab.setup_state(self)

    ensure_highlights(self)

    ---@type BufferOpts
    local buf_opts = { listed = false, scratch = true }
    self.buf = Buffer.new(buf_opts)
    vim.api.nvim_buf_set_name(
        self.buf.id,
        string.format('Minifugit [%d]', self.buf.id)
    )

    self.preview = DiffPreview.new(self)

    keymaps.attach(self)
    -- The first read starts with no cursor state to preserve: the document is
    -- still empty.
    self:read_snapshot({})
    self.buf:set_option('filetype', 'minifugit')

    local target_win
    local placeholder_buf
    self.win, self.win_prev_winopts, target_win, placeholder_buf =
        window.create_status_win(
            self.buf,
            self.options.status,
            reused_tab and reused_tab.tabpage
        )
    self.on_close_windows[self.win] = true
    status_tab.attach(self, target_win, placeholder_buf)
    if reused_tab ~= nil then
        self.tab_foreign_buffer = reused_tab.foreign_buffer
    end
    move_to_first_entry(self)
    ensure_autocmds(self)

    return self
end

return GitStatusWindow
