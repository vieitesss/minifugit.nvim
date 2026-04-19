---@class Git
---@field status function Gets the current status
---@field branch function Gets the current repository branch
---@field run function Executes a git command

---@type Git
local git = {
    status = function() end,
    branch = function() end,
    run = function() end,
}

local log = require('minifugit.log')

local ensure_git = function()
    local ok = vim.fn.executable('git')

    if ok == 0 then
        log.error('`git` is not executable')
        vim.print('[minifugit] `git` is not executable')
    end
end

---@class GitResult
---@field output string Command standard output
---@field exit_code number Command exit code
---@field stderr string Command standard error

---Executes a git command and returns the result
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? table Options { cwd = string?, ignore_error = boolean? }
---@return GitResult
function git.run(args, opts)
    opts = opts or {}
    ensure_git()

    local cmd = { 'git' }
    vim.list_extend(cmd, args)

    local cwd = opts.cwd or vim.fn.getcwd()

    local job = vim.system(cmd, { text = true, cwd = cwd })
    local result = job:wait()

    local output = result.stdout or ''
    local stderr = result.stderr or ''
    local exit_code = result.code or 1

    if exit_code ~= 0 and not opts.ignore_error then
        log.error(
            string.format(
                'git command failed (%d): %s\n%s',
                exit_code,
                table.concat(cmd, ' '),
                stderr
            )
        )
    end

    log.info(
        string.format(
            'output=%s, exit_code=%d, stderr=%s',
            output,
            exit_code,
            stderr
        )
    )

    return {
        output = output,
        exit_code = exit_code,
        stderr = stderr,
    }
end

---@param res GitResult
local return_result = function(res)
    if res.exit_code == 0 then
        return vim.trim(res.output)
    end

    return vim.trim(res.stderr)
end

function git.branch()
    ensure_git()

    local info = "HEAD: "

    local out = git.run({ 'branch', '--show-current' })
    local res = return_result(out)

    info = info .. res

    return info
end

return git
