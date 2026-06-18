local common = require('minifugit.ui.status.common')
local diff_parser = require('minifugit.ui.diff.parser')
local render = require('minifugit.ui.render')
local window = require('minifugit.ui.status.window')
local buffers = require('minifugit.ui.status.preview.buffers')
local window_state = require('minifugit.ui.status.preview.window_state')
local preview_util = require('minifugit.ui.status.preview.util')
local split_align = require('minifugit.ui.diff.split_align')
local word_diff = require('minifugit.ui.diff.word_diff')

local M = {}

local SPLIT_LINE_NAMESPACE =
    vim.api.nvim_create_namespace('minifugit.ui.split_line')

local SPLIT_INTRALINE_NAMESPACE =
    vim.api.nvim_create_namespace('minifugit.ui.split_intra')

---@param win number?
local function restore_current_win(win)
    if common.is_valid_win(win) and vim.api.nvim_get_current_win() ~= win then
        pcall(vim.api.nvim_set_current_win, win)
    end
end

---@param win number?
---@param enabled boolean
function M.set_split_line_numbers(win, enabled)
    if not common.is_valid_win(win) then
        return
    end

    vim.wo[win].number = enabled
    vim.wo[win].statuscolumn = enabled and '%l %s ' or '%s '
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_split_numbers(self)
    local enabled = false

    for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
        if common.is_valid_win(win) then
            enabled = not vim.wo[win].number
            break
        end
    end

    self.diff_show_numbers = enabled

    for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
        M.set_split_line_numbers(win, enabled)
    end

    return true
end

---@class MiniFugitStatusWinState
---@field winfixwidth boolean
---@field width integer

---@param self GitStatusWindow
---@return boolean
local function has_only_status_window(self)
    if not common.is_valid_win(self.win) then
        return false
    end

    local tabpage = vim.api.nvim_win_get_tabpage(self.win)

    return window.normal_window_count(tabpage) == 1
end

