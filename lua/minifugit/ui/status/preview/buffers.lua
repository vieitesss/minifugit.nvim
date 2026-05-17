local Buffer = require('minifugit.ui.buffer')

local M = {}

---@class MiniFugitPreviewBufferActions
---@field close_diff fun()
---@field jump_hunk fun(delta: integer)
---@field toggle_wrap fun()
---@field toggle_numbers fun()
---@field toggle_headers fun()
---@field toggle_split_numbers fun()
---@field stage_current_hunk fun()
---@field unstage_current_hunk fun()
---@field discard_current_hunk fun()
---@field toggle_layout fun()
---@field goto_code fun()
---@field toggle_help fun()

---@class MiniFugitPreviewActions : MiniFugitPreviewBufferActions
---@field has_open_diff fun(): boolean
---@field focus_open_diff fun()
---@field refresh fun(state: GitStatusCursorState?)

---@param bufnr integer
---@param actions MiniFugitPreviewBufferActions
function M.set_goto_code_keymap(bufnr, actions)
    vim.keymap.set('n', '<CR>', actions.goto_code, {
        buffer = bufnr,
        desc = 'Go to code under git diff cursor',
        silent = true,
    })
end

---@param bufnr integer?
function M.clear_goto_code_keymap(bufnr)
    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.keymap.del, 'n', '<CR>', { buffer = bufnr })
    end
end

---@param buf Buffer
---@param lines string[]
function M.set_plain_lines(buf, lines)
    vim.bo[buf.id].modifiable = true
    vim.api.nvim_buf_set_lines(buf.id, 0, -1, false, lines)
    vim.bo[buf.id].modifiable = false
end

---@param self GitStatusWindow
---@param actions MiniFugitPreviewBufferActions
---@return Buffer
function M.ensure_stacked(self, actions)
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

    vim.keymap.set('n', 'q', actions.close_diff, {
        buffer = self.diff_buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        actions.jump_hunk(1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to next git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        actions.jump_hunk(-1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to previous git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'w', actions.toggle_wrap, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview wrap',
        silent = true,
    })

    vim.keymap.set('n', 'l', actions.toggle_numbers, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 'm', actions.toggle_headers, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview metadata',
        silent = true,
    })

    vim.keymap.set('n', 's', actions.stage_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Stage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'u', actions.unstage_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Unstage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'd', actions.discard_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Discard current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 't', actions.toggle_layout, {
        buffer = self.diff_buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
        silent = true,
    })

    M.set_goto_code_keymap(self.diff_buf.id, actions)

    vim.keymap.set('n', '?', actions.toggle_help, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return self.diff_buf
end

---@param self GitStatusWindow
---@param buf_name string
---@param existing Buffer?
---@param actions MiniFugitPreviewBufferActions
---@return Buffer
function M.ensure_split(self, buf_name, existing, actions)
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

    vim.keymap.set('n', 'q', actions.close_diff, {
        buffer = buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', 'w', actions.toggle_wrap, {
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

    vim.keymap.set('n', 'l', actions.toggle_split_numbers, {
        buffer = buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 's', actions.stage_current_hunk, {
        buffer = buf.id,
        desc = 'Stage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'u', actions.unstage_current_hunk, {
        buffer = buf.id,
        desc = 'Unstage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'd', actions.discard_current_hunk, {
        buffer = buf.id,
        desc = 'Discard current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 't', actions.toggle_layout, {
        buffer = buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
        silent = true,
    })

    M.set_goto_code_keymap(buf.id, actions)

    vim.keymap.set('n', '?', actions.toggle_help, {
        buffer = buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return buf
end

return M
