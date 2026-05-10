local Buffer = require('minifugit.ui.buffer')
local common = require('minifugit.ui.status.common')

local M = {}

local sections = {
    {
        title = 'Status window mappings',
        rows = {
            { '<CR> / o', 'Open entry' },
            { '=', 'Preview diff' },
            { 'q', 'Close status window' },
            { '/', 'Filter entries' },
            { '<BS>', 'Clear filter' },
            { 'r', 'Refresh status' },
            { 's', 'Stage or unstage entry' },
            { 'u', 'Unstage entry' },
            { 'S', 'Stage all entries' },
            { 'U', 'Unstage all entries' },
            { 'd', 'Discard with confirmation' },
            { 'D', 'Discard without confirmation' },
            { 'c', 'Commit staged changes' },
            { 'p', 'Push unpushed commits' },
            { 'visual s', 'Stage selection' },
            { 'visual u', 'Unstage selection' },
            { 't', 'Toggle stacked/split diff layout' },
            { '?', 'Toggle mappings help' },
        },
    },
    {
        title = 'Diff preview mappings',
        rows = {
            { 'q', 'Close diff preview' },
            { '[h / ]h', 'Jump to previous or next hunk' },
            { 's', 'Stage current unstaged hunk' },
            { 'u', 'Unstage current staged hunk' },
            { 'd', 'Discard current unstaged hunk' },
            { 'w', 'Toggle wrap' },
            { 'l', 'Toggle line numbers' },
            { 'm', 'Toggle metadata rows' },
            { 't', 'Toggle stacked/split layout' },
            { '?', 'Toggle mappings help' },
        },
    },
}

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    if #text >= width then
        return text
    end

    return text .. string.rep(' ', width - #text)
end

---@return string[]
local function help_lines()
    local lines = {}
    local key_width = 0

    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows) do
            key_width = math.max(key_width, #row[1])
        end
    end

    table.insert(lines, 'Mappings')
    table.insert(lines, '')

    for section_index, section in ipairs(sections) do
        table.insert(lines, section.title)
        table.insert(lines, pad('Key', key_width) .. '  Action')
        table.insert(
            lines,
            string.rep('-', key_width) .. '  ' .. string.rep('-', 32)
        )

        for _, row in ipairs(section.rows) do
            table.insert(lines, pad(row[1], key_width) .. '  ' .. row[2])
        end

        if section_index < #sections then
            table.insert(lines, '')
        end
    end

    return lines
end

---@param lines string[]
---@return integer
local function content_width(lines)
    local width = 1

    for _, line in ipairs(lines) do
        width = math.max(width, #line)
    end

    return width
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_help(self)
    return self.help_buf ~= nil
        and self.help_buf:is_valid()
        and common.is_valid_win(self.help_win)
        and vim.api.nvim_win_get_buf(self.help_win) == self.help_buf.id
end

---@param self GitStatusWindow
function M.close(self)
    if not M.has_open_help(self) then
        return
    end

    vim.api.nvim_win_close(self.help_win, true)
    self.help_win = nil

    if self.help_buf ~= nil and self.help_buf:is_valid() then
        self.help_buf:delete()
    end

    self.help_buf = nil

    if common.is_valid_win(self.help_prev_win) then
        vim.api.nvim_set_current_win(self.help_prev_win)
    end

    self.help_prev_win = nil
end

---@param self GitStatusWindow
function M.toggle(self)
    if M.has_open_help(self) then
        M.close(self)
        return
    end

    local lines = help_lines()
    local max_width = math.min(vim.o.columns, math.max(24, vim.o.columns - 4))
    local max_height = math.min(vim.o.lines, math.max(6, vim.o.lines - 4))
    local width = math.min(content_width(lines) + 4, max_width)
    local height = math.min(#lines + 2, max_height)
    local row = math.max(0, math.floor((vim.o.lines - height) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    self.help_prev_win = vim.api.nvim_get_current_win()
    self.help_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Minifugit mappings',
    })

    vim.bo[self.help_buf.id].buftype = 'nofile'
    vim.bo[self.help_buf.id].bufhidden = 'wipe'
    vim.bo[self.help_buf.id].swapfile = false
    vim.bo[self.help_buf.id].modifiable = true
    self.help_buf:set_lines(lines)
    vim.bo[self.help_buf.id].modifiable = false

    self.help_win = vim.api.nvim_open_win(self.help_buf.id, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        border = 'rounded',
        title = ' minifugit ',
        title_pos = 'center',
        style = 'minimal',
    })

    vim.wo[self.help_win].wrap = false
    vim.wo[self.help_win].cursorline = false

    for _, key in ipairs({ 'q', '?', '<Esc>' }) do
        vim.keymap.set('n', key, function()
            M.close(self)
        end, {
            buffer = self.help_buf.id,
            desc = 'Close git mappings help',
            silent = true,
        })
    end
end

return M
