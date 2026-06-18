-- Test init file for miniharp.nvim development
-- Add the plugin to runtime path
vim.opt.runtimepath:prepend('.')

vim.g.mapleader = ' '
vim.opt.relativenumber = true
vim.opt.number = true
vim.cmd('colorscheme catppuccin')

vim.pack.add({
    { src = vim.env.HOME .. '/personal/minifugit.nvim' },
})

local mf = require('minifugit').setup({
    preview = {
        wrap = false,
        show_line_numbers = true,
        show_metadata = false,
    },
    status = {
        width = 0.4,
        min_width = 20,
    },
})
local log = require('minifugit.log')

vim.keymap.set('n', '<leader>gs', function()
    mf.status()
end)
vim.keymap.set('n', '<leader>l', function()
    log.open()
end)
