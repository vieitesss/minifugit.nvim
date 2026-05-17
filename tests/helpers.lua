---@class MinifugitTestHelpers
---@field run fun(args: string[], cwd: string): string
---@field write_file fun(path: string, lines: string[])

---@type MinifugitTestHelpers
local M = {
    ---@param args string[]
    ---@param cwd string
    ---@return string
    run = function(args, cwd)
        local result = vim.system(args, { text = true, cwd = cwd }):wait()
        assert.are.equal(0, result.code, result.stderr)
        return result.stdout or ''
    end,

    ---@param path string
    ---@param lines string[]
    write_file = function(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        vim.fn.writefile(lines, path)
    end,
}

return M
