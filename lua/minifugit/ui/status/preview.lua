local Buffer = require('minifugit.ui.buffer')
local diff_parser = require('minifugit.ui.diff.parser')
local diff_position = require('minifugit.ui.diff.position')
local diff_render = require('minifugit.ui.diff.render')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local window = require('minifugit.ui.status.window')
local selection = require('minifugit.ui.status.selection')

local M = {}

local SPLIT_DIFF_NAMESPACE =
    vim.api.nvim_create_namespace('minifugit.ui.split_diff')

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

---@param text string
---@return string
local function winbar_text(text)
    return text:gsub('%%', '%%%%')
end

---@param commit GitCommit
---@return string
local function commit_diff_title(commit)
    return winbar_text('commit: ' .. commit.hash .. ' ' .. commit.message)
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@return string
local function diff_title(entry, section)
    local prefix = section or 'diff'
    local path = entry.orig_path ~= nil
            and (entry.orig_path .. ' -> ' .. entry.path)
        or entry.path

    return winbar_text(prefix .. ': ' .. path)
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

    return layout
end

---@param buf Buffer?
---@param win number?
---@return boolean
local function has_diff_side(buf, win)
    return buf ~= nil
        and buf:is_valid()
        and common.is_valid_win(win)
        and vim.api.nvim_win_get_buf(win) == buf.id
end

---@param self GitStatusWindow
---@return boolean
local function has_open_split_diff(self)
    return has_diff_side(self.diff_left_buf, self.diff_left_win)
        and has_diff_side(self.diff_right_buf, self.diff_right_win)
end

---@param self GitStatusWindow
---@return boolean
local function has_any_split_diff(self)
    return has_diff_side(self.diff_left_buf, self.diff_left_win)
        or has_diff_side(self.diff_right_buf, self.diff_right_win)
end

---@param self GitStatusWindow
---@return boolean
local function has_open_stacked_diff(self)
    return has_diff_side(self.diff_buf, self.diff_win)
end

---@param win number?
local function diffoff(win)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('diffoff')
        end)
    end
end

---@param win number?
---@param enabled boolean
local function set_split_line_numbers(win, enabled)
    if not common.is_valid_win(win) then
        return
    end

    vim.wo[win].number = enabled
    vim.wo[win].statuscolumn = enabled and '%l %s ' or '%s '
end

---@class MiniFugitStatusWinState
---@field winfixwidth boolean
---@field width integer

---@param self GitStatusWindow
---@return MiniFugitStatusWinState?
local function make_status_win_resizable(self)
    if not common.is_valid_win(self.win) then
        return nil
    end

    local state = {
        winfixwidth = vim.wo[self.win].winfixwidth,
        width = vim.api.nvim_win_get_width(self.win),
    }
    vim.wo[self.win].winfixwidth = false

    return state
end

---@param self GitStatusWindow
---@param state MiniFugitStatusWinState?
local function restore_status_win_state(self, state)
    if state == nil or not common.is_valid_win(self.win) then
        return
    end

    pcall(vim.api.nvim_win_set_width, self.win, state.width)
    vim.wo[self.win].winfixwidth = state.winfixwidth
end

---@param self GitStatusWindow
---@param command string
---@param status_win_state MiniFugitStatusWinState?
---@return number?
local function create_preview_split(self, command, status_win_state)
    local current_win = vim.api.nvim_get_current_win()
    local ok, err = pcall(vim.cmd, command)

    if not ok then
        restore_status_win_state(self, status_win_state)

        if common.is_valid_win(current_win) then
            pcall(vim.api.nvim_set_current_win, current_win)
        end

        common.notify_error(tostring(err), 'Cannot open diff preview')
        return nil
    end

    return vim.api.nvim_get_current_win()
end

---@param self GitStatusWindow
---@param win number
---@param buf integer
---@param created boolean
---@param status_win_state MiniFugitStatusWinState?
---@return boolean
local function set_preview_win_buf(self, win, buf, created, status_win_state)
    vim.wo[win].winfixwidth = false

    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
    restore_status_win_state(self, status_win_state)

    if ok then
        return true
    end

    if
        created
        and common.is_valid_win(win)
        and #vim.api.nvim_tabpage_list_wins(0) > 1
    then
        pcall(vim.api.nvim_win_close, win, true)
    end

    if self.win ~= nil and common.is_valid_win(self.win) then
        pcall(vim.api.nvim_set_current_win, self.win)
    end

    common.notify_error(tostring(err), 'Cannot open diff preview')
    return false
