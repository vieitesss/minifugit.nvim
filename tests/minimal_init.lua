vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. '/plenary.nvim')

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
