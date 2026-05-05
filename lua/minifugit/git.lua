---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitCommit
---@field hash string
---@field short_hash string
---@field message string

---@class GitPushDestination
---@field remote string
---@field ref string

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field unpushed_commits GitCommit[]
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
            unpushed_commits = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    local root = git.root()

    if root == '' then
        return {
            branch = '',
            entries = {},
            unpushed_commits = {},
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
            unpushed_commits = {},
            root = root,
            error = return_result(status_out),
        }
    end

    return {
        branch = branch,
        entries = parse_status(status_out.output),
        unpushed_commits = git.unpushed_commits(root),
        root = root,
    }
end

local COMMIT_FIELD_SEPARATOR = '\31'
local NO_UPSTREAM_MESSAGE = 'No upstream configured. Run git push -u origin <branch>'

---@param output string
---@return GitCommit[]
local function parse_commits(output)
    local commits = {}

    for _, line in ipairs(vim.split(output, '\n', { plain = true })) do
        if line ~= '' then
            local sep = line:find(COMMIT_FIELD_SEPARATOR, 1, true)

            if sep ~= nil then
                local hash = line:sub(1, sep - 1)
                local short_hash = hash:sub(1, 7)
                local message = line:sub(sep + 1)

                if message ~= '' then
                    table.insert(commits, {
                        hash = hash,
                        short_hash = short_hash,
                        message = message,
                    })
                end
            end
        end
    end

    return commits
end

---@param root string
---@return string?
---@return string?
function git.upstream(root)
    local out = git.run(
        { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil, NO_UPSTREAM_MESSAGE
    end

    local upstream = return_result(out)

    if upstream == '' then
        return nil, NO_UPSTREAM_MESSAGE
    end

    return upstream, nil
end

---@param root string
---@return GitPushDestination?
---@return string?
function git.push_destination(root)
    local branch_out = git.run(
        { 'symbolic-ref', '--quiet', '--short', 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if branch_out.exit_code ~= 0 then
        return nil, 'Cannot push from detached HEAD'
    end

    local branch = return_result(branch_out)
    local upstream_out = git.run(
        {
            'for-each-ref',
            '--format=%(upstream:remotename)%00%(upstream:remoteref)',
            'refs/heads/' .. branch,
        },
        { cwd = root, ignore_error = true }
    )

    if upstream_out.exit_code ~= 0 or upstream_out.output == '' then
        return nil, NO_UPSTREAM_MESSAGE
    end

    local remote, ref_start = read_nul_field(upstream_out.output, 1)

    if remote == nil or remote == '' or ref_start == nil then
        return nil, NO_UPSTREAM_MESSAGE
    end

    local ref = upstream_out.output:sub(ref_start):gsub('[\r\n]+$', '')

    if ref == '' then
        return nil, NO_UPSTREAM_MESSAGE
    end

    return {
        remote = remote,
        ref = ref,
    }, nil
end

---@param root string
---@return GitCommit[]
function git.unpushed_commits(root)
    local upstream = git.upstream(root)

    if upstream == nil then
        return {}
    end

    local out = git.run(
        { 'log', '--format=%H%x1f%s', '-20', upstream .. '..HEAD' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 or out.output == '' then
        return {}
    end

    return parse_commits(out.output)
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

---@param entry GitStatusEntry
---@return string
local function entry_worktree_path(entry)
    return entry.path
end

---@param entries GitStatusEntry[]
---@return string[]
local function entries_worktree_paths(entries)
    local pathspecs = {}
    local seen = {}

    for _, entry in ipairs(entries) do
        local path = entry_worktree_path(entry)

        if not seen[path] then
            table.insert(pathspecs, path)
            seen[path] = true
        end
    end

    return pathspecs
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
---@return string?
function git.stage(entry)
    return git.stage_entries({ entry })
end

---@param entries GitStatusEntry[]
---@return boolean
---@return string?
function git.stage_entries(entries)
    ensure_git()

    local pathspecs = entries_pathspecs(entries)

    if #pathspecs == 0 then
        return true
    end

    local args = { 'add', '--' }
    vim.list_extend(args, pathspecs)

    local out = git.run(args, root_opts())

    return out.exit_code == 0, return_result(out)
end

---@param entry GitStatusEntry
---@return boolean
---@return string?
function git.unstage(entry)
    return git.unstage_entries({ entry })
end

---@param entries GitStatusEntry[]
---@return boolean
---@return string?
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

    return out.exit_code == 0, return_result(out)
end

---@param entries GitStatusEntry[]
---@return boolean
---@return string?
function git.discard_unstaged_entries(entries)
    ensure_git()

    local pathspecs = entries_worktree_paths(entries)

    if #pathspecs == 0 then
        return true
    end

    local args = { 'restore', '--worktree', '--' }
    vim.list_extend(args, pathspecs)

    local out = git.run(args, root_opts())

    return out.exit_code == 0, return_result(out)
end

---@param entries GitStatusEntry[]
---@return boolean
---@return string?
function git.discard_untracked_entries(entries)
    ensure_git()

    local pathspecs = entries_pathspecs(entries)

    if #pathspecs == 0 then
        return true
    end

    local args = { 'clean', '-fd', '--' }
    vim.list_extend(args, pathspecs)

    local out = git.run(args, root_opts())

    return out.exit_code == 0, return_result(out)
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
---@param section string?
---@return string[]
---@return string?
function git.diff(entry, section)
    ensure_git()

    local args
    local opts = root_opts()
    local pathspecs = entry_pathspecs(entry)
    local full_path = opts.cwd ~= nil and vim.fs.joinpath(opts.cwd, entry.path)
        or entry.path
    local stat = vim.uv.fs_stat(full_path)

    if section == 'untracked' or entry.unstaged == '?' then
        if stat ~= nil and stat.type == 'directory' then
            return {}, 'Diff preview is not available for untracked directories'
        end

        args = { 'diff', '--no-index', '--', '/dev/null', entry.path }
    elseif section == 'staged' then
        args = { 'diff', '--cached', '--' }
        vim.list_extend(args, pathspecs)
    elseif section == 'unstaged' or section == 'conflicts' then
        args = { 'diff', '--' }
        vim.list_extend(args, pathspecs)
    elseif entry.staged ~= ' ' or entry.unstaged ~= ' ' then
        args = { 'diff', 'HEAD', '--' }
        vim.list_extend(args, pathspecs)
    else
        return {}
    end

    opts.ignore_error = true

    local out = git.run(args, opts)

    if out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '') then
        return {}, return_result(out)
    end

    return parse_diff(out.output)
end

---@return boolean
---@return string
function git.push()
    ensure_git()

    local root = git.root()

    if root == '' then
        return false, 'Not inside a git repository'
    end

    local destination, destination_error = git.push_destination(root)

    if destination == nil then
        return false, destination_error or 'No upstream configured'
    end

    if #git.unpushed_commits(root) == 0 then
        return false, 'No unpushed commits to push'
    end

    local out = git.run(
        { 'push', destination.remote, 'HEAD:' .. destination.ref },
        { cwd = root, ignore_error = true }
    )

    return out.exit_code == 0, return_result(out)
end

return git
