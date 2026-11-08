---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---A blob side of a split preview: a tree-ish (`''` for the index) and a path.
---@class GitBlobRef
---@field rev string
---@field path string

---@class GitDiffSide
---@field title string
---@field lines string[]

---@class GitSplitDiff
---@field left GitDiffSide
---@field right GitDiffSide
---@field filetype string

---@class GitCommit
---@field hash string
---@field short_hash string
---@field message string

---@class GitPushDestination
---@field remote string
---@field ref string

---@class GitFileChangeCounts
---@field added integer
---@field modified integer
---@field deleted integer

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

---Absolute path of the git executable, resolved once. Spawning by bare name
---makes every call search PATH, which is slow when PATH holds slow mounts.
---@type string?
local git_path

---@return string?
local function git_executable()
    if git_path == nil then
        local path = vim.fn.exepath('git')
        git_path = path ~= '' and path or nil
    end

    return git_path
end

---@return boolean
local function ensure_git()
    if git_executable() == nil then
        log.error('`git` is not executable')
        vim.print('[minifugit] `git` is not executable')
        return false
    end

    return true
end

---@alias GitResult {
---output: string,
---exit_code: number,
---stderr: string,
---}

---@alias GitAsyncCallback fun(ok: boolean, output: string)

local return_result

---@param args string[]
---@return string[]
local function git_command(args)
    local cmd = { git_executable() }
    vim.list_extend(cmd, args)
    return cmd
end

---@param result vim.SystemCompleted
---@return GitResult
local function normalize_result(result)
    return {
        output = result.stdout or '',
        exit_code = result.code or 1,
        stderr = result.stderr or '',
    }
end

---@param cmd string[]
---@param res GitResult
---@param ignore_error boolean?
local function log_result(cmd, res, ignore_error)
    if res.exit_code ~= 0 and not ignore_error then
        log.error(
            string.format(
                'git command failed (%d): %s\n%s',
                res.exit_code,
                table.concat(cmd, ' '),
                res.stderr
            )
        )
    end

    log.info(
        string.format(
            'output=%s, exit_code=%d, stderr=%s',
            res.output,
            res.exit_code,
            res.stderr
        )
    )
end

---@return string
local function null_device_path()
    if vim.fn.has('win32') == 1 then
        return 'NUL'
    end

    return '/dev/null'
end

---Absolute Git environment pinned per repository root. Root-scoped calls set
---it, so the editor's inherited `GIT_DIR` and `GIT_WORK_TREE` cannot redirect
---a pinned root: relative values would resolve against the pinned root.
---@type table<string, table<string, string>>
local pinned_env_by_root = {}

---Environment and text mode for a git child.
---@param git_env string? `'ignored'` hides the editor's `GIT_DIR` and
---  `GIT_WORK_TREE`; `'inherited'` keeps them; nil uses the environment
---  pinned for `cwd`.
---@param cwd string
---@param text boolean
---@return table
local function child_opts(git_env, cwd, text)
    if git_env == 'ignored' then
        -- `clear_env` removes the variables; a merged `env` could only replace
        -- them, and GIT_DIR set to another value still redirects the call.
        local env = vim.fn.environ()
        env.GIT_DIR = nil
        env.GIT_WORK_TREE = nil

        return { text = text, cwd = cwd, env = env, clear_env = true }
    end

    if git_env == 'inherited' then
        return { text = text, cwd = cwd }
    end

    return {
        text = text,
        cwd = cwd,
        env = pinned_env_by_root[vim.fs.normalize(cwd)],
    }
end

---Executes a git command and returns the result.
---Text mode defaults to true; disable it for NUL-separated path output.
---`git_env` overrides the child environment for repository discovery:
---`'ignored'` hides the editor's `GIT_DIR` and `GIT_WORK_TREE`, `'inherited'`
---keeps them and skips the pinned environment of `cwd`.
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? {cwd: string?, ignore_error: boolean?, text: boolean?, git_env: string?}
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

    local cmd = git_command(args)
    local cwd = opts.cwd or vim.fn.getcwd()

    local job =
        vim.system(cmd, child_opts(opts.git_env, cwd, opts.text ~= false))
    local res = normalize_result(job:wait())

    log_result(cmd, res, opts.ignore_error)

    return res
end

---Executes a git command asynchronously and returns the full result.
---The callback runs on the main loop; `text` selects text mode exactly like
---`git.run`, so NUL-separated output keeps its bytes.
---@param args string[]
---@param opts? { cwd: string?, ignore_error: boolean?, text: boolean?, git_env: string? }
---@param callback fun(res: GitResult)
local function run_async_result(args, opts, callback)
    opts = opts or {}

    if not ensure_git() then
        callback({
            output = '',
            exit_code = 127,
            stderr = '`git` is not executable',
        })
        return
    end

    local cmd = git_command(args)
    local cwd = opts.cwd or vim.fn.getcwd()

    local function on_exit(result)
        vim.schedule(function()
            local res = normalize_result(result)

            log_result(cmd, res, opts.ignore_error)

            callback(res)
        end)
    end

    -- A spawn failure (for example a cwd that vanished while the read was
    -- queued) must surface as a read error instead of a crashed callback.
    local ok, err = pcall(function()
        vim.system(
            cmd,
            child_opts(opts.git_env, cwd, opts.text ~= false),
            on_exit
        )
    end)

    if not ok then
        callback({ output = '', exit_code = 127, stderr = tostring(err) })
    end
end

---Executes a git command asynchronously.
---@param args string[] List of git arguments (e.g., {"push"})
---@param opts? { cwd: string?, ignore_error: boolean?, text: boolean?, git_env: string? }
---@param callback GitAsyncCallback
function git.run_async(args, opts, callback)
    run_async_result(args, opts, function(res)
        callback(res.exit_code == 0, return_result(res))
    end)
