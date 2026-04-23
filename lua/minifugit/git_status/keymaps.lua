local keymaps = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui.utils')

---@param buf integer
function keymaps.apply(buf)
    if not ui.ensure_buf(buf) or not ui.ensure_win() then
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

    vim.api.nvim_buf_set_keymap(
        buf,
        'n',
        '=',
        "<CMD>lua require('minifugit.git_status.actions').diff_file()<CR>",
        {}
    )
end

return keymaps
