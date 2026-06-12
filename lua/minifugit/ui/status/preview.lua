require('minifugit.ui.status.preview.types')

local diff_parser = require('minifugit.ui.diff.parser')
local diff_position = require('minifugit.ui.diff.position')
local diff_render = require('minifugit.ui.diff.render')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local selection = require('minifugit.ui.status.selection')
local preview_cursor = require('minifugit.ui.status.preview.cursor')
local preview_hunks = require('minifugit.ui.status.preview.hunks')
local preview_buffers = require('minifugit.ui.status.preview.buffers')
local display = require('minifugit.ui.status.preview.display')
local window_state = require('minifugit.ui.status.preview.window_state')
local preview_util = require('minifugit.ui.status.preview.util')

local M = {}

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusEntryItem?
local function entry_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.entry_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusCommitItem?
local function commit_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.commit_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusEntryItem?
local function refresh_entry_item(self, state)
    local item = selection.current_entry_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.item_key ~= nil then
        item = entry_item_at_row(
            self,
            selection.row_for_item_key(self, state.item_key)
        )

        if item ~= nil then
            return item
        end
    end

    if state.entry_key ~= nil then
        return entry_item_at_row(
            self,
            selection.row_for_entry_key(self, state.entry_key)
        )
    end

    return nil
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusCommitItem?
local function refresh_commit_item(self, state)
    local item = selection.current_commit_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.commit_key ~= nil then
        return commit_item_at_row(
            self,
            selection.row_for_commit_key(self, state.commit_key)
        )
    end

    return nil
end

---@class MiniFugitDiffSourcePosition
---@field path string
---@field line integer

---@class MiniFugitDiffWindowState
---@field win_field string
---@field prev_buf_field string
---@field prev_winopts_field string
---@field created_win_field string
---@field buf_field string
---@field split boolean?

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

---@param self GitStatusWindow
---@return 'stacked'|'split'
local function resolved_layout(self)
    local layout = self.diff_layout_override or self.diff_layout

    if layout == 'auto' then
        return vim.o.columns >= self.options.preview.diff_auto_threshold
                and 'split'
            or 'stacked'
    end

    return layout == 'split' and 'split' or 'stacked'
end

---@param self GitStatusWindow
---@param lines string[]?
---@param raw_rows integer[]?
---@param diff_hunks MiniFugitDiffHunk[]?
---@param section GitStatusSectionName?
---@param entry GitStatusEntry?
local function set_diff_context(
    self,
    lines,
    raw_rows,
    diff_hunks,
    section,
    entry
)
    self.diff_raw_lines = lines
    self.diff_raw_rows = raw_rows
    self.diff_hunks = diff_hunks
    self.diff_section = section
    self.diff_context_entry = entry
end

---@param self GitStatusWindow
---@return MiniFugitPreviewActions
local function preview_actions(self)
    return {
        close_diff = function()
            M.close_diff(self)
        end,
        jump_hunk = function(delta)
            M.jump_hunk(self, delta)
        end,
        toggle_wrap = function()
            M.toggle_wrap(self)
        end,
        toggle_numbers = function()
            M.toggle_numbers(self)
        end,
        toggle_headers = function()
            M.toggle_headers(self)
        end,
        toggle_split_numbers = function()
            display.toggle_split_numbers(self)
        end,
        stage_current_hunk = function()
            M.stage_current_hunk(self)
        end,
        unstage_current_hunk = function()
            M.unstage_current_hunk(self)
        end,
        discard_current_hunk = function()
            M.discard_current_hunk(self)
        end,
        toggle_layout = function()
            M.toggle_layout(self)
        end,
        goto_code = function()
            M.goto_code(self)
        end,
        toggle_help = function()
            self:toggle_help()
        end,
        has_open_diff = function()
            return M.has_open_diff(self)
        end,
        focus_open_diff = function()
            display.focus_open_diff(self)
        end,
        refresh = function(cursor_state)
            self:refresh(cursor_state)
        end,
    }
end