end

---@param res GitResult
---@return string
function return_result(res)
    local value = res.exit_code == 0 and res.output or res.stderr

    -- Preserve meaningful leading spaces in outputs like `git status --short`.
    local v, _ = value:gsub('[\r\n]+$', '')
    return v
end

---Repository roots by working directory, discovery policy, and environment.
---Only found roots are cached; missing or nested `.git` entries trigger lookup.
---@type table<string, string>
local roots_by_context = {}

---Read a `rev-parse` value byte for byte: text mode and `return_result()`
---would rewrite or trim carriage returns that belong to a path.
---@param arg string
---@param cwd string
---@param ignore_env boolean Ignore the editor's Git discovery variables.
---@return string? value nil when `git rev-parse` fails
local function rev_parse_value(arg, cwd, ignore_env)
    local out = git.run({ 'rev-parse', arg }, {
        cwd = cwd,
        ignore_error = true,
        text = false,
        git_env = ignore_env and 'ignored' or 'inherited',
    })

    if out.exit_code ~= 0 then
        return nil
    end

    return out.output:gsub('\n$', '')
end

---Pin the absolute Git environment of `root` for its later calls.
---@param root string
---@param cwd string Directory the discovery ran in; relative values resolve
---  against it, as they did during discovery.
---@param ignore_env boolean
local function pin_env(root, cwd, ignore_env)
    local git_dir = rev_parse_value('--absolute-git-dir', cwd, ignore_env)

    if git_dir == nil then
        return
    end

    pinned_env_by_root[vim.fs.normalize(root)] = {
        GIT_DIR = git_dir,
        GIT_WORK_TREE = root,
    }
end

---Repository root of `cwd`, or of the current cwd when omitted.
---An explicit `cwd` names the repository, so the editor's `GIT_DIR` and
---`GIT_WORK_TREE` are ignored; without `cwd` they discover it like Git does.
---@param cwd string? Discovery directory; defaults to the current cwd.
---@return string
function git.root(cwd)
    if not ensure_git() then
        return ''
    end

    local ignore_env = cwd ~= nil
    cwd = cwd or vim.fn.getcwd()
    local key = { ignore_env and 'explicit' or 'inherited', cwd }

    if not ignore_env then
        local git_dir = vim.env.GIT_DIR
        local git_work_tree = vim.env.GIT_WORK_TREE
        table.insert(key, git_dir == nil and '0' or '1' .. git_dir)
        table.insert(key, git_work_tree == nil and '0' or '1' .. git_work_tree)
    end

    key = table.concat(key, '\0')
    local cached = roots_by_context[key]

    if cached ~= nil and vim.uv.fs_stat(cached .. '/.git') ~= nil then
        local dir = vim.fs.normalize(cwd)
        local cached_dir = vim.fs.normalize(cached)
        local prefix = cached_dir:sub(-1) == '/' and cached_dir
            or cached_dir .. '/'

        if dir == cached_dir or vim.startswith(dir, prefix) then
            while dir ~= cached_dir do
                if vim.uv.fs_stat(dir .. '/.git') ~= nil then
                    break
                end

                local parent = vim.fs.dirname(dir)
                if parent == nil or parent == dir then
                    break
                end
                dir = parent
            end

            if dir == cached_dir then
                return cached
            end
        end
    end

    roots_by_context[key] = nil

    local root = rev_parse_value('--show-toplevel', cwd, ignore_env) or ''
    if root == '' then
        return ''
    end

    roots_by_context[key] = root
    pin_env(root, cwd, ignore_env)

    return root
end

---@return GitStatusEntry[]
function git.status()
    ensure_git()

    local out = git.run({
        'status',
        '--porcelain=v1',
        '-z',
        '--untracked-files=all',
    }, { text = false })

    if out.exit_code ~= 0 then
        return {}
    end

    return parse_status(out.output)
end

local COMMIT_FIELD_SEPARATOR = '\31'

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

---@param upstream string?
---@return string[]
local function unpushed_commits_args(upstream)
    local range = upstream ~= nil and upstream .. '..HEAD' or 'HEAD'
    local args = { 'log', '--format=%H%x1f%s', '-20', range }

    if upstream == nil then
        vim.list_extend(args, { '--not', '--remotes' })
    end

    return args
end

---@return string[]
local function status_args()
    return { 'status', '--porcelain=v1', '-z', '--untracked-files=all' }
end

---@param root string
---@param branch string
---@param error string
---@return GitStatusSnapshot
local function failed_snapshot(root, branch, error)
    return {
        branch = branch,
        entries = {},
        unpushed_commits = {},
        root = root,
        error = error,
    }
end

---@param root string
---@param branch string
---@param entries GitStatusEntry[]
---@param unpushed_commits GitCommit[]
---@return GitStatusSnapshot
local function snapshot(root, branch, entries, unpushed_commits)
    return {
        branch = branch,
        entries = entries,
        unpushed_commits = unpushed_commits,
        root = root,
    }
end

---@param head_out GitResult
---@return string
local function detached_branch(head_out)
    return head_out.exit_code == 0 and return_result(head_out) or '(unknown)'
end

---@param root string
---@return string
local function branch_name(root)
    local branch_out = git.run(
        { 'branch', '--show-current' },
        { cwd = root, ignore_error = true }
    )
    local branch = return_result(branch_out)

    if branch ~= '' then
        return branch
    end

    return detached_branch(
        git.run(
            { 'rev-parse', '--short', 'HEAD' },
            { cwd = root, ignore_error = true }
        )
    )
end

