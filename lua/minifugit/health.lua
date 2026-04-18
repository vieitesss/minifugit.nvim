local M = {}

local check_git_installed = function()
    return vim.fn.executable("git")
end

M.check = function()
    vim.health.start('minifugit.nvim report')
    -- make sure setup function parameters are ok
    if check_git_installed() then
        vim.health.ok('`git` is installed')
    else
        vim.health.error('`git` is not installed')
    end
end

return M
