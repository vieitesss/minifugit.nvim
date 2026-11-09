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

vim.api.nvim_create_autocmd('SessionLoadPost', {
    group = vim.api.nvim_create_augroup('minifugit_session', { clear = true }),
    desc = 'Drop status windows a session restored as empty buffers',
    callback = function()
        require('minifugit.ui.status.session').drop_restored()
    end,
})
