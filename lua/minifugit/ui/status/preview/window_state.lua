local Buffer = require('minifugit.ui.buffer')
local common = require('minifugit.ui.status.common')
local window = require('minifugit.ui.status.window')

local M = {}

---@param win number?
local function diffoff(win)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('diffoff')
        end)
    end
end

---@param buf Buffer?
---@param win number?
---@return boolean
local function has_diff_side(buf, win)
    if buf == nil or not buf:is_valid() or not common.is_valid_win(win) then
        return false
    end

    win = assert(win)
    return vim.api.nvim_win_get_buf(win) == buf.id
end

---@param self GitStatusWindow
local function clear_diff_context(self)
    self.diff_raw_lines = nil
    self.diff_raw_rows = nil
    self.diff_hunks = nil
    self.diff_section = nil
    self.diff_context_entry = nil
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

M.STACKED_DIFF_STATE = DIFF_WINDOW_STATES[1]
M.SPLIT_DIFF_CLOSE_STATES = {
    DIFF_WINDOW_STATES[3],
    DIFF_WINDOW_STATES[2],
}

---@param self GitStatusWindow
---@return boolean
function M.has_open_split_diff(self)
    return has_diff_side(self.diff_left_buf, self.diff_left_win)
        and has_diff_side(self.diff_right_buf, self.diff_right_win)
end

---@param self GitStatusWindow
---@return boolean
function M.has_any_split_diff(self)
    return has_diff_side(self.diff_left_buf, self.diff_left_win)
        or has_diff_side(self.diff_right_buf, self.diff_right_win)
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_stacked_diff(self)
    return has_diff_side(self.diff_buf, self.diff_win)
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return M.has_open_stacked_diff(self) or M.has_any_split_diff(self)
end

---@param self GitStatusWindow
---@param buf integer
---@return MiniFugitDiffWindowState?
function M.diff_window_state_for_buf(self, buf)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        local diff_buf = self[state.buf_field]

        if diff_buf ~= nil and diff_buf.id == buf then
            return state
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param win number
---@return MiniFugitDiffWindowState?
function M.diff_window_state_for_win(self, win)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if self[state.win_field] == win then
            return state
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param state MiniFugitDiffWindowState
function M.clear_diff_window_state(self, state)
    self[state.win_field] = nil
    self[state.prev_buf_field] = nil
    self[state.prev_winopts_field] = nil
    self[state.created_win_field] = false
end

---@param self GitStatusWindow
function M.clear_missing_diff_window_states(self)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if not has_diff_side(self[state.buf_field], self[state.win_field]) then
            M.clear_diff_window_state(self, state)
        end
    end
end

---@param self GitStatusWindow
---@param buf integer
function M.restore_replaced_diff_window(self, buf)
    local state = M.diff_window_state_for_buf(self, buf)

    if state == nil then
        return
    end

    local win = self[state.win_field]

    if not common.is_valid_win(win) then
        M.clear_diff_window_state(self, state)
        return
    end

    if vim.api.nvim_win_get_buf(win) == buf then
        return
    end

    if state.split then
        diffoff(win)
    end

    window.restore_winopts(win, self[state.prev_winopts_field])
    M.clear_diff_window_state(self, state)
end

---@param self GitStatusWindow
---@param buf integer
function M.attach_autocmds(self, buf)
    if self.autocmd_group == nil then
        return
    end

    vim.api.nvim_clear_autocmds({
        group = self.autocmd_group,
        buffer = buf,
    })
    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = self.autocmd_group,
        buffer = buf,
        callback = function(args)
            vim.schedule(function()
                M.restore_replaced_diff_window(self, args.buf)
            end)
        end,
    })
end

---@param self GitStatusWindow
---@return Buffer[]
function M.diff_buffers(self)
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
function M.clear_diff_buffers(self)
    for _, state in ipairs(DIFF_WINDOW_STATES) do
        self[state.buf_field] = nil
    end
end

---@param buffers Buffer[]
function M.delete_diff_buffers(buffers)
    for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
    end
end

---@param self GitStatusWindow
---@param state MiniFugitDiffWindowState
---@param keep_win boolean
---@return boolean
function M.restore_or_close_diff_window(self, state, keep_win)
    local win = self[state.win_field]

    if not common.is_valid_win(win) then
        M.clear_diff_window_state(self, state)
        return false
    end

    if state.split then
        diffoff(win)
    end

    if keep_win then
        window.restore_winopts(win, self[state.prev_winopts_field])
        M.clear_diff_window_state(self, state)
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

    M.clear_diff_window_state(self, state)
    return true
end

---@param self GitStatusWindow
---@param states MiniFugitDiffWindowState[]
---@return boolean
function M.restore_or_close_diff_windows(self, states)
    local restored = false

    for _, state in ipairs(states) do
        restored = M.restore_or_close_diff_window(self, state, false)
            or restored
    end

    return restored
end

---@param self GitStatusWindow
---@param current_state MiniFugitDiffWindowState
---@return MiniFugitDiffWindowState
function M.code_window_state_for_diff(self, current_state)
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
function M.close_diff_windows_for_code(self, current_state)
    local buffers = M.diff_buffers(self)
    local code_state = M.code_window_state_for_diff(self, current_state)
    local code_win = self[code_state.win_field]

    for _, state in ipairs(DIFF_WINDOW_STATES) do
        if state == code_state then
            M.restore_or_close_diff_window(self, state, true)
        elseif current_state.split and state.split then
            M.restore_or_close_diff_window(self, state, false)
        end
    end

    self.diff_preview_key = nil
    clear_diff_context(self)
    M.clear_diff_buffers(self)
    M.clear_missing_diff_window_states(self)

    return buffers, code_win
end

return M
