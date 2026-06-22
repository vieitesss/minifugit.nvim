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

---@param self DiffPreview
---@return boolean
function M.toggle_split_numbers(self)
    local enabled = false

    for _, win in ipairs({ self.left.win, self.right.win }) do
        if common.is_valid_win(win) then
            enabled = not vim.wo[win].number
            break
        end
    end

    self.show_numbers = enabled

    for _, win in ipairs({ self.left.win, self.right.win }) do
        M.set_split_line_numbers(win, enabled)
    end

    return true
end

---@class MiniFugitStatusWinState
---@field winfixwidth boolean
---@field width integer

---@param self DiffPreview
---@return boolean
local function has_only_status_window(self)
    local status_win = self.host.win

    if not common.is_valid_win(status_win) then
        return false
    end

    local tabpage = vim.api.nvim_win_get_tabpage(status_win)

    return window.normal_window_count(tabpage) == 1
end

---@param self DiffPreview
---@return MiniFugitStatusWinState?
local function make_status_win_resizable(self)
    local status_win = self.host.win

    if not common.is_valid_win(status_win) then
        return nil
    end

    local width = vim.api.nvim_win_get_width(status_win)

    if has_only_status_window(self) then
        width = math.min(
            window.status_win_width(self.options.status),
            math.max(1, vim.o.columns - 1)
        )
    end

    local state = {
        winfixwidth = vim.wo[status_win].winfixwidth,
        width = width,
    }
    vim.wo[status_win].winfixwidth = false

    return state
end

---@param self DiffPreview
---@param state MiniFugitStatusWinState?
local function restore_status_win_state(self, state)
    local status_win = self.host.win

    if state == nil or not common.is_valid_win(status_win) then
        return
    end

    pcall(vim.api.nvim_win_set_width, status_win, state.width)
    vim.wo[status_win].winfixwidth = state.winfixwidth
end

