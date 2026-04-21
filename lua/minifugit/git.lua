---@class Git
---@field status function Gets the current status
---@field branch function Gets the current repository branch
---@field run function Executes a git command

---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@type Git
local git = {
    status = function() end,
    branch = function() end,
    run = function() end,
}

local log = require('minifugit.log')

---@param output string
---@param start integer
---@return string?, integer?
local function read_nul_field(output, start)
    local stop = output:find('\0', start, true)

    if stop == nil then
        return nil, nil
    end

    return output:sub(start, stop - 1), stop + 1
end

---@param staged string
---@param unstaged string
---@return boolean
local function is_rename_or_copy(staged, unstaged)
    return staged == 'R' or staged == 'C' or unstaged == 'R' or unstaged == 'C'
end

---@param output string
---@return GitStatusEntry[]
local function parse_status(output)
    local entries = {}
    local index = 1

    while index <= #output do
        local record
        record, index = read_nul_field(output, index)

        if record == nil then
            break
        end

        if record ~= '' then
            local staged = record:sub(1, 1)
            local unstaged = record:sub(2, 2)

            ---@type GitStatusEntry
            local entry = {
                staged = staged,
                unstaged = unstaged,
                path = record:sub(4),
            }

            if is_rename_or_copy(staged, unstaged) then
                entry.orig_path, index = read_nul_field(output, index)
            end

            table.insert(entries, entry)
        end
    end

    return entries
end

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
---@return string
local return_result = function(res)
    local value = res.exit_code == 0 and res.output or res.stderr

    -- Preserve meaningful leading spaces in outputs like `git status --short`.
    local v, _ = value:gsub('[\r\n]+$', '')
    return v
end

---@return string
function git.branch()
    ensure_git()

    local out = git.run({ 'branch', '--show-current' })
    return return_result(out)
end

---@return GitStatusEntry[]
function git.status()
    ensure_git()

    local out = git.run({ 'status', '--porcelain=v1', '-z' })

    if out.exit_code ~= 0 then
        return {}
    end

    return parse_status(out.output or '')
end

return git
