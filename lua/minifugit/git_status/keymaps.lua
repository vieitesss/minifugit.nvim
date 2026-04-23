local keymaps = {}

local log = require('minifugit.log')
local ui = require('minifugit.ui.utils')
local uis = require('minifugit.ui.status')

function keymaps.apply()
    local buf = uis.get_buf()
    local win = uis.get_win()
    if not ui.ensure_buf(buf) or not ui.ensure_win(win) then
        log.error(
            'Could not apply git_status keymaps on buf='
                .. buf
                .. ' win='
                .. win
        )
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