---@param self DiffPreview
---@param anchor_win number?
---@param command string
---@param status_win_state MiniFugitStatusWinState?
---@return number?
local function create_preview_split(self, anchor_win, command, status_win_state)
    local current_win = vim.api.nvim_get_current_win()
    local status_win = self.host.win
    local split_win
    local ok, err = pcall(function()
        local win = common.is_valid_win(anchor_win) and anchor_win or status_win

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

---@param self DiffPreview
local function resize_split_windows(self)
    local width = math.max(1, math.floor((vim.o.columns - 2) / 3))

    local status_win = self.host.win

    for _, win in ipairs({ status_win, self.left.win, self.right.win }) do
        if common.is_valid_win(win) then
            pcall(vim.api.nvim_win_set_width, win, width)
        end
    end
end

---@param self DiffPreview
---@return boolean
function M.focus_open_diff(self)
    if common.is_valid_win(self.stacked.win) then
        vim.api.nvim_set_current_win(self.stacked.win)
        return true
    end

    if common.is_valid_win(self.right.win) then
        vim.api.nvim_set_current_win(self.right.win)
        return true
    end

    if common.is_valid_win(self.left.win) then
        vim.api.nvim_set_current_win(self.left.win)
        return true
    end

    return false
end

---@param self DiffPreview
---@param diff_lines MiniFugitRenderLine[]
---@param preview_key string
---@param title string
---@param actions MiniFugitPreviewBufferActions
---@return boolean
function M.show_stacked(self, diff_lines, preview_key, title, actions)
    local current_win = vim.api.nvim_get_current_win()
    local outgoing

    if window_state.has_any_split_diff(self) then
        if common.is_valid_win(self.right.win) then
            self.right:restore_or_close(false)
        end

        if common.is_valid_win(self.left.win) then
            outgoing = self.left
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

    if outgoing ~= nil and common.is_valid_win(outgoing.win) then
        target_win = outgoing.win
    elseif window_state.has_open_stacked_diff(self) then
        target_win = assert(self.stacked.win)
    else
        target_win = window.find_target_win(self.host)

        if target_win == nil then
            local status_win = self.host.win
            target_win = create_preview_split(
                self,
                status_win,
                'rightbelow vsplit',
                status_winfixwidth
            )
            created_win = target_win ~= nil
        end

        if target_win == nil then
            restore_current_win(current_win)
            return false
        end
    end

    target_win = assert(target_win)
    local ok, err = self.stacked:open(target_win, buf.id, {
        created = created_win,
        inherit_from = (outgoing ~= nil and target_win == outgoing.win)
                and outgoing
            or nil,
    })
    restore_status_win_state(self, status_winfixwidth)

    if not ok then
        common.notify_error(
            err or 'Could not set diff buffer',
            'Cannot open diff preview'
        )
        restore_current_win(current_win)
        return false
    end

    window.configure_diff_win(target_win)
    vim.wo[target_win].wrap = self.wrap
    vim.wo[target_win].winbar = title
    self.preview_key = preview_key

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

---@param self DiffPreview
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
    local outgoing

    if
        window_state.has_open_diff(self)
        and not window_state.has_open_split_diff(self)
    then
        outgoing = self.stacked
    end

    local alignment = split_align.align(
        split_diff.left.lines,
        split_diff.right.lines,
        diff_lines,
        hunks
    )

    local left_buf = buffers.ensure_split(
        self,
        'Minifugit diff left',
        self.left.buf,
        actions
    )
    local right_buf = buffers.ensure_split(
        self,
        'Minifugit diff right',
        self.right.buf,
        actions
    )

    self.left.buf = left_buf
    self.right.buf = right_buf
    window_state.attach_autocmds(self, left_buf.id)
    window_state.attach_autocmds(self, right_buf.id)

    buffers.set_plain_lines(left_buf, alignment.left_lines)
    buffers.set_plain_lines(right_buf, alignment.right_lines)

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

    self.left_rows = alignment.left_rows
    self.right_rows = alignment.right_rows
    self.anchors = alignment.anchors

    if split_diff.filetype ~= '' then
        left_buf:set_option('filetype', split_diff.filetype)
        right_buf:set_option('filetype', split_diff.filetype)
    end

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local left_created = false

    if outgoing ~= nil and common.is_valid_win(outgoing.win) then
        target_win = outgoing.win
    elseif window_state.has_open_split_diff(self) then
        target_win = assert(self.left.win)
    else
        target_win = window.find_target_win(self.host)

        if target_win == nil then
            local status_win = self.host.win
            target_win = create_preview_split(
                self,
                status_win,
                'rightbelow vsplit',
                status_winfixwidth
            )
            left_created = target_win ~= nil
        end

        if target_win == nil then
            restore_current_win(current_win)
            return false
        end
    end

    target_win = assert(target_win)
    local ok, err = self.left:open(target_win, left_buf.id, {
        created = left_created,
        inherit_from = (outgoing ~= nil and target_win == outgoing.win)
                and outgoing
            or nil,
    })
    restore_status_win_state(self, status_winfixwidth)

    if not ok then
        common.notify_error(
            err or 'Could not set diff buffer',
            'Cannot open diff preview'
        )
        restore_current_win(current_win)
        return false
    end

    window.configure_split_diff_win(target_win)
    M.set_split_line_numbers(target_win, self.show_numbers)
    vim.wo[target_win].wrap = self.wrap
    vim.wo[target_win].winbar = title
        .. ' [1/2] '
        .. preview_util.winbar_text(split_diff.left.title)

    local right_win = self.right.win
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
    ok, err =
        self.right:open(right_win, right_buf.id, { created = right_created })
    restore_status_win_state(self, right_status_winfixwidth)

    if not ok then
        common.notify_error(
            err or 'Could not set diff buffer',
            'Cannot open diff preview'
        )
        actions.close_diff()
        restore_current_win(current_win)
        return false
    end

    window.configure_split_diff_win(right_win)
    M.set_split_line_numbers(right_win, self.show_numbers)
    vim.wo[right_win].wrap = self.wrap
    vim.wo[right_win].winbar = title
        .. ' [2/2] '
        .. preview_util.winbar_text(split_diff.right.title)
    resize_split_windows(self)

    vim.wo[target_win].scrollbind = true
    vim.wo[target_win].cursorbind = true
    vim.wo[right_win].scrollbind = true
    vim.wo[right_win].cursorbind = true

    vim.api.nvim_win_call(target_win, function()
        vim.cmd('syncbind')
    end)

    self.preview_key = preview_key

    restore_current_win(current_win)

    return true
end

return M
