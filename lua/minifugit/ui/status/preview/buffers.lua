require('minifugit.ui.status.preview.types')

local Buffer = require('minifugit.ui.buffer')

local M = {}

---@param bufnr integer
---@param actions MiniFugitPreviewBufferActions
function M.set_goto_code_keymap(bufnr, actions)
    vim.keymap.set('n', '<CR>', actions.goto_code, {
        buffer = bufnr,
        desc = 'Open file at diff line under cursor',
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
    buf:set_modifiable(true)
    vim.api.nvim_buf_set_lines(buf.id, 0, -1, false, lines)
    buf:set_modifiable(false)
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

    vim.keymap.set('n', 'q', actions.close_diff, {
        buffer = self.diff_buf.id,
        desc = 'Close Minifugit diff preview',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        actions.jump_hunk(1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to next diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        actions.jump_hunk(-1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to previous diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'aw', actions.toggle_wrap, {
        buffer = self.diff_buf.id,
        desc = 'Alternate diff preview line wrapping',
        silent = true,
    })

    vim.keymap.set('n', 'an', actions.toggle_numbers, {
        buffer = self.diff_buf.id,
        desc = 'Alternate diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 'am', actions.toggle_headers, {
        buffer = self.diff_buf.id,
        desc = 'Alternate stacked diff metadata rows',
        silent = true,
    })

    vim.keymap.set('n', 's', actions.stage_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Stage hunk under cursor',
        silent = true,
    })

    vim.keymap.set('n', 'u', actions.unstage_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Unstage hunk under cursor',
        silent = true,
    })

    vim.keymap.set('n', 'd', actions.discard_current_hunk, {
        buffer = self.diff_buf.id,
        desc = 'Discard hunk under cursor with confirmation',
        silent = true,
    })

    vim.keymap.set('n', 'al', actions.toggle_layout, {
        buffer = self.diff_buf.id,
        desc = 'Alternate diff preview between stacked and split layout',
        silent = true,
    })

    M.set_goto_code_keymap(self.diff_buf.id, actions)

    vim.keymap.set('n', '?', actions.toggle_help, {
        buffer = self.diff_buf.id,
        desc = 'Toggle Minifugit mappings help',
        silent = true,
    })

    return self.diff_buf
end

---@param buf_name string
---@param existing Buffer?
---@param actions MiniFugitPreviewBufferActions
---@return Buffer
function M.ensure_split(_, buf_name, existing, actions)
    if existing ~= nil and existing:is_valid() then
        return existing
    end

    local buf = Buffer.new({
        listed = false,
        scratch = true,
        name = buf_name,
    })

    vim.keymap.set('n', 'q', actions.close_diff, {
        buffer = buf.id,
        desc = 'Close Minifugit diff preview',
        silent = true,
    })

    vim.keymap.set('n', 'aw', actions.toggle_wrap, {
        buffer = buf.id,
        desc = 'Alternate diff preview line wrapping',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        actions.jump_hunk(1)
    end, {
        buffer = buf.id,
        desc = 'Jump to next diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        actions.jump_hunk(-1)
    end, {
        buffer = buf.id,
        desc = 'Jump to previous diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'an', actions.toggle_split_numbers, {
        buffer = buf.id,
        desc = 'Alternate diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 's', actions.stage_current_hunk, {
        buffer = buf.id,
        desc = 'Stage hunk under cursor',
        silent = true,
    })

    vim.keymap.set('n', 'u', actions.unstage_current_hunk, {
        buffer = buf.id,
        desc = 'Unstage hunk under cursor',
        silent = true,
    })

    vim.keymap.set('n', 'd', actions.discard_current_hunk, {
        buffer = buf.id,
        desc = 'Discard hunk under cursor with confirmation',
        silent = true,
    })

    vim.keymap.set('n', 'al', actions.toggle_layout, {
        buffer = buf.id,
        desc = 'Alternate diff preview between stacked and split layout',
        silent = true,
    })

    M.set_goto_code_keymap(buf.id, actions)

    vim.keymap.set('n', '?', actions.toggle_help, {
        buffer = buf.id,
        desc = 'Toggle Minifugit mappings help',
        silent = true,
    })

    return buf
end

return M