---@param self GitStatusWindow
---@return MiniFugitStatusWinState?
local function make_status_win_resizable(self)
    if not common.is_valid_win(self.win) then
        return nil
    end

    local width = vim.api.nvim_win_get_width(self.win)

    if has_only_status_window(self) then
        width = math.min(
            window.status_win_width(self.options.status),
            math.max(1, vim.o.columns - 1)
        )
    end

    local state = {
        winfixwidth = vim.wo[self.win].winfixwidth,
        width = width,
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
---@param anchor_win number?
---@param command string
---@param status_win_state MiniFugitStatusWinState?
---@return number?
local function create_preview_split(self, anchor_win, command, status_win_state)
    local current_win = vim.api.nvim_get_current_win()
    local split_win
    local ok, err = pcall(function()
        local win = common.is_valid_win(anchor_win) and anchor_win or self.win

        if common.is_valid_win(win) then
            vim.api.nvim_win_call(win, function()
                vim.cmd(command)
                split_win = vim.api.nvim_get_current_win()
            end)
        else
            vim.cmd(command)
            split_win = vim.api.nvim_get_current_win()
        end
    end)

    if
        common.is_valid_win(current_win)
        and vim.api.nvim_get_current_win() ~= current_win
    then
        restore_current_win(current_win)
    end

    if not ok then
        restore_status_win_state(self, status_win_state)
        common.notify_error(tostring(err), 'Cannot open diff preview')
        return nil
    end

    return split_win
end

---@param self GitStatusWindow
---@param win number
---@param buf integer
---@param created boolean
---@param status_win_state MiniFugitStatusWinState?
---@return boolean
local function set_win_buf(self, win, buf, created, status_win_state)
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
local function resize_split_windows(self)
    local width = math.max(1, math.floor((vim.o.columns - 2) / 3))

    for _, win in ipairs({ self.win, self.diff_left_win, self.diff_right_win }) do
        if common.is_valid_win(win) then
            pcall(vim.api.nvim_win_set_width, win, width)
        end
    end
end

---@param self GitStatusWindow
---@return boolean
function M.focus_open_diff(self)
    if common.is_valid_win(self.diff_win) then
        vim.api.nvim_set_current_win(self.diff_win)
        return true
    end

    if common.is_valid_win(self.diff_right_win) then
        vim.api.nvim_set_current_win(self.diff_right_win)
        return true
    end

    if common.is_valid_win(self.diff_left_win) then
        vim.api.nvim_set_current_win(self.diff_left_win)
        return true
    end

    return false
end

---@param self GitStatusWindow
---@param diff_lines MiniFugitRenderLine[]
---@param preview_key string
---@param title string
---@param actions MiniFugitPreviewBufferActions
---@return boolean
function M.show_stacked(self, diff_lines, preview_key, title, actions)
    local current_win = vim.api.nvim_get_current_win()
    local transition_win
    local transition_prev_buf
    local transition_prev_winopts
    local transition_created_win = false

    if window_state.has_any_split_diff(self) then
        if common.is_valid_win(self.diff_right_win) then
            window_state.restore_or_close_diff_window(
                self,
                window_state.SPLIT_RIGHT_DIFF_STATE,
                false
            )
        end

        if common.is_valid_win(self.diff_left_win) then
            transition_win = self.diff_left_win
            transition_prev_buf = self.diff_left_prev_buf
            transition_prev_winopts = self.diff_left_prev_winopts
            transition_created_win = self.diff_left_created_win == true
            window_state.clear_diff_window_state(
                self,
                window_state.SPLIT_LEFT_DIFF_STATE
            )
        end
    end

    local buf = buffers.ensure_stacked(self, actions)
    window_state.attach_autocmds(self, buf.id)

    buf:set_modifiable(true)
    buf:set_lines(render.text_lines(diff_lines))
    buf:set_modifiable(false)
    render.apply(buf.id, diff_lines)

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local created_win = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
    elseif window_state.has_open_stacked_diff(self) then
        target_win = assert(self.diff_win)
    else
        target_win = create_preview_split(
            self,
            self.win,
            'rightbelow vsplit',
            status_winfixwidth
        )
        created_win = target_win ~= nil

        if target_win == nil then
            restore_current_win(current_win)
            return false
        end
    end

    target_win = assert(target_win)
    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id
        and self.diff_win == target_win

    if transition_win == target_win then
        self.diff_prev_buf = transition_prev_buf or previous_buf
        self.diff_prev_winopts = transition_prev_winopts
            or window.capture_winopts(target_win)
        self.diff_created_win = transition_created_win
    elseif not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_prev_winopts = window.capture_winopts(target_win)
        self.diff_created_win = created_win
    end

    if
        not set_win_buf(
            self,
            target_win,
            buf.id,
            created_win,
            status_winfixwidth
        )
    then
        restore_current_win(current_win)
        return false
    end

    window.configure_diff_win(target_win)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = title
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    restore_current_win(current_win)

    return true
end

---Apply line-background extmarks to a split diff buffer using alignment rows.
---@param bufnr integer
---@param rows MiniFugitSplitRow[]
---@param groups table<string, string>
---@param side MiniFugitDiffSide
local function apply_split_line_highlights(bufnr, rows, groups, side)
    vim.api.nvim_buf_clear_namespace(bufnr, SPLIT_LINE_NAMESPACE, 0, -1)

    local line_hl = side == 'left' and groups.diff_removed or groups.diff_added
    local change_kind = side == 'left' and 'delete' or 'add'

    for buf_row, meta in ipairs(rows) do
        if meta.kind == change_kind then
            pcall(
                vim.api.nvim_buf_set_extmark,
                bufnr,
                SPLIT_LINE_NAMESPACE,
                buf_row - 1,
                0,
                {
                    end_row = buf_row - 1,
                    end_col = #(vim.api.nvim_buf_get_lines(
                        bufnr,
                        buf_row - 1,
                        buf_row,
                        false
                    )[1] or ''),
                    hl_eol = true,
                    hl_group = line_hl,
                    priority = 200,
                }
            )
        end
    end
end