end

---@param self GitStatusWindow
---@param bufnr integer
local function set_goto_code_keymap(self, bufnr)
    vim.keymap.set('n', '<CR>', function()
        M.goto_code(self)
    end, {
        buffer = bufnr,
        desc = 'Go to code under git diff cursor',
        silent = true,
    })
end

---@param bufnr integer?
local function clear_goto_code_keymap(bufnr)
    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.keymap.del, 'n', '<CR>', { buffer = bufnr })
    end
end

---@param self GitStatusWindow
---@param lines string[]?
---@param raw_rows integer[]?
---@param hunks MiniFugitDiffHunk[]?
---@param section GitStatusSectionName?
---@param entry GitStatusEntry?
local function set_diff_context(self, lines, raw_rows, hunks, section, entry)
    self.diff_raw_lines = lines
    self.diff_raw_rows = raw_rows
    self.diff_hunks = hunks
    self.diff_section = section
    self.diff_entry = entry
end

---@param self GitStatusWindow
---@param buf_name string
---@param existing Buffer?
---@return Buffer
local function ensure_split_buf(self, buf_name, existing)
    if existing ~= nil and existing:is_valid() then
        return existing
    end

    local buf = Buffer.new({
        listed = false,
        scratch = true,
        name = buf_name,
    })

    vim.bo[buf.id].buftype = 'nofile'
    vim.bo[buf.id].bufhidden = 'hide'
    vim.bo[buf.id].swapfile = false

    vim.keymap.set('n', 'q', function()
        M.close_diff(self)
    end, {
        buffer = buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', 'w', function()
        M.toggle_wrap(self)
    end, {
        buffer = buf.id,
        desc = 'Toggle git diff preview wrap',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        vim.cmd('normal! ]c')
    end, {
        buffer = buf.id,
        desc = 'Jump to next git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        vim.cmd('normal! [c')
    end, {
        buffer = buf.id,
        desc = 'Jump to previous git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'l', function()
        local enabled = false

        for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
            if common.is_valid_win(win) then
                enabled = not vim.wo[win].number
                break
            end
        end

        self.diff_show_numbers = enabled

        for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
            set_split_line_numbers(win, enabled)
        end
    end, {
        buffer = buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 's', function()
        M.stage_current_hunk(self)
    end, {
        buffer = buf.id,
        desc = 'Stage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'u', function()
        M.unstage_current_hunk(self)
    end, {
        buffer = buf.id,
        desc = 'Unstage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'd', function()
        M.discard_current_hunk(self)
    end, {
        buffer = buf.id,
        desc = 'Discard current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 't', function()
        M.toggle_layout(self)
    end, {
        buffer = buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
        silent = true,
    })

    set_goto_code_keymap(self, buf.id)

    vim.keymap.set('n', '?', function()
        self:toggle_help()
    end, {
        buffer = buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return buf
end

---@param buf Buffer
---@param lines string[]
local function set_plain_lines(buf, lines)
    vim.bo[buf.id].modifiable = true
    vim.api.nvim_buf_set_lines(buf.id, 0, -1, false, lines)
    vim.bo[buf.id].modifiable = false
end

---@param win number?
---@param width integer
local function set_win_width(win, width)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_set_width, win, width)
    end
end

---@param self GitStatusWindow
local function resize_split_preview_windows(self)
    -- Split diff uses three vertical windows: status, left diff, and right
    -- diff. Account for the two vertical separators, then size each content
    -- window to one third of the usable width.
    local width = math.max(1, math.floor((vim.o.columns - 2) / 3))

    set_win_width(self.win, width)
    set_win_width(self.diff_left_win, width)
    set_win_width(self.diff_right_win, width)
end

---@class MiniFugitDiffCursor
---@field layout 'stacked'|'split'
---@field row integer
---@field side MiniFugitDiffSide?

---@param self GitStatusWindow
---@return MiniFugitDiffCursor?
local function current_diff_cursor(self)
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)
    local row = vim.api.nvim_win_get_cursor(current_win)[1]

    if self.diff_buf ~= nil and current_buf == self.diff_buf.id then
        return { layout = 'stacked', row = row }
    end

    if self.diff_left_buf ~= nil and current_buf == self.diff_left_buf.id then
        return { layout = 'split', side = 'left', row = row }
    end

    if self.diff_right_buf ~= nil and current_buf == self.diff_right_buf.id then
        return { layout = 'split', side = 'right', row = row }
    end

    return nil
end

---@param self GitStatusWindow
---@return MiniFugitDiffSourcePosition?
local function current_source_position(self)
    local entry = self.diff_entry

    if entry == nil then
        return nil
    end

    local cursor = current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    local line_number

    if cursor.layout == 'stacked' then
        local raw_row = self.diff_raw_rows and self.diff_raw_rows[cursor.row]
        line_number = diff_position.source_line_for_stacked_row(
            self.diff_raw_lines,
            self.diff_hunks,
            raw_row
        )
    elseif cursor.side ~= nil then
        line_number = diff_position.source_line_for_split_row(
            self.diff_raw_lines,
            self.diff_hunks,
            cursor.side,
            cursor.row
        )
    end

    if line_number == nil then
        return nil
    end

    return { path = entry.path, line = math.max(line_number, 1) }
end

---@param self GitStatusWindow
---@return MiniFugitDiffHunkPosition?
local function current_hunk_position(self)
    local cursor = current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    if cursor.layout == 'stacked' then
        local raw_row = self.diff_raw_rows and self.diff_raw_rows[cursor.row]

        return diff_position.hunk_position_for_raw_row(
            self.diff_raw_lines,
            self.diff_hunks,
            raw_row
        )
    end

    if cursor.side == nil then
        return nil
    end

    return diff_position.hunk_position_for_split_row(
        self.diff_hunks,
        cursor.side,
        cursor.row
    )
end

---@param win number
---@param row integer?
local function set_cursor_row(win, row)
    if row == nil then
        return
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
    local clamped = math.min(math.max(row, 1), line_count)

    pcall(vim.api.nvim_win_set_cursor, win, { clamped, 0 })
end

---@param self GitStatusWindow
---@param position MiniFugitDiffHunkPosition?
local function restore_hunk_position(self, position)
    if position == nil then
        return
    end

    local hunk =
        diff_position.hunk_by_index(self.diff_hunks, position.hunk_index)

    if hunk == nil then
        return
    end

    if common.is_valid_win(self.diff_win) then
        local row = diff_position.stacked_row_for_hunk_position(
            self.diff_raw_lines,
            self.diff_raw_rows,
            hunk,
            position.side,
            position.offset
        )

        vim.api.nvim_set_current_win(self.diff_win)
        set_cursor_row(self.diff_win, row)

        return
    end

    local side, row = diff_position.split_row_for_hunk_position(hunk, position)
    local win = side == 'left' and self.diff_left_win or self.diff_right_win

    if common.is_valid_win(win) then
        vim.api.nvim_set_current_win(win)
        set_cursor_row(win, row)
    end
end

---@param buf Buffer
---@param row integer?
---@param group string
---@param marker string
local function mark_split_change(buf, row, group, marker)
    if row == nil or row < 1 then
        return
    end

    pcall(
        vim.api.nvim_buf_set_extmark,
        buf.id,
        SPLIT_DIFF_NAMESPACE,
        row - 1,
        0,
        {
            line_hl_group = group,
            sign_text = marker,
            sign_hl_group = group,
            priority = 200,
        }
    )
end

---@param left_buf Buffer
---@param right_buf Buffer
---@param diff_lines string[]
---@param groups table<string, string>
local function mark_split_changes(left_buf, right_buf, diff_lines, groups)
    vim.api.nvim_buf_clear_namespace(left_buf.id, SPLIT_DIFF_NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(right_buf.id, SPLIT_DIFF_NAMESPACE, 0, -1)

    for _, line in ipairs(diff_parser.parse_lines(diff_lines)) do
        if line.kind == 'added' then
            mark_split_change(
                right_buf,
                line.new_number,
                groups.diff_added,
                '+'
            )
        elseif line.kind == 'removed' then
            mark_split_change(
                left_buf,
                line.old_number,
                groups.diff_removed,
                '-'
            )
        end
    end
end

---@param self GitStatusWindow
---@param hunk MiniFugitDiffHunk
---@return string[]?
local function hunk_patch(self, hunk)
    local lines = self.diff_raw_lines

    if lines == nil then
        common.notify_warn('Diff preview is not open')
        return nil
    end

    local hunk_start = hunk.raw_header_row
    local file_start = hunk_start

    while
        file_start > 1 and not vim.startswith(lines[file_start] or '', 'diff ')
    do
        file_start = file_start - 1
    end

    local header_stop = hunk_start - 1

    for row = file_start, hunk_start - 1 do
        if vim.startswith(lines[row] or '', '@@') then
            header_stop = row - 1
            break
        end
    end

    local patch = {}

    for row = file_start, header_stop do
        table.insert(patch, lines[row])
    end

    for row = hunk_start, hunk.raw_end_row do
        table.insert(patch, lines[row])
    end

    return patch
end

---@param self GitStatusWindow
---@return string[]?
local function current_hunk_patch(self)
    if not M.has_open_diff(self) or self.diff_raw_lines == nil then
        common.notify_warn('Diff preview is not open')
        return nil
    end

    local position = current_hunk_position(self)

    if position == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    local hunk =
        diff_position.hunk_by_index(self.diff_hunks, position.hunk_index)

    if hunk == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    return hunk_patch(self, hunk)
end

---@param self GitStatusWindow
---@param kind 'stage'|'unstage'|'discard'
---@return boolean
local function apply_current_hunk(self, kind)
    local section = self.diff_section

    if kind == 'stage' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to stage')
        return false
    end

    if kind == 'unstage' and section ~= 'staged' then
        common.notify_warn('No staged hunk to unstage')
        return false
    end

    if kind == 'discard' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to discard')
        return false
    end

    local patch = current_hunk_patch(self)

    if patch == nil then
        return false
    end

    if
        kind == 'discard'
        and vim.fn.confirm('Discard current hunk?', '&Discard\n&Cancel', 2)
            ~= 1
    then
        return false
    end

    local cursor_state = selection.capture_cursor_state(self)
    local ok, err = git.apply_hunk(patch, kind)

    if not ok then
        common.notify_error(err, 'Git hunk action failed')
        return false
    end

    self:refresh(cursor_state)

    if M.has_open_diff(self) then
        if common.is_valid_win(self.diff_win) then
            vim.api.nvim_set_current_win(self.diff_win)
        elseif common.is_valid_win(self.diff_right_win) then
            vim.api.nvim_set_current_win(self.diff_right_win)
        elseif common.is_valid_win(self.diff_left_win) then
            vim.api.nvim_set_current_win(self.diff_left_win)
        end
    end

    return true
end

---@param self GitStatusWindow
---@param delta integer
---@return boolean
function M.jump_hunk(self, delta)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    if not common.is_valid_win(self.diff_win) then
        -- Split diff layout uses vim-native ]c / [c for hunk navigation.
        return false
    end

    local win = self.diff_win
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    local lines = vim.api.nvim_buf_get_lines(self.diff_buf.id, 0, -1, false)
    local start = delta > 0 and cursor + 1 or cursor - 1
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

    local position = current_hunk_position(self)
    local ok = M.set_layout(self, next_layout)

    if ok then
        restore_hunk_position(self, position)
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
    return has_open_stacked_diff(self) or has_any_split_diff(self)
end

---@param self GitStatusWindow
---@param diff_lines MiniFugitRenderLine[]
---@param preview_key string
---@param title string
---@return boolean
local function show_diff_lines(self, diff_lines, preview_key, title)
    if has_any_split_diff(self) then
        M.close_diff(self)
    end

    local buf = M.ensure_diff_buf(self)

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local created_win = false

    if has_open_stacked_diff(self) then
        target_win = self.diff_win
        vim.api.nvim_set_current_win(target_win)
    else
        target_win = window.find_target_win(self)

        if target_win == nil then
            target_win = create_preview_split(
                self,
                'rightbelow vsplit',
                status_winfixwidth
            )

            if target_win == nil then
                return false
            end

            self.target_win = target_win
            created_win = true
        else
            vim.api.nvim_set_current_win(target_win)
        end
    end

    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id
        and self.diff_win == target_win

    if not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_prev_winopts = window.capture_winopts(target_win)
        self.diff_created_win = created_win
    end

    if
        not set_preview_win_buf(
            self,
            target_win,
            buf.id,
            created_win,
            status_winfixwidth
        )
    then
        return false
    end

    window.configure_diff_win(target_win)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = title
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@param self GitStatusWindow
---@param split_diff GitSplitDiff
---@param diff_lines string[]
---@param preview_key string
---@param title string
---@return boolean
local function show_split_diff(self, split_diff, diff_lines, preview_key, title)
    if M.has_open_diff(self) and not has_open_split_diff(self) then
        M.close_diff(self)
    end

    local left_buf =
        ensure_split_buf(self, 'Minifugit diff left', self.diff_left_buf)
    local right_buf =
        ensure_split_buf(self, 'Minifugit diff right', self.diff_right_buf)

    self.diff_left_buf = left_buf
    self.diff_right_buf = right_buf
    set_plain_lines(left_buf, split_diff.left.lines)
    set_plain_lines(right_buf, split_diff.right.lines)
    mark_split_changes(left_buf, right_buf, diff_lines, self.groups)

    if split_diff.filetype ~= '' then
        vim.bo[left_buf.id].filetype = split_diff.filetype
        vim.bo[right_buf.id].filetype = split_diff.filetype
    end

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local left_created = false

    if has_open_split_diff(self) then
        -- Reuse the existing left window directly. find_target_win(self) could
        -- return diff_right_win if the user last focused it (self.target_win ==
        -- diff_right_win), which would make diff_left_win and diff_right_win
        -- point at the same window and corrupt the two-window layout.
        target_win = self.diff_left_win
        vim.api.nvim_set_current_win(target_win)
    else
        target_win = window.find_target_win(self)

        if target_win == nil then
            target_win = create_preview_split(
                self,
                'rightbelow vsplit',
                status_winfixwidth
            )

            if target_win == nil then
                return false
            end

            self.target_win = target_win
            left_created = true
        else
            vim.api.nvim_set_current_win(target_win)
        end
    end

    local was_left_preview = target_win == self.diff_left_win
        and vim.api.nvim_win_get_buf(target_win) == left_buf.id

    if not was_left_preview then
        self.diff_left_prev_buf = vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = window.capture_winopts(target_win)
        self.diff_left_created_win = left_created
    end

    if
        not set_preview_win_buf(
            self,
            target_win,
            left_buf.id,
            left_created,
            status_winfixwidth
        )
    then
        return false
    end

    window.configure_split_diff_win(target_win)
    set_split_line_numbers(target_win, self.diff_show_numbers)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar =
        winbar_text(title .. ' [1/2] ' .. split_diff.left.title)
    self.diff_left_win = target_win

    local right_win = self.diff_right_win
    local right_status_winfixwidth = make_status_win_resizable(self)
    local right_created = false

    if not common.is_valid_win(right_win) then
        right_win = create_preview_split(
            self,
            'rightbelow vsplit',
            right_status_winfixwidth
        )

        if right_win == nil then
            M.close_diff(self)
            return false
        end

        right_created = true
    else
        vim.api.nvim_set_current_win(right_win)
    end

    local was_right_preview = vim.api.nvim_win_get_buf(right_win)
        == right_buf.id

    if not was_right_preview then
        self.diff_right_prev_buf = vim.api.nvim_win_get_buf(right_win)
        self.diff_right_prev_winopts = window.capture_winopts(right_win)
        self.diff_right_created_win = right_created
    end

    if
        not set_preview_win_buf(
            self,
            right_win,
            right_buf.id,
            right_created,
            right_status_winfixwidth
        )
    then
        M.close_diff(self)
        return false
    end

    window.configure_split_diff_win(right_win)
    set_split_line_numbers(right_win, self.diff_show_numbers)
    vim.wo[right_win].wrap = self.diff_wrap
    vim.wo[right_win].winbar =
        winbar_text(title .. ' [2/2] ' .. split_diff.right.title)
    self.diff_right_win = right_win
    resize_split_preview_windows(self)

    diffoff(self.diff_left_win)
    diffoff(self.diff_right_win)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_right_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffupdate')
        vim.cmd('syncbind')
    end)

    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@type MiniFugitDiffWindowState[]
local DIFF_WINDOW_STATES = {
    {
        win_field = 'diff_win',
        prev_buf_field = 'diff_prev_buf',
        prev_winopts_field = 'diff_prev_winopts',
        created_win_field = 'diff_created_win',
        buf_field = 'diff_buf',
    },
    {
        win_field = 'diff_left_win',
        prev_buf_field = 'diff_left_prev_buf',
        prev_winopts_field = 'diff_left_prev_winopts',
        created_win_field = 'diff_left_created_win',
        buf_field = 'diff_left_buf',
        split = true,
    },
    {
        win_field = 'diff_right_win',
        prev_buf_field = 'diff_right_prev_buf',
        prev_winopts_field = 'diff_right_prev_winopts',
        created_win_field = 'diff_right_created_win',
        buf_field = 'diff_right_buf',
        split = true,
    },
}

local STACKED_DIFF_STATE = DIFF_WINDOW_STATES[1]
local SPLIT_DIFF_CLOSE_STATES = {
    DIFF_WINDOW_STATES[3],
    DIFF_WINDOW_STATES[2],
}

---@param self GitStatusWindow
---@param win number
---@return MiniFugitDiffWindowState?
local function diff_window_state_for_win(self, win)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if self[state.win_field] == win then
            return state
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param state MiniFugitDiffWindowState
local function clear_diff_window_state(self, state)
    self[state.win_field] = nil
    self[state.prev_buf_field] = nil
    self[state.prev_winopts_field] = nil
    self[state.created_win_field] = false
end

---@param self GitStatusWindow
local function clear_missing_diff_window_states(self)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if not has_diff_side(self[state.buf_field], self[state.win_field]) then
            clear_diff_window_state(self, state)
        end
    end
end

---@param self GitStatusWindow
---@return Buffer[]
local function diff_buffers(self)
    local buffers = {}

    for _, state in ipairs(DIFF_WINDOW_STATES) do
        local buf = self[state.buf_field]

        if buf ~= nil and buf:is_valid() then
            table.insert(buffers, buf)
        end
    end

    return buffers
end

---@param self GitStatusWindow
local function clear_diff_buffers(self)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        self[state.buf_field] = nil
    end
end

---@param buffers Buffer[]
local function delete_diff_buffers(buffers)
    for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
    end
end

---@param self GitStatusWindow
---@param state MiniFugitDiffWindowState
---@param keep_win boolean
---@return boolean
local function restore_or_close_diff_window(self, state, keep_win)
    local win = self[state.win_field]

    if not common.is_valid_win(win) then
        clear_diff_window_state(self, state)
        return false
    end

    if state.split then
        diffoff(win)
    end

    if keep_win then
        window.restore_winopts(win, self[state.prev_winopts_field])
        clear_diff_window_state(self, state)
        return true
    end

    if
        self[state.created_win_field]
        and #vim.api.nvim_tabpage_list_wins(0) > 1
    then
        vim.api.nvim_win_close(win, true)
    elseif
        self[state.prev_buf_field]
        and vim.api.nvim_buf_is_valid(self[state.prev_buf_field])
    then
        vim.api.nvim_win_set_buf(win, self[state.prev_buf_field])
        window.restore_winopts(win, self[state.prev_winopts_field])
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(win, true)
    else
        window.restore_winopts(win, self[state.prev_winopts_field])
    end

    clear_diff_window_state(self, state)
    return true
end

---@param self GitStatusWindow
---@param states MiniFugitDiffWindowState[]
---@return boolean
local function restore_or_close_diff_windows(self, states)
    local restored = false

    for _, state in ipairs(states) do
        restored = restore_or_close_diff_window(self, state, false) or restored
    end

    return restored
end

---@param self GitStatusWindow
---@param current_state MiniFugitDiffWindowState
---@return MiniFugitDiffWindowState
local function code_window_state_for_diff(self, current_state)
    if not current_state.split then
        return current_state
    end

    local left_state = DIFF_WINDOW_STATES[2]

    if common.is_valid_win(self[left_state.win_field]) then
        return left_state
    end

    return current_state
end

---@param self GitStatusWindow
---@param current_state MiniFugitDiffWindowState
---@return Buffer[]
---@return number
local function close_diff_windows_for_code(self, current_state)
    local buffers = diff_buffers(self)
    local code_state = code_window_state_for_diff(self, current_state)
    local code_win = self[code_state.win_field]

    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if state == code_state then
            restore_or_close_diff_window(self, state, true)
        elseif current_state.split and state.split then
            restore_or_close_diff_window(self, state, false)
        end
    end

    self.diff_preview_key = nil
    set_diff_context(self, nil, nil, nil, nil, nil)
    clear_diff_buffers(self)
    clear_missing_diff_window_states(self)

    return buffers, code_win
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

    local ok = show_diff_lines(
        self,
        diff_lines,
        preview_key,
        commit_diff_title(commit)
    )

    if ok and self.diff_buf ~= nil then
        clear_goto_code_keymap(self.diff_buf.id)
    end

    return ok
end

---@param self GitStatusWindow
function M.close_diff(self)
    local closed = false

    if has_any_split_diff(self) then
        closed = restore_or_close_diff_windows(self, SPLIT_DIFF_CLOSE_STATES)
    end

    if has_open_stacked_diff(self) then
        closed = restore_or_close_diff_window(self, STACKED_DIFF_STATE, false)
            or closed
    end

    if not closed then
        return
    end

    clear_missing_diff_window_states(self)
    self.diff_preview_key = nil
    set_diff_context(self, nil, nil, nil, nil, nil)

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end
end

---@param self GitStatusWindow
---@return Buffer
function M.ensure_diff_buf(self)
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

    vim.keymap.set('n', 'q', function()
        M.close_diff(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        M.jump_hunk(self, 1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to next git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        M.jump_hunk(self, -1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to previous git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'w', function()
        M.toggle_wrap(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview wrap',
        silent = true,
    })

    vim.keymap.set('n', 'l', function()
        M.toggle_numbers(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 'm', function()
        M.toggle_headers(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview metadata',
        silent = true,
    })

    vim.keymap.set('n', 's', function()
        M.stage_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Stage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'u', function()
        M.unstage_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Unstage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'd', function()
        M.discard_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Discard current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 't', function()
        M.toggle_layout(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
        silent = true,
    })

    vim.keymap.set('n', '?', function()
        self:toggle_help()
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return self.diff_buf
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean? }
---@return boolean
function M.open_diff(self, entry, section, opts)
    opts = opts or {}

    local preview_key =
        table.concat({ section or '', entry.orig_path or '', entry.path }, '\0')
    local layout = resolved_layout(self)
    local has_open_preview = (layout == 'split' and has_open_split_diff(self))
        or (layout ~= 'split' and has_open_stacked_diff(self))

    if
        not opts.force
        and has_open_preview
        and self.diff_preview_key == preview_key
    then
        return true
    end

    local lines, err = git.diff(entry, section)

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    local hunks = diff_parser.parse_hunks(lines)
    local split_diff, split_err = git.split_diff(entry, section)

    if layout == 'split' then
        if split_diff ~= nil then
            local ok = show_split_diff(
                self,
                split_diff,
                lines,
                preview_key,
                diff_title(entry, section)
            )

            if ok then
                set_diff_context(self, lines, nil, hunks, section, entry)
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

    diff_parser.assign_stacked_rows(hunks, raw_rows)

    local ok = show_diff_lines(
        self,
        diff_lines,
        preview_key,
        diff_title(entry, section)
    )

    if ok then
        set_diff_context(self, lines, raw_rows, hunks, section, entry)

        if self.diff_buf ~= nil then
            set_goto_code_keymap(self, self.diff_buf.id)
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
    local position = current_source_position(self)

    if position == nil then
        common.notify_warn('No source line under cursor')
        return false
    end

    -- For staged diffs the computed line number refers to the index version.
    -- If the file also has unstaged changes, translate through the unstaged
    -- diff so the cursor lands on the correct worktree line.
    if self.diff_section == 'staged' and self.diff_entry ~= nil then
        local unstaged_lines = git.diff(self.diff_entry, 'unstaged')

        if #unstaged_lines > 0 then
            local unstaged_hunks = diff_parser.parse_hunks(unstaged_lines)
            position = {
                path = position.path,
                line = diff_position.old_line_to_new_line(
                    unstaged_lines,
                    unstaged_hunks,
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
    local state = diff_window_state_for_win(self, win)

    if state == nil then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local buffers, code_win = close_diff_windows_for_code(self, state)

    vim.api.nvim_set_current_win(code_win)
    edit_without_jumplist(path)
    set_cursor_row(code_win, position.line)
    self.target_win = code_win

    delete_diff_buffers(buffers)

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.stage_current_hunk(self)
    return apply_current_hunk(self, 'stage')
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_current_hunk(self)
    return apply_current_hunk(self, 'unstage')
end

---@param self GitStatusWindow
---@return boolean
function M.discard_current_hunk(self)
    return apply_current_hunk(self, 'discard')
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
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