---@param root string? Repository root; defaults to the current cwd's root.
---@return GitStatusSnapshot
function git.status_snapshot(root)
    if not ensure_git() then
        return failed_snapshot('', '', '`git` is not executable')
    end

    root = root or git.root()

    if root == '' then
        return failed_snapshot('', '', 'Not inside a git repository')
    end

    local branch = branch_name(root)
    local status_out = git.run(status_args(), { cwd = root, text = false })

    if status_out.exit_code ~= 0 then
        return failed_snapshot(root, branch, return_result(status_out))
    end

    return snapshot(
        root,
        branch,
        parse_status(status_out.output),
        git.unpushed_commits(root)
    )
end

---@param root string
---@param callback fun(branch: string)
local function branch_name_async(root, callback)
    run_async_result(
        { 'branch', '--show-current' },
        { cwd = root, ignore_error = true },
        function(branch_out)
            local branch = return_result(branch_out)

            if branch ~= '' then
                callback(branch)
                return
            end

            run_async_result(
                { 'rev-parse', '--short', 'HEAD' },
                { cwd = root, ignore_error = true },
                function(head_out)
                    callback(detached_branch(head_out))
                end
            )
        end
    )
end

---@param root string
---@param callback fun(commits: GitCommit[])
local function unpushed_commits_async(root, callback)
    run_async_result(
        { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' },
        { cwd = root, ignore_error = true },
        function(upstream_out)
            local upstream = upstream_out.exit_code == 0
                    and return_result(upstream_out)
                or ''

            if upstream == '' then
                upstream = nil
            end

            run_async_result(
                unpushed_commits_args(upstream),
                { cwd = root, ignore_error = true },
                function(out)
                    if out.exit_code ~= 0 or out.output == '' then
                        callback({})
                        return
                    end

                    callback(parse_commits(out.output))
                end
            )
        end
    )
end

---Collect a status snapshot without blocking the main loop.
---@param root string? Repository root; defaults to the current cwd's root.
---@param callback fun(snapshot: GitStatusSnapshot)
function git.status_snapshot_async(root, callback)
    if not ensure_git() then
        callback(failed_snapshot('', '', '`git` is not executable'))
        return
    end

    root = root or git.root()

    if root == '' then
        callback(failed_snapshot('', '', 'Not inside a git repository'))
        return
    end

    branch_name_async(root, function(branch)
        run_async_result(
            status_args(),
            { cwd = root, text = false },
            function(out)
                if out.exit_code ~= 0 then
                    callback(failed_snapshot(root, branch, return_result(out)))
                    return
                end

                local entries = parse_status(out.output)

                unpushed_commits_async(root, function(commits)
                    callback(snapshot(root, branch, entries, commits))
                end)
            end
        )
    end)
end

local NO_UPSTREAM_MESSAGE = function(root)
    local branch_out = git.run({ 'branch', '--show-current' }, { cwd = root })
    return 'No upstream configured. Run git push -u origin '
        .. return_result(branch_out)
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
        return nil, NO_UPSTREAM_MESSAGE(root)
    end

    local upstream = return_result(out)

    if upstream == '' then
        return nil, NO_UPSTREAM_MESSAGE(root)
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
    local upstream_out = git.run({
        'for-each-ref',
        '--format=%(upstream:remotename)%00%(upstream:remoteref)',
        'refs/heads/' .. branch,
    }, { cwd = root, ignore_error = true })

    if upstream_out.exit_code ~= 0 or upstream_out.output == '' then
        return nil, NO_UPSTREAM_MESSAGE(root)
    end

    local remote, ref_start = read_nul_field(upstream_out.output, 1)

    if remote == nil or remote == '' or ref_start == nil then
        return nil, NO_UPSTREAM_MESSAGE(root)
    end

    local ref = upstream_out.output:sub(ref_start):gsub('[\r\n]+$', '')

    if ref == '' then
        return nil, NO_UPSTREAM_MESSAGE(root)
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
    local out = git.run(
        unpushed_commits_args(upstream),
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 or out.output == '' then
        return {}
    end

    return parse_commits(out.output)
end

---@param root string?
---@return table
local function root_opts(root)
    root = root or git.root()
    local opts = { ignore_error = true }

    if root ~= '' then
        opts.cwd = root
    end

    return opts
end

---Resolve and pin a caller-supplied revision to a commit, never a Git option.
---@param base string
---@param root string?
---@return string? hash
---@return string? error
function git.resolve_commit(base, root)
    if base == '' or base:sub(1, 1) == '-' then
        return nil, 'Invalid base revision: ' .. base
    end

    local out = git.run(
        { 'rev-parse', '--verify', '--quiet', base .. '^{commit}' },
        root_opts(root)
    )
    if out.exit_code ~= 0 then
        return nil, 'Invalid base revision: ' .. base
    end

    return return_result(out), nil
end

---`git rm --cached` reports the path as deleted from the pinned commit while
---the still-present worktree file is untracked. One modified entry describes
---that single change: the base blob on the left, the worktree file on the right.
---@param entries GitStatusEntry[]
---@return GitStatusEntry[]
local function merge_cached_deletions(entries)
    local deleted = {}
    local untracked = {}

    for _, entry in ipairs(entries) do
        if entry.unstaged == 'D' then
            deleted[entry.path] = true
        elseif entry.unstaged == '?' then
            untracked[entry.path] = true
        end
    end

    local merged = {}

    for _, entry in ipairs(entries) do
        if entry.unstaged == 'D' and untracked[entry.path] then
            table.insert(merged, {
                staged = entry.staged,
                unstaged = 'M',
                path = entry.path,
            })
        elseif not (entry.unstaged == '?' and deleted[entry.path]) then
            table.insert(merged, entry)
        end
    end

    return merged
end

---Translate `--name-status` and untracked records to porcelain records for
---the shared parser.
---@param diff_output string NUL-separated `diff --name-status` output.
---@param untracked_output string NUL-separated `ls-files --others` output.
---@return GitStatusEntry[]
local function parse_base_entries(diff_output, untracked_output)
    local records = {}
    local fields = vim.split(diff_output, '\0', { plain = true })
    local index = 1
    while index < #fields do
        local marker = fields[index]:sub(1, 1)
        local path = fields[index + 1]
        index = index + 2
        if marker == 'R' then
            table.insert(
                records,
                ' ' .. marker .. ' ' .. fields[index] .. '\0' .. path .. '\0'
            )
            index = index + 1
        else
            table.insert(records, ' ' .. marker .. ' ' .. path .. '\0')
        end
    end

    for _, path in ipairs(vim.split(untracked_output, '\0', { plain = true })) do
        if path ~= '' then
            table.insert(records, '?? ' .. path .. '\0')
        end
    end

    return merge_cached_deletions(parse_status(table.concat(records)))
end

---Tracked changes from the pinned commit to the worktree, plus untracked files.
---@param base string Pinned commit hash.
---@param root string?
---@return GitStatusEntry[]
---@return string? error
function git.base_entries(base, root)
    local opts = root_opts(root)
    opts.text = false
    local out =
        git.run({ 'diff', '--name-status', '-z', '-M', base, '--' }, opts)
    if out.exit_code ~= 0 then
        return {}, return_result(out)
    end

    local untracked =
        git.run({ 'ls-files', '--others', '--exclude-standard', '-z' }, opts)
    if untracked.exit_code ~= 0 then
        return {}, return_result(untracked)
    end

    return parse_base_entries(out.output, untracked.output), nil
end

---Collect base-mode entries without blocking the main loop.
---@param base string Pinned commit hash.
---@param root string?
---@param callback fun(entries: GitStatusEntry[], error: string?)
function git.base_entries_async(base, root, callback)
    local opts = root_opts(root)
    opts.text = false

    run_async_result(
        { 'diff', '--name-status', '-z', '-M', base, '--' },
        opts,
        function(diff_out)
            if diff_out.exit_code ~= 0 then
                callback({}, return_result(diff_out))
                return
            end

            run_async_result(
                { 'ls-files', '--others', '--exclude-standard', '-z' },
                opts,
                function(untracked_out)
                    if untracked_out.exit_code ~= 0 then
                        callback({}, return_result(untracked_out))
                        return
                    end

                    callback(
                        parse_base_entries(
                            diff_out.output,
                            untracked_out.output
                        ),
                        nil
                    )
                end
            )
        end
    )
end

---@param entry GitStatusEntry
---@return string[]
local function entry_pathspecs(entry)
    if entry.orig_path == nil then
        return { ':(literal)' .. entry.path }
    end

    return { ':(literal)' .. entry.orig_path, ':(literal)' .. entry.path }
end

---@param entries GitStatusEntry[]
---@return string[]
local function entries_worktree_paths(entries)
    local pathspecs = {}
    local seen = {}

    for _, entry in ipairs(entries) do
        local path = ':(literal)' .. entry.path

        if not seen[path] then
            table.insert(pathspecs, path)
            seen[path] = true
        end
    end

    return pathspecs
end

---`git add` rejects the whole call when a pathspec matches nothing, and a
---staged rename leaves the original path in neither the index nor the
---worktree. Stage the new path only: the rename is already in the index.
---@param entry GitStatusEntry
---@return string[]
local function entry_stage_pathspecs(entry)
    if entry.staged == 'R' then
        return { ':(literal)' .. entry.path }
    end

    return entry_pathspecs(entry)
end

---@param entries GitStatusEntry[]
---@param pathspecs_for? fun(entry: GitStatusEntry): string[]
---@return string[]
local function entries_pathspecs(entries, pathspecs_for)
    pathspecs_for = pathspecs_for or entry_pathspecs
    local pathspecs = {}
    local seen = {}

    for _, entry in ipairs(entries) do
        for _, path in ipairs(pathspecs_for(entry)) do
            if not seen[path] then
                table.insert(pathspecs, path)
                seen[path] = true
            end
        end
    end

    return pathspecs
end

local PATHSPEC_BATCH_MAX_ARGS = 128
local PATHSPEC_BATCH_MAX_CHARS = 24 * 1024

---@param base_args string[]
---@param pathspecs string[]
---@param opts? table
---@return GitResult
local function run_pathspec_batches(base_args, pathspecs, opts)
    local batch = {}
    local batch_chars = 0

    ---@return GitResult?
    local function flush()
        if #batch == 0 then
            return nil
        end

        local args = vim.deepcopy(base_args)
        vim.list_extend(args, batch)

        local out = git.run(args, opts)
        batch = {}
        batch_chars = 0

        if out.exit_code ~= 0 then
            return out
        end
    end

    for _, path in ipairs(pathspecs) do
        if
            #batch > 0
            and (
                #batch >= PATHSPEC_BATCH_MAX_ARGS
                or batch_chars + #path > PATHSPEC_BATCH_MAX_CHARS
            )
        then
            local out = flush()

            if out ~= nil then
                return out
            end
        end

        table.insert(batch, path)
        batch_chars = batch_chars + #path + 1
    end

    return flush() or { output = '', exit_code = 0, stderr = '' }
end

---@param entry GitStatusEntry
---@param root string?
---@return boolean
---@return string?
function git.stage(entry, root)
    return git.stage_entries({ entry }, root)
end

---@param entries GitStatusEntry[]
---@param root string?
---@return boolean
---@return string?
function git.stage_entries(entries, root)
    ensure_git()

    local pathspecs = entries_pathspecs(entries, entry_stage_pathspecs)

    if #pathspecs == 0 then
        return true
    end

    local out =
        run_pathspec_batches({ 'add', '--' }, pathspecs, root_opts(root))

    return out.exit_code == 0, return_result(out)
end

---@param entry GitStatusEntry
---@param root string?
---@return boolean
---@return string?
function git.unstage(entry, root)
    return git.unstage_entries({ entry }, root)
end

---@param entries GitStatusEntry[]
---@param root string?
---@return boolean
---@return string?
function git.unstage_entries(entries, root)
    ensure_git()

    local staged_entries = vim.tbl_filter(function(entry)
        return entry.staged ~= ' ' and entry.staged ~= '?'
    end, entries)
    local pathspecs = entries_pathspecs(staged_entries)

    if #pathspecs == 0 then
        return true
    end

    local out = run_pathspec_batches(
        { 'restore', '--staged', '--' },
        pathspecs,
        root_opts(root)
    )

    return out.exit_code == 0, return_result(out)
end

---@param entries GitStatusEntry[]
---@param root string?
---@return boolean
---@return string?
function git.discard_unstaged_entries(entries, root)
    ensure_git()

    local pathspecs = entries_worktree_paths(entries)

    if #pathspecs == 0 then
        return true
    end

    local out = run_pathspec_batches(
        { 'restore', '--worktree', '--' },
        pathspecs,
        root_opts(root)
    )

    return out.exit_code == 0, return_result(out)
end

---@param entries GitStatusEntry[]
---@param root string?
---@return boolean
---@return string?
function git.discard_untracked_entries(entries, root)
    ensure_git()

    local pathspecs = entries_pathspecs(entries)

    if #pathspecs == 0 then
        return true
    end

    local out = run_pathspec_batches(
        { 'clean', '-fd', '--' },
        pathspecs,
        root_opts(root)
    )

    return out.exit_code == 0, return_result(out)
end

---@param patch string[]
---@param kind 'stage'|'unstage'|'discard'
---@param root string?
---@return boolean
---@return string?
function git.apply_hunk(patch, kind, root)
    ensure_git()

    if #patch == 0 then
        return false, 'No hunk patch to apply'
    end

    if kind ~= 'stage' and kind ~= 'unstage' and kind ~= 'discard' then
        return false, 'Unknown hunk action: ' .. kind
    end

    local path = vim.fn.tempname() .. '.patch'
    vim.fn.writefile(patch, path)

    local args = { 'apply' }

    if kind == 'stage' then
        table.insert(args, '--cached')
    elseif kind == 'unstage' then
        table.insert(args, '--cached')
        table.insert(args, '--reverse')
    elseif kind == 'discard' then
        table.insert(args, '--reverse')
    end

    table.insert(args, path)

    local out = git.run(args, root_opts(root))
    vim.fn.delete(path)

    return out.exit_code == 0, return_result(out)
end

---@param root string?
---@return boolean
---@return string?
function git.has_staged_changes(root)
    if not ensure_git() then
        return false, '`git` is not executable'
    end

    local out = git.run(
        { 'diff', '--cached', '--quiet', '--exit-code' },
        root_opts(root)
    )

    if out.exit_code == 1 then
        return true, nil
    end

    if out.exit_code == 0 then
        return false, nil
    end

    return false, return_result(out)
end

---@param file string
---@param root string?
---@return boolean
---@return string
function git.commit_file(file, root)
    ensure_git()

    local out =
        git.run({ 'commit', '--cleanup=strip', '-F', file }, root_opts(root))

    return out.exit_code == 0, return_result(out)
end

---@param root string?
---@return string[]
function git.commit_template(root)
    ensure_git()

    local out = git.run({ 'commit', '--dry-run', '--status' }, root_opts(root))
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

---@return GitFileChangeCounts
local function empty_change_counts()
    return { added = 0, modified = 0, deleted = 0 }
end

---@param counts GitFileChangeCounts
---@param removed integer
---@param added integer
local function add_diff_block_counts(counts, removed, added)
    local modified = math.min(removed, added)

    counts.modified = counts.modified + modified
    counts.deleted = counts.deleted + removed - modified
    counts.added = counts.added + added - modified
end

---@param diff string
---@return GitFileChangeCounts
local function parse_change_counts(diff)
    local counts = empty_change_counts()
    local removed = 0
    local added = 0

    local function flush_block()
        if removed > 0 or added > 0 then
            add_diff_block_counts(counts, removed, added)
            removed = 0
            added = 0
        end
    end

    for _, line in ipairs(parse_diff(diff)) do
        local prefix = line:sub(1, 1)

        if line:sub(1, 3) == '+++' or line:sub(1, 3) == '---' then
            flush_block()
        elseif prefix == '-' then
            removed = removed + 1
        elseif prefix == '+' then
            added = added + 1
        else
            flush_block()
        end
    end

    flush_block()

    return counts
end

---@param path string
---@param root string
---@return string?
local function normalize_path(path, root)
    if path == '' then
        return nil
    end

    local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
    local normalized_root = vim.fs.normalize(root)

    if absolute == normalized_root then
        return '.'
    end

    local relative = vim.fs.relpath(normalized_root, absolute)

    if
        relative ~= nil
        and relative ~= '..'
        and relative:sub(1, 3) ~= '../'
        and relative:sub(1, 3) ~= '..\\'
    then
        return relative
    end

    return path
end

---@param path string
---@return boolean
local function is_absolute_path(path)
    return path:sub(1, 1) == '/'
        or path:sub(1, 1) == '\\'
        or path:match('^%a:[/\\]') ~= nil
end

---@param path string
---@param root string
---@return uv.fs_stat.result?
local function fs_stat_path(path, root)
    local full_path = path

    if not is_absolute_path(path) then
        full_path = vim.fs.joinpath(root, path)
    end

    return vim.uv.fs_stat(vim.fs.normalize(full_path))
end

---The checked-out HEAD of a submodule working tree, or nil when it is not
---initialized. An empty directory would otherwise find the parent repository.
---@param path string
---@param root string?
---@return string? hash
local function submodule_head(path, root)
    if vim.uv.fs_lstat(vim.fs.joinpath(path, '.git')) == nil then
        return nil
    end

    -- The parent root pins its own GIT_DIR/GIT_WORK_TREE, so `-C` must
    -- discover the submodule repository instead of inheriting that pin.
    local opts = root_opts(root)
    opts.git_env = 'ignored'

    local out = git.run({ '-C', path, 'rev-parse', '--verify', 'HEAD' }, opts)

    if out.exit_code ~= 0 then
        return nil
    end

    local hash = vim.trim(out.output)

    return hash ~= '' and hash or nil
end

---The commit id of a submodule (gitlink) entry. It is a commit of the
---submodule repository, so `git show` cannot read it here, but the tree or
---index metadata that records it still resolves.
---@param ref GitBlobRef
---@param root string?
---@return string? hash
local function gitlink_commit(ref, root)
    local opts = root_opts(root)
    opts.text = false

    local out
    local pattern

    if ref.rev == '' then
        out = git.run(
            { 'ls-files', '--stage', '-z', '--', ':(literal)' .. ref.path },
            opts
        )
        pattern = '^(%d+) (%x+) %d+\t'
    else
        out = git.run(
            { 'ls-tree', '-z', ref.rev, '--', ':(literal)' .. ref.path },
            opts
        )
        pattern = '^(%d+) commit (%x+)\t'
    end

    if out.exit_code ~= 0 then
        return nil
    end

    local mode, hash = out.output:match(pattern)

    if mode ~= '160000' then
        return nil
    end

    return hash
end

---@param path string
---@param root string?
---@param gitlink boolean? The other side is a submodule (gitlink); nil asks
---  the index.
---@return string[]
---@return string?
local function read_worktree_lines(path, root, gitlink)
    root = root or git.root()

    local full_path = root ~= '' and vim.fs.joinpath(root, path) or path
    local stat = vim.uv.fs_lstat(full_path)

    if stat == nil then
        return {}, 'Cannot stat file: ' .. full_path
    end

    -- Git shows a symlink as its target path, not the contents it points to.
    if stat.type == 'link' then
        local target, readlink_err = vim.uv.fs_readlink(full_path)

        if target == nil then
            return {}, 'Cannot read file: ' .. tostring(readlink_err)
        end

        -- A target may contain newlines, but buffer lines cannot.
        return vim.split(target, '\n', { plain = true }), nil
    end

    if stat.type == 'directory' then
        if not gitlink then
            gitlink = gitlink_commit({ rev = '', path = path }, root) ~= nil
        end

        if gitlink then
            local hash = submodule_head(full_path, root)

            return { 'Subproject commit ' .. (hash or '(not checked out)') },
                nil
        end

        return {}, 'Diff preview is not available for directories'
    end

    local ok, lines = pcall(vim.fn.readfile, full_path)

    if not ok then
        return {}, 'Cannot read file: ' .. tostring(lines)
    end

    return lines, nil
end

---@param ref GitBlobRef
---@param root string?
---@return string[]
---@return string?
---@return boolean? gitlink Whether the ref is a submodule (gitlink) commit.
local function read_blob_lines(ref, root)
    local spec = (ref.rev ~= '' and ref.rev .. ':' or ':') .. ref.path
    local out = git.run({ 'show', spec }, root_opts(root))

    if out.exit_code ~= 0 then
        local hash = gitlink_commit(ref, root)

        if hash ~= nil then
            return { 'Subproject commit ' .. hash }, nil, true
        end

        return {}, return_result(out)
    end

    local lines = parse_diff(out.output)

    -- vim.split leaves a synthetic trailing "" on \n-terminated output, while
    -- vim.fn.readfile() strips the final newline naturally. Strip it here so
    -- both sides of a split diff use the same line-count convention and the
    -- diff engine can align trailing-newline changes correctly.
    if lines[#lines] == '' then
        table.remove(lines)
    end

    return lines, nil
end

---@param entry GitStatusEntry
---@param left_ref GitBlobRef
---@param left_title string
---@param root string?
---@param filetype string?
---@return GitSplitDiff?
---@return string?
local function blob_to_worktree_diff(
    entry,
    left_ref,
    left_title,
    root,
    filetype
)
    local left, right = {}, {}
    local err
    local left_gitlink

    if entry.unstaged ~= 'A' then
        left, err, left_gitlink = read_blob_lines(left_ref, root)
        if err ~= nil then
            return nil, err
        end
    end

    if entry.unstaged ~= 'D' then
        right, err = read_worktree_lines(entry.path, root, left_gitlink)
        if err ~= nil then
            return nil, err
        end
    end

    return {
        left = {
            title = entry.unstaged == 'A' and '/dev/null' or left_title,
            lines = left,
        },
        right = {
            title = entry.unstaged == 'D' and '/dev/null'
                or 'worktree:' .. entry.path,
            lines = right,
        },
        filetype = filetype
            or vim.filetype.match({ filename = entry.path })
            or '',
    },
        nil
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param root string?
---@return GitSplitDiff?
---@return string?
function git.split_diff(entry, section, root)
    ensure_git()

    if section == 'conflicts' then
        return nil, 'Split diff preview is not available for conflicts'
    end

    local old_path = entry.orig_path or entry.path
    local ft = vim.filetype.match({ filename = entry.path }) or ''

    if section == 'untracked' or entry.unstaged == '?' then
        local right, err = read_worktree_lines(entry.path, root)

        if err ~= nil then
            return nil, err
        end

        return {
            left = { title = '/dev/null', lines = {} },
            right = { title = 'worktree:' .. entry.path, lines = right },
            filetype = ft,
        },
            nil
    end

    if section == 'staged' then
        local left = {}
        local err

        if entry.staged ~= 'A' then
            left, err = read_blob_lines({ rev = 'HEAD', path = old_path }, root)

            if err ~= nil then
                return nil, err
            end
        end

        local right = {}

        if entry.staged ~= 'D' then
            right, err = read_blob_lines({ rev = '', path = entry.path }, root)

            if err ~= nil then
                return nil, err
            end
        end

        return {
            left = {
                title = entry.staged == 'A' and '/dev/null'
                    or 'HEAD:' .. old_path,
                lines = left,
            },
            right = {
                title = entry.staged == 'D' and '/dev/null'
                    or 'index:' .. entry.path,
                lines = right,
            },
            filetype = ft,
        },
            nil
    end

    if section == 'unstaged' then
        return blob_to_worktree_diff(
            entry,
            { rev = '', path = entry.path },
            'index:' .. entry.path,
            root,
            ft
        )
    end

    return nil, 'Split diff preview requires a status section'
end

---Split preview using the base blob on the left and worktree on the right.
---@param entry GitStatusEntry
---@param base string Pinned commit hash.
---@param root string?
---@return GitSplitDiff?
---@return string? error
function git.base_split_diff(entry, base, root)
    if entry.unstaged == '?' then
        return git.split_diff(entry, 'untracked', root)
    end

    local path = entry.orig_path or entry.path
    local left_spec = base .. ':' .. path
    local left_ref = { rev = base, path = path }

    return blob_to_worktree_diff(entry, left_ref, left_spec, root)
end

---@param commit GitCommit
---@param root string?
---@return string[]
---@return string?
function git.show_commit(commit, root)
    ensure_git()

    local out =
        git.run({ 'show', '--stat', '--patch', commit.hash }, root_opts(root))

    if out.exit_code ~= 0 then
        return {}, return_result(out)
    end

    return parse_diff(out.output), nil
end

---Collect a commit diff without blocking the main loop.
---@param commit GitCommit
---@param root string?
---@param callback fun(lines: string[], error: string?)
function git.show_commit_async(commit, root, callback)
    run_async_result(
        { 'show', '--stat', '--patch', commit.hash },
        root_opts(root),
        function(out)
            if out.exit_code ~= 0 then
                callback({}, return_result(out))
                return
            end

            callback(parse_diff(out.output), nil)
        end
    )
end

---@param path string?
---@return GitFileChangeCounts
---@return string?
function git.file_change_counts(path)
    if not ensure_git() then
        return empty_change_counts(), '`git` is not executable'
    end

    path = path or vim.api.nvim_buf_get_name(0)

    local root = git.root()

    if root == '' then
        return empty_change_counts(), 'Not inside a git repository'
    end

    local relative_path = normalize_path(path, root)

    if relative_path == nil then
        return empty_change_counts(), 'No file path provided'
    end

    local stat = fs_stat_path(relative_path, root)

    if stat ~= nil and stat.type == 'directory' then
        return empty_change_counts(),
            'File change counts are not available for directories'
    end

    local status_out = git.run({
        'status',
        '--porcelain=v1',
        '-z',
        '--untracked-files=all',
        '--',
        ':(literal)' .. relative_path,
    }, { cwd = root, ignore_error = true, text = false })

    if status_out.exit_code ~= 0 then
        return empty_change_counts(), return_result(status_out)
    end

    local status_entries = parse_status(status_out.output)

    if #status_entries > 1 then
        return empty_change_counts(), 'Expected a file path, got multiple files'
    end

    if #status_entries == 1 and status_entries[1].unstaged == '?' then
        local lines, err = read_worktree_lines(relative_path, root)

        if err ~= nil then
            return empty_change_counts(), err
        end

        return { added = #lines, modified = 0, deleted = 0 }, nil
    end

    local out = git.run({
        'diff',
        '--no-ext-diff',
        '--unified=0',
        '--',
        ':(literal)' .. relative_path,
    }, { cwd = root, ignore_error = true })

    if out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '') then
        return empty_change_counts(), return_result(out)
    end

    return parse_change_counts(out.output), nil
end

---@return GitFileChangeCounts
---@return string?
function git.current_file_change_counts()
    return git.file_change_counts(vim.api.nvim_buf_get_name(0))
end

---@param entry GitStatusEntry
---@param section string?
---@return boolean
local function is_worktree_new_file(entry, section)
    if section == 'untracked' or entry.unstaged == '?' then
        return true
    end

    return entry.unstaged == 'A'
        and (section == 'unstaged' or entry.staged == ' ')
end

---@param entry GitStatusEntry
---@param section string?
---@param root string?
---@return string[]? args nil when the entry has no diff
---@return string? error
local function diff_args(entry, section, root)
    local opts = root_opts(root)
    local pathspecs = entry_pathspecs(entry)
    local full_path = opts.cwd ~= nil and vim.fs.joinpath(opts.cwd, entry.path)
        or entry.path
    local stat = vim.uv.fs_stat(full_path)

    if is_worktree_new_file(entry, section) then
        if stat ~= nil and stat.type == 'directory' then
            return nil,
                'Diff preview is not available for untracked directories'
        end

        return { 'diff', '--no-index', '--', null_device_path(), entry.path }
    end

    if section == 'staged' then
        local args = { 'diff', '--cached', '--' }
        vim.list_extend(args, pathspecs)
        return args
    end

    if section == 'unstaged' or section == 'conflicts' then
        local args = { 'diff', '--' }
        vim.list_extend(args, pathspecs)
        return args
    end

    if entry.staged ~= ' ' or entry.unstaged ~= ' ' then
        local args = { 'diff', 'HEAD', '--' }
        vim.list_extend(args, pathspecs)
        return args
    end

    return nil
end

---`git diff --no-index` exits 1 when the files differ, so only higher exit
---codes (or a failed call without output) are errors.
---@param out GitResult
---@return boolean
local function diff_failed(out)
    return out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '')
end

---@param entry GitStatusEntry
---@param section string?
---@param root string?
---@return string[]
---@return string?
function git.diff(entry, section, root)
    ensure_git()

    local args, err = diff_args(entry, section, root)

    if err ~= nil then
        return {}, err
    end

    if args == nil then
        return {}
    end

    local out = git.run(args, root_opts(root))

    if diff_failed(out) then
        return {}, return_result(out)
    end

    return parse_diff(out.output)
end

---Collect an entry diff without blocking the main loop.
---@param entry GitStatusEntry
---@param section string?
---@param root string?
---@param callback fun(lines: string[], error: string?)
function git.diff_async(entry, section, root, callback)
    local args, err = diff_args(entry, section, root)

    if err ~= nil then
        callback({}, err)
        return
    end

    if args == nil then
        callback({})
        return
    end

    run_async_result(args, root_opts(root), function(out)
        if diff_failed(out) then
            callback({}, return_result(out))
            return
        end

        callback(parse_diff(out.output), nil)
    end)
end

---A path deleted from the index but still present in the worktree is
---untracked again, so `git diff <base>` reports only its deletion.
---@param path string
---@param root string?
---@return boolean
local function index_tracks(path, root)
    local opts = root_opts(root)
    opts.text = false

    local out = git.run(
        { 'ls-files', '--error-unmatch', '-z', '--', ':(literal)' .. path },
        opts
    )

    return out.exit_code == 0
end

---@param path string
---@param root string
---@param callback fun(tracked: boolean)
local function index_tracks_async(path, root, callback)
    local opts = root_opts(root)
    opts.text = false

    run_async_result(
        { 'ls-files', '--error-unmatch', '-z', '--', ':(literal)' .. path },
        opts,
        function(out)
            callback(out.exit_code == 0)
        end
    )
end

---@param entry GitStatusEntry
---@param base string Pinned commit hash.
---@param tracked boolean Whether the index still tracks the entry path.
---@return string[]
local function base_diff_args(entry, base, tracked)
    if entry.unstaged == 'M' and not tracked then
        -- The worktree file is untracked after a cached deletion, so
        -- `git diff <base>` only reports a deletion. Compare the base blob
        -- with the worktree file directly: Git reads its bytes and mode.
        return {
            'diff',
            '--no-ext-diff',
            base .. ':' .. (entry.orig_path or entry.path),
            '--',
            ':(literal)' .. entry.path,
        }
    end

    local args = { 'diff', '--no-ext-diff', '-M', base, '--' }
    vim.list_extend(args, entry_pathspecs(entry))

    return args
end

---@param entry GitStatusEntry
---@return boolean
local function base_diff_needs_index(entry)
    return entry.unstaged == 'M'
end

---Unified preview from the pinned commit to the worktree.
---@param entry GitStatusEntry
---@param base string Pinned commit hash.
---@param root string?
---@return string[]
---@return string? error
function git.base_diff(entry, base, root)
    if entry.unstaged == '?' then
        return git.diff(entry, 'untracked', root)
    end

    root = root or git.root()

    local tracked = not base_diff_needs_index(entry)
        or index_tracks(entry.path, root)
    local out = git.run(base_diff_args(entry, base, tracked), root_opts(root))

    if out.exit_code ~= 0 then
        return {}, return_result(out)
    end

    return parse_diff(out.output), nil
end

---Collect a base-mode diff without blocking the main loop.
---@param entry GitStatusEntry
---@param base string Pinned commit hash.
---@param root string?
---@param callback fun(lines: string[], error: string?)
function git.base_diff_async(entry, base, root, callback)
    if entry.unstaged == '?' then
        git.diff_async(entry, 'untracked', root, callback)
        return
    end

    root = root or git.root()
    local opts = root_opts(root)

    local function run(tracked)
        run_async_result(
            base_diff_args(entry, base, tracked),
            opts,
            function(out)
                if out.exit_code ~= 0 then
                    callback({}, return_result(out))
                    return
                end

                callback(parse_diff(out.output), nil)
            end
        )
    end

    if not base_diff_needs_index(entry) then
        run(true)
        return
    end

    index_tracks_async(entry.path, root, run)
end

---@class GitPushRequest
---@field args string[]
---@field opts { cwd: string, ignore_error: boolean }

---Resolve everything a push needs before touching a remote.
---@param root string?
---@return GitPushRequest?
---@return string?
local function push_request(root)
    root = root or git.root()

    if root == '' then
        return nil, 'Not inside a git repository'
    end

    local destination, destination_error = git.push_destination(root)

    if destination == nil then
        return nil, destination_error or 'No upstream configured'
    end

    if #git.unpushed_commits(root) == 0 then
        return nil, 'No unpushed commits to push'
    end

    return {
        args = { 'push', destination.remote, 'HEAD:' .. destination.ref },
        opts = { cwd = root, ignore_error = true },
    }
end

---@param root string?
---@return boolean
---@return string
function git.push(root)
    ensure_git()

    local request, request_error = push_request(root)

    if request == nil then
        return false, request_error
    end

    local out = git.run(request.args, request.opts)

    return out.exit_code == 0, return_result(out)
end

---@param callback GitAsyncCallback
---@param root string?
function git.push_async(callback, root)
    ensure_git()

    local request, request_error = push_request(root)

    if request == nil then
        callback(false, request_error)
        return
    end

    git.run_async(request.args, request.opts, callback)
end

return git
