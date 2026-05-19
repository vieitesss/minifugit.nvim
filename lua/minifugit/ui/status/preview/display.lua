local common = require('minifugit.ui.status.common')
local diff_parser = require('minifugit.ui.diff.parser')
local render = require('minifugit.ui.render')
local window = require('minifugit.ui.status.window')
local buffers = require('minifugit.ui.status.preview.buffers')
local window_state = require('minifugit.ui.status.preview.window_state')
local preview_util = require('minifugit.ui.status.preview.util')

local M = {}

local SPLIT_DIFF_NAMESPACE =
    vim.api.nvim_create_namespace('minifugit.ui.split_diff')

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
    local ok, err = pcall(function()
        vim.cmd(command)
    end)

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
            preview_util.diffoff(self.diff_left_win)
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

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local created_win = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
        vim.api.nvim_set_current_win(target_win)
    elseif window_state.has_open_stacked_diff(self) then
        target_win = assert(self.diff_win)
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
---@param actions MiniFugitPreviewBufferActions
---@return boolean
function M.show_split(self, split_diff, diff_lines, preview_key, title, actions)
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
    buffers.set_plain_lines(left_buf, split_diff.left.lines)
    buffers.set_plain_lines(right_buf, split_diff.right.lines)
    mark_split_changes(left_buf, right_buf, diff_lines, self.groups)

    if split_diff.filetype ~= '' then
        vim.bo[left_buf.id].filetype = split_diff.filetype
        vim.bo[right_buf.id].filetype = split_diff.filetype
    end

    local status_winfixwidth = make_status_win_resizable(self)
    local target_win
    local left_created = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
        vim.api.nvim_set_current_win(target_win)
    elseif window_state.has_open_split_diff(self) then
        -- Reuse the existing left window directly. find_target_win(self) could
        -- return diff_right_win if the user last focused it (self.target_win ==
        -- diff_right_win), which would make diff_left_win and diff_right_win
        -- point at the same window and corrupt the two-window layout.
        target_win = assert(self.diff_left_win)
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
            'rightbelow vsplit',
            right_status_winfixwidth
        )

        if right_win == nil then
            actions.close_diff()
            return false
        end

        right_created = true
    else
        right_win = assert(right_win)
        vim.api.nvim_set_current_win(right_win)
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
        not set_preview_win_buf(
            self,
            right_win,
            right_buf.id,
            right_created,
            right_status_winfixwidth
        )
    then
        actions.close_diff()
        return false
    end

    window.configure_split_diff_win(right_win)
    M.set_split_line_numbers(right_win, self.diff_show_numbers)
    vim.wo[right_win].wrap = self.diff_wrap
    vim.wo[right_win].winbar = title
        .. ' [2/2] '
        .. preview_util.winbar_text(split_diff.right.title)
    self.diff_right_win = right_win
    resize_split_preview_windows(self)

    preview_util.diffoff(self.diff_left_win)
    preview_util.diffoff(self.diff_right_win)
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

return M
