require('minifugit.ui.status.preview.types')

local diff_parser = require('minifugit.ui.diff.parser')
local diff_position = require('minifugit.ui.diff.position')
local diff_render = require('minifugit.ui.diff.render')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local preview_cursor = require('minifugit.ui.status.preview.cursor')
local preview_hunks = require('minifugit.ui.status.preview.hunks')
local preview_buffers = require('minifugit.ui.status.preview.buffers')
local display = require('minifugit.ui.status.preview.display')
local window_state = require('minifugit.ui.status.preview.window_state')
local preview_util = require('minifugit.ui.status.preview.util')
local DiffWindow = require('minifugit.ui.status.preview.diff_window')
local selection = require('minifugit.ui.status.selection')

---@class DiffPreview
---@field host GitStatusWindow
---@field options MinifugitOptions
---@field groups table<string, string>
---@field stacked DiffWindow
---@field left DiffWindow
---@field right DiffWindow
---@field left_rows MiniFugitSplitRow[]?
---@field right_rows MiniFugitSplitRow[]?
---@field anchors table<integer, integer>?
---@field preview_key string?
---@field raw_lines string[]?
---@field raw_rows integer[]?
---@field hunks MiniFugitDiffHunk[]?
---@field section GitStatusSectionName?
---@field context_entry GitStatusEntry?
---@field wrap boolean
---@field show_headers boolean
---@field show_numbers boolean
---@field layout 'stacked'|'split'|'auto'
---@field layout_override 'stacked'|'split'?
local DiffPreview = {}
DiffPreview.__index = DiffPreview

---@param host GitStatusWindow
---@return DiffPreview
function DiffPreview.new(host)
    local preview_opts = host.options.preview

    local obj = setmetatable({
        host = host,
        options = host.options,
        groups = host.groups,
        stacked = DiffWindow.new(false),
        left = DiffWindow.new(true),
        right = DiffWindow.new(true),
        wrap = preview_opts.wrap,
        show_headers = preview_opts.show_metadata,
        show_numbers = preview_opts.show_line_numbers,
        layout = preview_opts.diff_layout,
    }, DiffPreview)

    obj.actions = {
        close_diff = function()
            obj:close()
        end,
        jump_hunk = function(delta)
            obj:jump_hunk(delta)
        end,
        toggle_wrap = function()
            obj:toggle_wrap()
        end,
        toggle_numbers = function()
            local win = vim.api.nvim_get_current_win()
            local ok = obj:toggle_numbers()
            if ok and not common.is_valid_win(win) then
                display.focus_open_diff(obj)
            end
            return ok
        end,
        toggle_headers = function()
            local win = vim.api.nvim_get_current_win()
            local ok = obj:toggle_headers()
            if ok and not common.is_valid_win(win) then
                display.focus_open_diff(obj)
            end
            return ok
        end,
        toggle_split_numbers = function()
            obj:toggle_split_numbers()
        end,
        stage_current_hunk = function()
            obj:stage_current_hunk()
        end,
        unstage_current_hunk = function()
            obj:unstage_current_hunk()
        end,
        discard_current_hunk = function()
            obj:discard_current_hunk()
        end,
        toggle_layout = function()
            local win = vim.api.nvim_get_current_win()
            local ok = obj:toggle_layout()
            if ok and not common.is_valid_win(win) then
                display.focus_open_diff(obj)
            end
            return ok
        end,
        goto_code = function()
            obj:goto_code()
        end,
        toggle_help = function()
            obj.host:toggle_help()
        end,
        has_open_diff = function()
            return obj:has_open()
        end,
        focus_open_diff = function()
            obj:focus()
        end,
        refresh = function(cursor_state)
            obj.host:refresh(cursor_state)
        end,
    }

    return obj
end

-- ── Internal helpers ─────────────────────────────────────────────────────────

---@param self DiffPreview
---@return 'stacked'|'split'
local function resolved_layout(self)
    local layout = self.layout_override or self.layout

    if layout == 'auto' then
        return vim.o.columns >= self.options.preview.diff_auto_threshold
                and 'split'
            or 'stacked'
    end

    return layout == 'split' and 'split' or 'stacked'
end

---@param self DiffPreview
---@param lines string[]?
---@param raw_rows integer[]?
---@param diff_hunks MiniFugitDiffHunk[]?
---@param section GitStatusSectionName?
---@param entry GitStatusEntry?
local function set_context(self, lines, raw_rows, diff_hunks, section, entry)
    self.raw_lines = lines
    self.raw_rows = raw_rows
    self.hunks = diff_hunks
    self.section = section
    self.context_entry = entry
