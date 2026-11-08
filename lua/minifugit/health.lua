local M = {}

local check_git_installed = function()
    if vim.fn.executable('git') then
        vim.health.ok('`git` is installed')
    else
        vim.health.error('`git` is not installed')
    end
end

local check_nvim_version = function()
    if vim.version.ge(vim.version(), '0.11') then
        vim.health.ok('Version v0.11+')
    else
        vim.health.error('Version should be v0.11+')
    end
end

M.check = function()
    vim.health.start('minifugit.nvim report')
    -- make sure setup function parameters are ok
    check_nvim_version()
    check_git_installed()
end

return M