---@param self GitStatusWindow
---@param delta integer
---@return boolean
function M.jump_hunk(self, delta)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    -- Stacked diff: scan for @@ lines.
    if common.is_valid_win(self.diff_win) then
        local win = assert(self.diff_win)
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
        local lines = vim.api.nvim_buf_get_lines(self.diff_buf.id, 0, -1, false)
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

    -- Split diff: use alignment anchors.
    local anchors = self.diff_anchors

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

        -- Sync the paired window (cursorbind doesn't fire for API moves).
        local paired = win == self.diff_left_win and self.diff_right_win
            or (win == self.diff_right_win and self.diff_left_win)

        if common.is_valid_win(paired) then
            vim.api.nvim_win_set_cursor(paired, { target, 0 })
        end

        return true
    end

    common.notify_warn('No more hunks')
    return false
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_wrap(self)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    self.diff_wrap = not self.diff_wrap

    if common.is_valid_win(self.diff_win) then
        vim.wo[self.diff_win].wrap = self.diff_wrap
    end

    if common.is_valid_win(self.diff_left_win) then
        vim.wo[self.diff_left_win].wrap = self.diff_wrap
    end

    if common.is_valid_win(self.diff_right_win) then
        vim.wo[self.diff_right_win].wrap = self.diff_wrap
    end

    return true
end

---@param self GitStatusWindow
---@param layout 'stacked'|'split'
---@return boolean
function M.set_layout(self, layout)
    self.diff_layout_override = layout

    local ok = M.refresh_current_entry(self) == true

    if ok and self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return ok
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_layout(self)
    local current = resolved_layout(self)
    local next_layout = current == 'split' and 'stacked' or 'split'

    if not M.has_open_diff(self) then
        self.diff_layout_override = next_layout
        return true
    end

    local position = preview_cursor.current_hunk_position(self)
    local ok = M.set_layout(self, next_layout)

    if ok then
        preview_cursor.restore_hunk_position(self, position)
    end

    return ok
end

---@param self GitStatusWindow
---@param option 'numbers'|'headers'
---@return boolean
local function toggle_diff_render_option(self, option)
    if option == 'numbers' then
        self.diff_show_numbers = not self.diff_show_numbers
    else
        self.diff_show_headers = not self.diff_show_headers
    end

    local ok = M.refresh_current_entry(self) == true

    if
        ok
        and self.diff_win ~= nil
        and vim.api.nvim_win_is_valid(self.diff_win)
    then
        vim.api.nvim_set_current_win(self.diff_win)
    end

    return ok
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_numbers(self)
    return toggle_diff_render_option(self, 'numbers')
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_headers(self)
    return toggle_diff_render_option(self, 'headers')
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return window_state.has_open_stacked_diff(self)
        or window_state.has_any_split_diff(self)
end

---@param self GitStatusWindow
---@param commit GitCommit
---@param opts? { force: boolean? }
---@return boolean
function M.open_commit_diff(self, commit, opts)
    opts = opts or {}

    local preview_key = 'commit:' .. commit.hash

    if
        not opts.force
        and M.has_open_diff(self)
        and self.diff_preview_key == preview_key
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
            show_headers = self.diff_show_headers,
            show_numbers = self.diff_show_numbers,
        })
    end

    set_diff_context(self, nil, nil, nil, nil, nil)

    local ok = display.show_stacked(
        self,
        diff_lines,
        preview_key,
        commit_diff_title(commit),
        preview_actions(self)
    )

    if ok and self.diff_buf ~= nil then
        preview_buffers.clear_goto_code_keymap(self.diff_buf.id)
    end

    return ok
end

---@param self GitStatusWindow
function M.close_diff(self)
    local closed = false

    if window_state.has_any_split_diff(self) then
        closed = window_state.restore_or_close_diff_windows(
            self,
            window_state.SPLIT_DIFF_CLOSE_STATES
        )
    end

    if window_state.has_open_stacked_diff(self) then
        closed = window_state.restore_or_close_diff_window(
            self,
            window_state.STACKED_DIFF_STATE,
            false
        ) or closed
    end

    if not closed then
        return
    end

    window_state.clear_missing_diff_window_states(self)
    self.diff_preview_key = nil
    set_diff_context(self, nil, nil, nil, nil, nil)

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end
end

