local preview = require('minifugit.ui.status.preview')

local M = {}

---@param self GitStatusWindow
function M.attach(self)
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    vim.keymap.set('n', '<CR>', function()
        self:enter_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Open git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'o', function()
        self:enter_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Open git status entry',
        silent = true,
    })

    vim.keymap.set('n', '=', function()
        self:diff_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Show git status entry diff',
        silent = true,
    })

    vim.keymap.set('n', 'q', function()
        self:close()
    end, {
        buffer = self.buf.id,
        desc = 'Close git status window',
        silent = true,
    })

    vim.keymap.set('n', '/', function()
        self:filter_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Filter git status entries',
        silent = true,
    })

    vim.keymap.set('n', '<BS>', function()
        self:clear_filter()
    end, {
        buffer = self.buf.id,
        desc = 'Clear git status filter',
        silent = true,
    })

    vim.keymap.set('n', 'r', function()
        self:refresh()
    end, {
        buffer = self.buf.id,
        desc = 'Refresh git status',
        silent = true,
    })

    vim.keymap.set('n', 's', function()
        self:stage_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Stage git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'u', function()
        self:unstage_entry()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'S', function()
        self:stage_all_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Stage all git status entries',
        silent = true,
    })

    vim.keymap.set('n', 'U', function()
        self:unstage_all_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage all git status entries',
        silent = true,
    })

    vim.keymap.set('n', 'd', function()
        self:discard_entry(false)
    end, {
        buffer = self.buf.id,
        desc = 'Discard git status entry',
        silent = true,
    })

    vim.keymap.set('n', 'D', function()
        self:discard_entry(true)
    end, {
        buffer = self.buf.id,
        desc = 'Discard git status entry without confirmation',
        silent = true,
    })

    vim.keymap.set('n', 'c', function()
        self:commit()
    end, {
        buffer = self.buf.id,
        desc = 'Commit staged changes',
        silent = true,
    })

    vim.keymap.set('n', 'p', function()
        self:push()
    end, {
        buffer = self.buf.id,
        desc = 'Push unpushed commits',
        silent = true,
    })

    vim.keymap.set('n', '?', function()
        self:toggle_help()
    end, {
        buffer = self.buf.id,
        desc = 'Toggle git status mappings',
        silent = true,
    })

    vim.keymap.set('n', 't', function()
        preview.toggle_layout(self)
    end, {
        buffer = self.buf.id,
        desc = 'Toggle stacked/split diff preview layout',
        silent = true,
    })

    vim.keymap.set('x', 's', function()
        self:stage_selected_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Stage selected git status entries',
        silent = true,
    })

    vim.keymap.set('x', 'u', function()
        self:unstage_selected_entries()
    end, {
        buffer = self.buf.id,
        desc = 'Unstage selected git status entries',
        silent = true,
    })

    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = self.buf.id,
        callback = function()
            if preview.has_open_diff(self) then
                local opts = { force = false, notify = false }

                if not preview.preview_current_commit(self, opts) then
                    preview.preview_current_entry(self, opts)
                end
            end
        end,
    })
end

return M
