-- Test init file for miniharp.nvim development
-- Add the plugin to runtime path
vim.opt.runtimepath:prepend('.')

vim.g.mapleader = ' '

vim.pack.add({
    { src = vim.env.HOME .. '/personal/minifugit.nvim' },
})

require('minifugit')
