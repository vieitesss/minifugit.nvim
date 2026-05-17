local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))
local project_root = vim.fs.dirname(tests_dir)

vim.opt.runtimepath:prepend(project_root)
vim.opt.runtimepath:prepend(project_root .. '/plenary.nvim')

vim.g.mapleader = ' '

---@class TermStub
---@field isatty fun(): boolean
---@field colors table<string, fun(value: string): string>

---@type TermStub
package.loaded.term = package.loaded.term
    or {
        isatty = function()
            return false
        end,
        colors = setmetatable({}, {
            ---@return fun(value: string): string
            __index = function()
                ---@param value string
                ---@return string
                return function(value)
                    return value
                end
            end,
        }),
    }