end

---@param self DiffPreview
---@param state GitStatusCursorState?
---@return GitStatusEntryItem?
local function refresh_entry_item(self, state)
    local item = selection.current_entry_item(self.host)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.item_key ~= nil then
        local row = selection.row_for_item_key(self.host, state.item_key)
        local line = row ~= nil and self.host.lines[row] or nil
        item = selection.entry_item_from_data(line and line.data)

        if item ~= nil then
            return item
        end
    end

    if state.entry_key ~= nil then
        local row = selection.row_for_entry_key(self.host, state.entry_key)
        local line = row ~= nil and self.host.lines[row] or nil
        return selection.entry_item_from_data(line and line.data)
    end

    return nil
end

---@param self DiffPreview
---@param state GitStatusCursorState?
---@return GitStatusCommitItem?
local function refresh_commit_item(self, state)
    local item = selection.current_commit_item(self.host)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.commit_key ~= nil then
        local row = selection.row_for_commit_key(self.host, state.commit_key)
        local line = row ~= nil and self.host.lines[row] or nil
        return selection.commit_item_from_data(line and line.data)
    end

    return nil
end

---@param commit GitCommit
---@return string
local function commit_diff_title(commit)
    return preview_util.winbar_text(
        'commit: ' .. commit.hash .. ' ' .. commit.message
    )
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@return string
local function diff_title(entry, section)
    local prefix = section or 'diff'
    local path = entry.orig_path ~= nil
            and (entry.orig_path .. ' -> ' .. entry.path)
        or entry.path

    return preview_util.winbar_text(prefix .. ': ' .. path)
end

-- ── Public interface ──────────────────────────────────────────────────────────

---@return boolean
function DiffPreview:has_open()
    return window_state.has_open_stacked_diff(self)
        or window_state.has_any_split_diff(self)
end

---@return boolean
function DiffPreview:focus()
    return display.focus_open_diff(self)
end

---@return boolean
function DiffPreview:toggle_wrap()
    if not self:has_open() then
        common.notify_warn('Diff preview is not open')
        return false
    end

    self.wrap = not self.wrap

    if common.is_valid_win(self.stacked.win) then
        vim.wo[self.stacked.win].wrap = self.wrap
    end

    if common.is_valid_win(self.left.win) then
        vim.wo[self.left.win].wrap = self.wrap
    end

    if common.is_valid_win(self.right.win) then
        vim.wo[self.right.win].wrap = self.wrap
    end

    return true
end

---@return boolean
function DiffPreview:toggle_numbers()
    self.show_numbers = not self.show_numbers
    return self:refresh() == true
end

---@return boolean
function DiffPreview:toggle_headers()
    self.show_headers = not self.show_headers
    return self:refresh() == true
end

---@return boolean
function DiffPreview:toggle_split_numbers()
    return display.toggle_split_numbers(self)
end

---@param layout 'stacked'|'split'
---@return boolean
function DiffPreview:set_layout(layout)
    self.layout_override = layout
    return self:refresh() == true
end

---@return boolean
function DiffPreview:toggle_layout()
    local current = resolved_layout(self)
    local next_layout = current == 'split' and 'stacked' or 'split'

    if not self:has_open() then
        self.layout_override = next_layout
        return true
    end

    local position = preview_cursor.current_hunk_position(self)
    local ok = self:set_layout(next_layout)

    if ok then
        preview_cursor.restore_hunk_position(self, position)
    end

    return ok
end

