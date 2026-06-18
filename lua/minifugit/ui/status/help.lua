local Buffer = require('minifugit.ui.buffer')
local common = require('minifugit.ui.status.common')

local M = {}

local sections = {
    {
        title = 'Status window mappings',
        rows = {
            { '<CR> / o', 'Open the file or commit under the cursor' },
            { '=', 'Preview the diff for the entry under the cursor' },
            { 'q', 'Close the status window' },
            { '/', 'Filter entries by path or summary' },
            { '<BS>', 'Clear the active filter' },
            { 'r', 'Refresh Git status data' },
            { 's', 'Stage entry, or unstage it if already staged' },
            { 'u', 'Unstage the entry under the cursor' },
            { 'S', 'Stage all visible entries' },
            { 'U', 'Unstage all visible entries' },
            { 'd', 'Discard the entry with confirmation' },
            { 'D', 'Discard the entry without confirmation' },
            { 'c', 'Commit staged changes' },
            { 'p', 'Push unpushed commits' },
            { 'visual s', 'Stage the selected entries' },
            { 'visual u', 'Unstage the selected entries' },
            { 'al', 'Alternate diff preview stacked/split layout' },
            { '?', 'Toggle this mappings help' },
        },
    },
    {
        title = 'Diff preview mappings',
        rows = {
            { 'q', 'Close the diff preview' },
            {
                '<CR>',
                'Open the file at the diff line under the cursor',
                status_diff = true,
            },
            { '[h / ]h', 'Jump to the previous or next hunk' },
            { 's', 'Stage the hunk under the cursor' },
            { 'u', 'Unstage the hunk under the cursor' },
            { 'd', 'Discard the hunk under the cursor with confirmation' },
            { 'aw', 'Alternate line wrapping' },
            { 'an', 'Alternate line numbers' },
            { 'am', 'Alternate metadata rows (stacked only)' },
            { 'al', 'Alternate stacked/split layout' },
            { '?', 'Toggle this mappings help' },
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

---@param opts { include_status_diff_mappings: boolean }
---@return string[]
local function help_lines(opts)
    local lines = {}
    local key_width = 0

    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows) do
            if opts.include_status_diff_mappings or not row.status_diff then
                key_width = math.max(key_width, #row[1])
            end
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
            if opts.include_status_diff_mappings or not row.status_diff then
                table.insert(lines, pad(row[1], key_width) .. '  ' .. row[2])
            end
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

    local lines = help_lines({
        include_status_diff_mappings = self.diff_context_entry ~= nil,
    })
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

    self.help_buf:set_option('bufhidden', 'wipe')
    self.help_buf:set_modifiable(true)
    self.help_buf:set_lines(lines)
    self.help_buf:set_modifiable(false)

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
            desc = 'Close Minifugit mappings help',
            silent = true,
        })
    end
end

return M
