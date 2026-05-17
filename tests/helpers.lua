---@class MinifugitTestHelpers
---@field run fun(args: string[], cwd: string): string
---@field write_file fun(path: string, lines: string[])

local git_env = {
    GIT_CONFIG_GLOBAL = vim.uv.os_uname().sysname == 'Windows_NT' and 'NUL'
        or '/dev/null',
    GIT_CONFIG_NOSYSTEM = '1',
    GIT_TERMINAL_PROMPT = '0',
}

---@type MinifugitTestHelpers
local M = {
    ---@param args string[]
    ---@param cwd string
    ---@return string
    run = function(args, cwd)
        local result = vim.system(args, {
            text = true,
            cwd = cwd,
            env = git_env,
        }):wait()
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