---Apply intra-line word-change extmarks using word-diff between paired
---deleted/added lines.
---@param bufnr integer
---@param rows MiniFugitSplitRow[]
---@param hunks MiniFugitDiffHunk[]
---@param groups table<string, string>
---@param side MiniFugitDiffSide
---@param raw_diff_lines string[]
local function apply_split_intraline_highlights(
    bufnr,
    rows,
    hunks,
    groups,
    side,
    raw_diff_lines
)
    vim.api.nvim_buf_clear_namespace(bufnr, SPLIT_INTRALINE_NAMESPACE, 0, -1)

    local text_hl = side == 'left' and groups.diff_removed_intraline
        or groups.diff_added_intraline

    -- Parse all diff lines once, indexed by raw_row.
    local parsed = diff_parser.parse_lines(raw_diff_lines or {})
    ---@type table<integer, MiniFugitDiffLine>
    local by_raw_row = {}
    for _, dl in ipairs(parsed) do
        by_raw_row[dl.raw_row] = dl
    end

    for _, hunk in ipairs(hunks or {}) do
        local del_lines = {}
        local add_lines = {}
        local in_hunk = false

        for raw_row = hunk.raw_start_row, hunk.raw_end_row do
            local dl = by_raw_row[raw_row]

            if dl ~= nil then
                if dl.kind == 'hunk' and dl.raw_row == hunk.raw_header_row then
                    in_hunk = true
                end

                if in_hunk then
                    if dl.kind == 'removed' then
                        table.insert(del_lines, dl)
                    elseif dl.kind == 'added' then
                        table.insert(add_lines, dl)
                    end
                end
            end
        end

        if #del_lines > 0 and #add_lines > 0 then
            local pairs_count = math.min(#del_lines, #add_lines)

            for pair_i = 1, pairs_count do
                local del = del_lines[pair_i]
                local add = add_lines[pair_i]

                if del.text and add.text then
                    local old_text = del.text:sub(2)
                    local new_text = add.text:sub(2)
                    local ranges = word_diff.changed_ranges(
                        old_text,
                        new_text,
                        side == 'left' and 'left' or 'right'
                    )

                    for _, range in ipairs(ranges) do
                        for buf_row, meta in ipairs(rows) do
                            local matches_row = side == 'right'
                                    and meta.new_lnum == add.new_number
                                    and meta.kind == 'add'
                                or side == 'left'
                                    and meta.old_lnum == del.old_number
                                    and meta.kind == 'delete'

                            if matches_row then
                                pcall(
                                    vim.api.nvim_buf_set_extmark,
                                    bufnr,
                                    SPLIT_INTRALINE_NAMESPACE,
                                    buf_row - 1,
                                    range.start_col,
                                    {
                                        end_col = range.end_col,
                                        hl_group = text_hl,
                                        priority = 201,
                                    }
                                )
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

---@param self GitStatusWindow
---@param split_diff GitSplitDiff
---@param diff_lines string[]
---@param hunks MiniFugitDiffHunk[]
---@param preview_key string
---@param title string
---@param actions MiniFugitPreviewBufferActions
---@return boolean
function M.show_split(
    self,
    split_diff,
    diff_lines,
    hunks,
    preview_key,
    title,
    actions
)
    local current_win = vim.api.nvim_get_current_win()
    local transition_win
    local transition_prev_buf
    local transition_prev_winopts
    local transition_created_win = false

    if
        window_state.has_open_diff(self)
        and not window_state.has_open_split_diff(self)
    then
        transition_win = self.diff_win
        transition_prev_buf = self.diff_prev_buf
        transition_prev_winopts = self.diff_prev_winopts
        transition_created_win = self.diff_created_win == true
        window_state.clear_diff_window_state(
            self,
            window_state.STACKED_DIFF_STATE
        )
    end

    -- Build hunk-only alignment from split_diff contents and parsed hunks.
    local alignment = split_align.align(
        split_diff.left.lines,
        split_diff.right.lines,
        diff_lines,
        hunks
    )

    local left_buf = buffers.ensure_split(
        self,
        'Minifugit diff left',
        self.diff_left_buf,
        actions
    )
    local right_buf = buffers.ensure_split(
        self,
        'Minifugit diff right',
        self.diff_right_buf,
        actions
    )

    self.diff_left_buf = left_buf
    self.diff_right_buf = right_buf
    window_state.attach_autocmds(self, left_buf.id)
    window_state.attach_autocmds(self, right_buf.id)

    -- Write aligned lines (hunks only) to both buffers.
    buffers.set_plain_lines(left_buf, alignment.left_lines)
    buffers.set_plain_lines(right_buf, alignment.right_lines)

    -- Apply line-background and intra-line highlights.
    apply_split_line_highlights(
        left_buf.id,
        alignment.left_rows,
        self.groups,
        'left'
    )
    apply_split_line_highlights(
        right_buf.id,
        alignment.right_rows,
        self.groups,
        'right'
    )
    apply_split_intraline_highlights(
        left_buf.id,
        alignment.left_rows,
        hunks,
        self.groups,
        'left',
        diff_lines
    )
    apply_split_intraline_highlights(
        right_buf.id,
        alignment.right_rows,
        hunks,
        self.groups,
        'right',
        diff_lines
    )

    -- Store alignment metadata for cursor position lookup.
    self.diff_left_rows = alignment.left_rows
    self.diff_right_rows = alignment.right_rows
    self.diff_anchors = alignment.anchors

    if split_diff.filetype ~= '' then
        left_buf:set_option('filetype', split_diff.filetype)
        right_buf:set_option('filetype', split_diff.filetype)
    end

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local left_created = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
    elseif window_state.has_open_split_diff(self) then
        target_win = assert(self.diff_left_win)
    else
        target_win = create_preview_split(
            self,
            self.win,
            'rightbelow vsplit',
            status_winfixwidth
        )
        left_created = target_win ~= nil

        if target_win == nil then
            restore_current_win(current_win)
            return false
        end
    end

    target_win = assert(target_win)
    local was_left_preview = target_win == self.diff_left_win
        and vim.api.nvim_win_get_buf(target_win) == left_buf.id

    if transition_win == target_win then
        self.diff_left_prev_buf = transition_prev_buf
            or vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = transition_prev_winopts
            or window.capture_winopts(target_win)
        self.diff_left_created_win = transition_created_win
    elseif not was_left_preview then
        self.diff_left_prev_buf = vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = window.capture_winopts(target_win)
        self.diff_left_created_win = left_created
    end

    if
        not set_win_buf(
            self,
            target_win,
            left_buf.id,
            left_created,
            status_winfixwidth
        )
    then
        restore_current_win(current_win)
        return false
    end

    window.configure_split_diff_win(target_win)
    M.set_split_line_numbers(target_win, self.diff_show_numbers)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = title
        .. ' [1/2] '
        .. preview_util.winbar_text(split_diff.left.title)
    self.diff_left_win = target_win

    local right_win = self.diff_right_win
    local right_status_winfixwidth = make_status_win_resizable(self)
    local right_created = false

    if not common.is_valid_win(right_win) then
        right_win = create_preview_split(
            self,
            target_win,
            'rightbelow vsplit',
            right_status_winfixwidth
        )

        if right_win == nil then
            actions.close_diff()
            restore_current_win(current_win)
            return false
        end

        right_created = true
    else
        right_win = assert(right_win)
    end

    right_win = assert(right_win)
    local was_right_preview = vim.api.nvim_win_get_buf(right_win)
        == right_buf.id

    if not was_right_preview then
        self.diff_right_prev_buf = vim.api.nvim_win_get_buf(right_win)
        self.diff_right_prev_winopts = window.capture_winopts(right_win)
        self.diff_right_created_win = right_created
    end

    if
        not set_win_buf(
            self,
            right_win,
            right_buf.id,
            right_created,
            right_status_winfixwidth
        )
    then
        actions.close_diff()
        restore_current_win(current_win)
        return false
    end

    window.configure_split_diff_win(right_win)
    M.set_split_line_numbers(right_win, self.diff_show_numbers)
    vim.wo[right_win].wrap = self.diff_wrap
    vim.wo[right_win].winbar = title
        .. ' [2/2] '
        .. preview_util.winbar_text(split_diff.right.title)
    self.diff_right_win = right_win
    resize_split_windows(self)

    -- Set scrollbind and cursorbind instead of using diffthis.
    vim.wo[target_win].scrollbind = true
    vim.wo[target_win].cursorbind = true
    vim.wo[right_win].scrollbind = true
    vim.wo[right_win].cursorbind = true

    vim.api.nvim_win_call(target_win, function()
        vim.cmd('syncbind')
    end)

    self.diff_preview_key = preview_key

    restore_current_win(current_win)

    return true
end

return M
