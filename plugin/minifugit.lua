if vim.g.loaded_minifugit then
    return
end
vim.g.loaded_minifugit = true

vim.api.nvim_create_user_command('MinifugitStatus', function()
    require('minifugit').status()
end, {
    desc = 'Open Minifugit status',
    force = true,
})
