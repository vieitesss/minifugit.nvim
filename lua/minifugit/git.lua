---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field root string
---@field error string?

local git = {}

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
    local index
    index = 1

    while index <= #output do
        local record
        record, index = read_nul_field(output, index)

        if record == nil or index == nil then
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

---@return boolean
local function ensure_git()
    local ok = vim.fn.executable('git')

    if ok == 0 then
        log.error('`git` is not executable')
        vim.print('[minifugit] `git` is not executable')
        return false
    end

    return true
end

---@alias GitResult {
---output: string,
---exit_code: string,
---stderr: string,
---}

---Executes a git command and returns the result
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? table Options { cwd = string?, ignore_error = boolean? }
---@return GitResult
function git.run(args, opts)
    opts = opts or {}

    if not ensure_git() then
        return {
            output = '',
            exit_code = 127,
            stderr = '`git` is not executable',
        }
    end

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
local function return_result(res)
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

---@return string
function git.root()
    ensure_git()

    local out = git.run(
        { 'rev-parse', '--show-toplevel' },
        { ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return ''
    end

    return return_result(out)
end

---@return GitStatusEntry[]
function git.status()
    ensure_git()

    local out = git.run({ 'status', '--porcelain=v1', '-z' })

    if out.exit_code ~= 0 then
        return {}
    end

    return parse_status(out.output)
end

---@return GitStatusSnapshot
function git.status_snapshot()
    if not ensure_git() then
        return {
            branch = '',
            entries = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    local root = git.root()

    if root == '' then
        return {
            branch = '',
            entries = {},
            root = '',
            error = 'Not inside a git repository',
        }
    end

    local branch_out = git.run(
        { 'branch', '--show-current' },
        { cwd = root, ignore_error = true }
    )
    local branch = return_result(branch_out)

    if branch == '' then
        local head_out = git.run(
            { 'rev-parse', '--short', 'HEAD' },
            { cwd = root, ignore_error = true }
        )

        branch = head_out.exit_code == 0 and return_result(head_out)
            or '(unknown)'
    end

    local status_out = git.run(
        { 'status', '--porcelain=v1', '-z' },
        { cwd = root }
    )

    if status_out.exit_code ~= 0 then
        return {
            branch = branch,
            entries = {},
            root = root,
            error = return_result(status_out),
        }
    end

    return {
        branch = branch,
        entries = parse_status(status_out.output),
        root = root,
    }
end

---@return table
local function root_opts()
    local root = git.root()
    local opts = { ignore_error = true }

    if root ~= '' then
        opts.cwd = root
    end

    return opts
end

---@param entry GitStatusEntry
---@return string[]
local function entry_pathspecs(entry)
    if entry.orig_path == nil then
        return { entry.path }
    end

    return { entry.orig_path, entry.path }
end

---@param entries GitStatusEntry[]
---@return string[]
local function entries_pathspecs(entries)
    local pathspecs = {}
    local seen = {}

    for _, entry in ipairs(entries) do
        for _, path in ipairs(entry_pathspecs(entry)) do
            if not seen[path] then
                table.insert(pathspecs, path)
                seen[path] = true
            end
        end
    end

    return pathspecs
end

---@param entry GitStatusEntry
---@return boolean
function git.stage(entry)
    return git.stage_entries({ entry })
end

---@param entries GitStatusEntry[]
---@return boolean
function git.stage_entries(entries)
    ensure_git()

    local pathspecs = entries_pathspecs(entries)

    if #pathspecs == 0 then
        return true
    end

    local args = { 'add', '--' }
    vim.list_extend(args, pathspecs)

    local out = git.run(args, root_opts())

    return out.exit_code == 0
end

---@param entry GitStatusEntry
---@return boolean
function git.unstage(entry)
    return git.unstage_entries({ entry })
end

---@param entries GitStatusEntry[]
---@return boolean
function git.unstage_entries(entries)
    ensure_git()

    local staged_entries = vim.tbl_filter(function(entry)
        return entry.staged ~= ' ' and entry.staged ~= '?'
    end, entries)
    local pathspecs = entries_pathspecs(staged_entries)

    if #pathspecs == 0 then
        return true
    end

    local args = { 'restore', '--staged', '--' }
    vim.list_extend(args, pathspecs)

    local out = git.run(args, root_opts())

    return out.exit_code == 0
end

---@param file string
---@return boolean
---@return string
function git.commit_file(file)
    ensure_git()

    local out =
        git.run({ 'commit', '--cleanup=strip', '-F', file }, root_opts())

    return out.exit_code == 0, return_result(out)
end

---@return string[]
function git.commit_template()
    ensure_git()

    local out = git.run({ 'commit', '--dry-run', '--status' }, root_opts())
    local lines = {
        '',
        '# Please enter the commit message for your changes. Lines starting',
        '# with `#` will be ignored, and an empty message aborts the commit.',
        '#',
    }

    if out.output ~= '' then
        for _, line in ipairs(vim.split(out.output, '\n', { plain = true })) do
            if line ~= '' then
                table.insert(lines, '# ' .. line)
            end
        end
    end

    return lines
end

---@param diff string?
---@return string[]
local function parse_diff(diff)
    if diff == '' or diff == nil then
        return {}
    end

    return vim.split(diff, '\n', { plain = true })
end

---@param entry GitStatusEntry
---@return string[]
function git.diff(entry)
    ensure_git()

    local args
    local opts = root_opts()

    if entry.unstaged == '?' then
        args = { 'diff', '--no-index', '--', '/dev/null', entry.path }
    elseif entry.staged ~= ' ' or entry.unstaged ~= ' ' then
        args = { 'diff', 'HEAD', '--', entry.path }
    else
        return {}
    end

    local out = git.run(args, opts)

    return parse_diff(out.output)
end

return git
