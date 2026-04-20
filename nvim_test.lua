-- Test init file for miniharp.nvim development
-- Add the plugin to runtime path
vim.opt.runtimepath:prepend('.')

vim.g.mapleader = ' '

vim.pack.add({
    { src = vim.env.HOME .. '/personal/minifugit.nvim' },
})

local mf = require('minifugit')
local log = require('minifugit.log')

vim.keymap.set('n', '<leader>gs', function()
    mf.status()
end)
vim.keymap.set('n', '<leader>l', function()
    log.open()
end)
