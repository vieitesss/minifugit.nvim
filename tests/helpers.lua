---@class MinifugitTestHelpers
---@field assert_has_line_containing fun(lines: string[], expected: string)
---@field run fun(args: string[], cwd: string): string
---@field write_file fun(path: string, lines: string[])
---@field clone_repo_with_changed_file fun(repo: string, path: string, lines: string[]): string

local git_env = {
    GIT_CONFIG_GLOBAL = vim.uv.os_uname().sysname == 'Windows_NT' and 'NUL'
        or '/dev/null',
    GIT_CONFIG_NOSYSTEM = '1',
    GIT_TERMINAL_PROMPT = '0',
}

---@type MinifugitTestHelpers
local M = {
    ---@param lines string[]
    ---@param expected string
    assert_has_line_containing = function(lines, expected)
        for _, line in ipairs(lines) do
            if line:find(expected, 1, true) ~= nil then
                return
            end
        end

        assert.fail('Expected line containing not found: ' .. expected)
    end,

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

---@param repo string
---@param path string Relative path in the cloned repository.
---@param lines string[]
---@return string Temporary clone; the caller owns cleanup and cwd changes.
function M.clone_repo_with_changed_file(repo, path, lines)
    local clone = vim.fn.tempname()
    M.run({ 'git', 'clone', '--local', repo, clone }, repo)
    M.write_file(vim.fs.joinpath(clone, path), lines)
    return clone
end

return M