---@param self GitStatusWindow
---@return Buffer
function M.ensure_diff_buf(self)
    return preview_buffers.ensure_stacked(self, preview_actions(self))
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function M.open_diff(self, entry, section, opts)
    opts = opts or {}

    local preview_key =
        table.concat({ section or '', entry.orig_path or '', entry.path }, '\0')
    local layout = resolved_layout(self)
    local has_open_preview = (
        layout == 'split' and window_state.has_open_split_diff(self)
    )
        or (layout ~= 'split' and window_state.has_open_stacked_diff(self))

    if has_open_preview and self.diff_preview_key == preview_key then
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
                preview_actions(self)
            )

            if ok then
                set_diff_context(self, lines, nil, parsed_hunks, section, entry)
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
            show_headers = self.diff_show_headers,
            show_numbers = self.diff_show_numbers,
            syntax = syntax,
        })
    end

    diff_parser.assign_stacked_rows(parsed_hunks, raw_rows)

    local ok = display.show_stacked(
        self,
        diff_lines,
        preview_key,
        diff_title(entry, section),
        preview_actions(self)
    )

    if ok then
        set_diff_context(self, lines, raw_rows, parsed_hunks, section, entry)

        if self.diff_buf ~= nil then
            preview_buffers.set_goto_code_keymap(
                self.diff_buf.id,
                preview_actions(self)
            )
        end
    end

    return ok
end

---@param path string
local function edit_without_jumplist(path)
    vim.cmd('keepalt keepjumps edit ' .. vim.fn.fnameescape(path))
end

---@param self GitStatusWindow
---@return boolean
function M.goto_code(self)
    local position = preview_cursor.current_source_position(self)

    if position == nil then
        common.notify_warn('No source line under cursor')
        return false
    end

    -- For staged diffs the computed line number refers to the index version.
    -- If the file also has unstaged changes, translate through the unstaged
    -- diff so the cursor lands on the correct worktree line.
    if self.diff_section == 'staged' and self.diff_context_entry ~= nil then
        local unstaged_lines = git.diff(self.diff_context_entry, 'unstaged')

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
    local state = window_state.diff_window_state_for_win(self, win)

    if state == nil then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local diff_buffers, code_win =
        window_state.close_diff_windows_for_code(self, state)

    vim.api.nvim_set_current_win(code_win)
    local finish_related_open = self:begin_related_buffer_open()
    local ok, err = pcall(edit_without_jumplist, path)
    finish_related_open(ok and vim.api.nvim_get_current_buf() or nil)

    if not ok then
        common.notify_error(tostring(err), 'Cannot open ' .. position.path)
        window_state.delete_diff_buffers(diff_buffers)
        return false
    end

    preview_cursor.set_cursor_row(code_win, position.line)
    self.target_win = code_win

    window_state.delete_diff_buffers(diff_buffers)

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.stage_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'stage',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'unstage',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.discard_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'discard',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function M.preview_current_entry(self, opts)
    opts = opts or {}

    local item = selection.current_entry_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No git status entry under cursor')
        end

        return false
    end

    return M.open_diff(self, item.entry, item.section, {
        force = opts.force,
        focus = opts.focus,
    })
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return boolean?
function M.refresh_current_entry(self, state)
    if not M.has_open_diff(self) then
        return
    end

    local preview_key = self.diff_preview_key or ''

    if vim.startswith(preview_key, 'commit:') then
        local item = refresh_commit_item(self, state)

        if item == nil then
            return
        end

        return M.open_commit_diff(self, item.commit, {
            force = true,
        })
    end

    local item = refresh_entry_item(self, state)

    if item == nil then
        return
    end

    return M.open_diff(self, item.entry, item.section, {
        force = true,
    })
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function M.preview_current_commit(self, opts)
    opts = opts or {}

    local item = selection.current_commit_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No unpushed commit under cursor')
        end

        return false
    end

    return M.open_commit_diff(self, item.commit, {
        force = opts.force,
    })
end

return M
