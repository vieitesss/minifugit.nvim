local keymaps = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui')

---@param buf integer
function keymaps.apply(buf)
    if not ui.ensure_open_window(buf) then
        log.error('Could not apply git_status keymaps on buffer=' .. buf)
        return
    end

    vim.api.nvim_buf_set_keymap(
        buf,
        'n',
        '<CR>',
        "<CMD>lua require('minifugit.git_status.actions').go_to_file()<CR>",
        {}
    )
end

return keymaps