---@param delta integer
---@return boolean
function DiffPreview:jump_hunk(delta)
    if not self:has_open() then
        common.notify_warn('Diff preview is not open')
        return false
    end

    if common.is_valid_win(self.stacked.win) then
        local win = assert(self.stacked.win)
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
        local lines =
            vim.api.nvim_buf_get_lines(self.stacked.buf.id, 0, -1, false)
        local start = delta > 0 and cursor_row + 1 or cursor_row - 1
        local stop = delta > 0 and #lines or 1

        for row = start, stop, delta do
            if vim.startswith(lines[row] or '', '@@') then
                vim.api.nvim_win_set_cursor(win, { row, 0 })
                return true
            end
        end

        common.notify_warn('No more hunks')
        return false
    end

    local anchors = self.anchors

    if anchors == nil or vim.tbl_isempty(anchors) then
        common.notify_warn('No hunks to jump to')
        return false
    end

    local win = vim.api.nvim_get_current_win()

    if not common.is_valid_win(win) then
        return false
    end

    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    local anchor_rows = {}

    for _, row in pairs(anchors) do
        table.insert(anchor_rows, row)
    end

    table.sort(anchor_rows)

    local target

    if delta > 0 then
        for _, row in ipairs(anchor_rows) do
            if row > cursor_row then
                target = row
                break
            end
        end

        if target == nil then
            target = anchor_rows[1]
        end
    else
        for i = #anchor_rows, 1, -1 do
            if anchor_rows[i] < cursor_row then
                target = anchor_rows[i]
                break
            end
        end

        if target == nil then
            target = anchor_rows[#anchor_rows]
        end
    end

    if target ~= nil then
        local buf = vim.api.nvim_win_get_buf(win)
        local line_count = vim.api.nvim_buf_line_count(buf)
        target = math.min(target, line_count)
        vim.api.nvim_win_set_cursor(win, { target, 0 })

        local paired = win == self.left.win and self.right.win
            or (win == self.right.win and self.left.win)

        if common.is_valid_win(paired) then
            vim.api.nvim_win_set_cursor(paired, { target, 0 })
        end

        return true
    end

    common.notify_warn('No more hunks')
    return false
end

---@return boolean
function DiffPreview:goto_code()
    local position = preview_cursor.current_source_position(self)

    if position == nil then
        common.notify_warn('No source line under cursor')
        return false
    end

    if self.section == 'staged' and self.context_entry ~= nil then
        local unstaged_lines = git.diff(self.context_entry, 'unstaged')

        if #unstaged_lines > 0 then
            local parsed_unstaged_hunks =
                diff_parser.parse_hunks(unstaged_lines)
            position = {
                path = position.path,
                line = diff_position.old_line_to_new_line(
                    unstaged_lines,
                    parsed_unstaged_hunks,
                    position.line
                ),
            }
        end
    end

    local root = git.root()
    local path = root ~= '' and vim.fs.joinpath(root, position.path)
        or position.path

    if vim.fn.filereadable(path) == 0 then
        common.notify_warn('Cannot open ' .. position.path)
        return false
    end

    local win = vim.api.nvim_get_current_win()
    local dw = window_state.diff_window_for_win(self, win)

    if dw == nil then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local diff_buffers, code_win =
        window_state.close_diff_windows_for_code(self, dw)

    vim.api.nvim_set_current_win(code_win)
    local finish_related_open = self.host:begin_related_buffer_open()
    local ok, err = pcall(function()
        vim.cmd('keepalt keepjumps edit ' .. vim.fn.fnameescape(path))
    end)
    finish_related_open(ok and vim.api.nvim_get_current_buf() or nil)

    if not ok then
        common.notify_error(tostring(err), 'Cannot open ' .. position.path)
        window_state.delete_diff_buffers(diff_buffers)
        return false
    end

    preview_cursor.set_cursor_row(code_win, position.line)
    self.host.target_win = code_win

    window_state.delete_diff_buffers(diff_buffers)

    return true
end

---@return boolean
function DiffPreview:stage_current_hunk()
    return preview_hunks.apply_current_hunk(self, 'stage', self.actions)
end

---@return boolean
function DiffPreview:unstage_current_hunk()
    return preview_hunks.apply_current_hunk(self, 'unstage', self.actions)
end

---@return boolean
function DiffPreview:discard_current_hunk()
    return preview_hunks.apply_current_hunk(self, 'discard', self.actions)
end

---@return Buffer
function DiffPreview:ensure_diff_buf()
    return preview_buffers.ensure_stacked(self, self.actions)
end

---@return nil
function DiffPreview:delete_owned_buffers()
    for _, dw in ipairs({ self.stacked, self.left, self.right }) do
        if dw.buf ~= nil and dw.buf.id ~= nil then
            pcall(vim.api.nvim_buf_delete, dw.buf.id, { force = true })
            dw.buf = nil
        end
    end
end

---@param commit GitCommit
---@param opts? { force: boolean? }
---@return boolean
function DiffPreview:open_commit(commit, opts)
    opts = opts or {}

    local preview_key = 'commit:' .. commit.hash

    if
        not opts.force
        and self:has_open()
        and self.preview_key == preview_key
    then
        return true
    end

    local lines, err = git.show_commit(commit)
    local diff_lines

    if err ~= nil then
        common.notify_error(err, 'Cannot show commit diff')
        return false
    end

    if #lines == 0 then
        diff_lines = { render.line('No diff for commit ' .. commit.hash) }
    else
        diff_lines = diff_render.render_lines(lines, self.groups, {
            show_headers = self.show_headers,
            show_numbers = self.show_numbers,
        })
    end

    set_context(self, nil, nil, nil, nil, nil)

    local ok = display.show_stacked(
        self,
        diff_lines,
        preview_key,
        commit_diff_title(commit),
        self.actions
    )

    if ok and self.stacked.buf ~= nil then
        preview_buffers.clear_goto_code_keymap(self.stacked.buf.id)
    end

    return ok
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function DiffPreview:open(entry, section, opts)
    opts = opts or {}

    local preview_key =
        table.concat({ section or '', entry.orig_path or '', entry.path }, '\0')
    local layout = resolved_layout(self)
    local has_open_preview = (
        layout == 'split' and window_state.has_open_split_diff(self)
    )
        or (layout ~= 'split' and window_state.has_open_stacked_diff(self))

    if has_open_preview and self.preview_key == preview_key then
        if opts.focus then
            return display.focus_open_diff(self)
        end

        if not opts.force then
            return true
        end
    end

    local lines, err = git.diff(entry, section)

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    local parsed_hunks = diff_parser.parse_hunks(lines)
    local split_diff, split_err = git.split_diff(entry, section)

    if layout == 'split' then
        if split_diff ~= nil then
            local ok = display.show_split(
                self,
                split_diff,
                lines,
                parsed_hunks,
                preview_key,
                diff_title(entry, section),
                self.actions
            )

            if ok then
                set_context(self, lines, nil, parsed_hunks, section, entry)

                if opts.focus then
                    display.focus_open_diff(self)
                end
            end

            return ok
        end

        if split_err ~= nil and opts.notify ~= false then
            common.notify_warn(split_err .. '; showing stacked diff')
        end
    end

    local diff_lines
    local raw_rows
    local syntax

    if split_diff ~= nil then
        syntax = {
            filetype = split_diff.filetype,
            left_lines = split_diff.left.lines,
            right_lines = split_diff.right.lines,
        }
    end

    if #lines == 0 then
        diff_lines = { render.line('No diff for ' .. entry.path) }
    else
        diff_lines, raw_rows = diff_render.render_lines(lines, self.groups, {
            show_headers = self.show_headers,
            show_numbers = self.show_numbers,
            syntax = syntax,
        })
    end

    diff_parser.assign_stacked_rows(parsed_hunks, raw_rows)

    local ok = display.show_stacked(
        self,
        diff_lines,
        preview_key,
        diff_title(entry, section),
        self.actions
    )

    if ok then
        set_context(self, lines, raw_rows, parsed_hunks, section, entry)

        if opts.focus then
            display.focus_open_diff(self)
        end

        if self.stacked.buf ~= nil then
            preview_buffers.set_goto_code_keymap(
                self.stacked.buf.id,
                self.actions
            )
        end
    end

    return ok
end

function DiffPreview:close()
    local closed = false

    if window_state.has_any_split_diff(self) then
        closed = self.right:restore_or_close(false) or closed
        closed = self.left:restore_or_close(false) or closed
    end

    if window_state.has_open_stacked_diff(self) then
        closed = self.stacked:restore_or_close(false) or closed
    end

    if not closed then
        return
    end

    window_state.clear_missing_diff_window_states(self)
    self.preview_key = nil
    set_context(self, nil, nil, nil, nil, nil)

    if self.host.win ~= nil and common.is_valid_win(self.host.win) then
        vim.api.nvim_set_current_win(self.host.win)
    end
end

---@param state GitStatusCursorState?
---@return boolean?
function DiffPreview:refresh(state)
    if not self:has_open() then
        return
    end

    local key = self.preview_key or ''

    if vim.startswith(key, 'commit:') then
        local item = refresh_commit_item(self, state)

        if item == nil then
            return
        end

        return self:open_commit(item.commit, { force = true })
    end

    local item = refresh_entry_item(self, state)

    if item == nil then
        return
    end

    return self:open(item.entry, item.section, { force = true })
end

---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function DiffPreview:preview_current_entry(opts)
    opts = opts or {}

    local item = selection.current_entry_item(self.host)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No git status entry under cursor')
        end

        return false
    end

    return self:open(item.entry, item.section, {
        force = opts.force,
        focus = opts.focus,
    })
end

---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function DiffPreview:preview_current_commit(opts)
    opts = opts or {}

    local item = selection.current_commit_item(self.host)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No unpushed commit under cursor')
        end

        return false
    end

    return self:open_commit(item.commit, { force = opts.force })
end

return DiffPreview
