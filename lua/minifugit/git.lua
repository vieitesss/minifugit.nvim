---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

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

---@param cwd string
---@return table<string, string>?
local function pinned_env(cwd)
    return pinned_env_by_root[vim.fs.normalize(cwd)]
end

---Environment for a child that must not see the editor's Git discovery
---variables. `clear_env` removes them, so they must be absent instead of
---overridden with another value.
---@return table<string, string>
local function environ_without_git_discovery()
    local env = vim.fn.environ()
    env.GIT_DIR = nil
    env.GIT_WORK_TREE = nil

    return env
end

---@param opts {text: boolean?, git_env: string?} `git_env` is `'ignored'`
---  or `'inherited'`; nil uses the environment pinned for `cwd`.
---@param cwd string
---@param text boolean? Overrides `opts.text`.
---@return table
local function child_opts(opts, cwd, text)
    if text == nil then
        text = opts.text ~= false
    end

    if opts.git_env == 'ignored' then
        -- `clear_env` removes the variables; a merged `env` could only replace
        -- them, and GIT_DIR set to another value still redirects the call.
        return {
            text = text,
            cwd = cwd,
            env = environ_without_git_discovery(),
            clear_env = true,
        }
    end

    if opts.git_env == 'inherited' then
        return { text = text, cwd = cwd }
    end

    return { text = text, cwd = cwd, env = pinned_env(cwd) }
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

    local job = vim.system(cmd, child_opts(opts, cwd))
    local res = normalize_result(job:wait())

    log_result(cmd, res, opts.ignore_error)

    return res
end

---Executes a git command asynchronously.
---@param args string[] List of git arguments (e.g., {"push"})
---@param opts? { cwd: string?, ignore_error: boolean?, git_env: string? }
---@param callback GitAsyncCallback
function git.run_async(args, opts, callback)
    opts = opts or {}

    if not ensure_git() then
        callback(false, '`git` is not executable')
        return
    end

    local cmd = git_command(args)
    local cwd = opts.cwd or vim.fn.getcwd()

    vim.system(cmd, child_opts(opts, cwd, true), function(result)
        vim.schedule(function()
            local res = normalize_result(result)

            log_result(cmd, res, opts.ignore_error)

            callback(res.exit_code == 0, return_result(res))
        end)
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

---Pin the absolute Git environment of `root` for its later calls.
---@param root string
---@param cwd string Directory the discovery ran in; relative values resolve
---  against it, as they did during discovery.
---@param ignore_env boolean
local function pin_env(root, cwd, ignore_env)
    local out = git.run({ 'rev-parse', '--absolute-git-dir' }, {
        cwd = cwd,
        ignore_error = true,
        text = false,
        git_env = ignore_env and 'ignored' or 'inherited',
    })

    if out.exit_code ~= 0 then
        return
    end

    pinned_env_by_root[vim.fs.normalize(root)] = {
        GIT_DIR = out.output:gsub('\n$', ''),
        GIT_WORK_TREE = root,
    }
end

---Read the toplevel byte for byte: text mode and `return_result()` would
---rewrite or trim carriage returns that belong to the directory name.
---@param cwd string
---@param ignore_env boolean Ignore the editor's Git discovery variables.
---@return string root '' when no repository is found
local function discover_root(cwd, ignore_env)
    local out = git.run({ 'rev-parse', '--show-toplevel' }, {
        cwd = cwd,
        ignore_error = true,
        text = false,
        git_env = ignore_env and 'ignored' or 'inherited',
    })

    if out.exit_code ~= 0 then
        return ''
    end

    return out.output:gsub('\n$', '')
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

    local root = discover_root(cwd, ignore_env)
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

---@param root string? Repository root; defaults to the current cwd's root.
---@return GitStatusSnapshot
function git.status_snapshot(root)
    if not ensure_git() then
        return {
            branch = '',
            entries = {},
            unpushed_commits = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    root = root or git.root()

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
        { 'status', '--porcelain=v1', '-z', '--untracked-files=all' },
        { cwd = root, text = false }
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
local NO_UPSTREAM_MESSAGE = function(root)
    local branch_out = git.run({ 'branch', '--show-current' }, { cwd = root })
    return 'No upstream configured. Run git push -u origin '
        .. return_result(branch_out)
end

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
    local range = upstream ~= nil and upstream .. '..HEAD' or 'HEAD'
    local args = { 'log', '--format=%H%x1f%s', '-20', range }

    if upstream == nil then
        vim.list_extend(args, { '--not', '--remotes' })
    end

    local out = git.run(args, { cwd = root, ignore_error = true })

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

    -- Translate name-status records to porcelain records for the shared parser.
    local records = {}
    local fields = vim.split(out.output, '\0', { plain = true })
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

    local untracked =
        git.run({ 'ls-files', '--others', '--exclude-standard', '-z' }, opts)
    if untracked.exit_code ~= 0 then
        return {}, return_result(untracked)
    end
    for _, path in ipairs(vim.split(untracked.output, '\0', { plain = true })) do
        if path ~= '' then
            table.insert(records, '?? ' .. path .. '\0')
        end
    end

    return parse_status(table.concat(records)), nil
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

---@param path string
---@param root string?
---@return string[]
---@return string?
local function read_worktree_lines(path, root)
    root = root or git.root()

    local full_path = root ~= '' and vim.fs.joinpath(root, path) or path
    local stat = vim.uv.fs_stat(full_path)

    if stat == nil then
        return {}, 'Cannot stat file: ' .. full_path
    end

    if stat.type == 'directory' then
        return {}, 'Diff preview is not available for directories'
    end

    local ok, lines = pcall(vim.fn.readfile, full_path)

    if not ok then
        return {}, 'Cannot read file: ' .. tostring(lines)
    end

    return lines, nil
end

---@param spec string
---@param root string?
---@return string[]
---@return string?
local function read_blob_lines(spec, root)
    local out = git.run({ 'show', spec }, root_opts(root))

    if out.exit_code ~= 0 then
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
---@param left_spec string
---@param left_title string
---@param root string?
---@param filetype string?
---@return GitSplitDiff?
---@return string?
local function blob_to_worktree_diff(
    entry,
    left_spec,
    left_title,
    root,
    filetype
)
    local left, right = {}, {}
    local err

    if entry.unstaged ~= 'A' then
        left, err = read_blob_lines(left_spec, root)
        if err ~= nil then
            return nil, err
        end
    end

    if entry.unstaged ~= 'D' then
        right, err = read_worktree_lines(entry.path, root)
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
            left, err = read_blob_lines('HEAD:' .. old_path, root)

            if err ~= nil then
                return nil, err
            end
        end

        local right = {}

        if entry.staged ~= 'D' then
            right, err = read_blob_lines(':' .. entry.path, root)

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
            ':' .. entry.path,
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

    local left_spec = base .. ':' .. (entry.orig_path or entry.path)
    return blob_to_worktree_diff(entry, left_spec, left_spec, root)
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
---@return string[]
---@return string?
function git.diff(entry, section, root)
    ensure_git()

    local args
    local opts = root_opts(root)
    local pathspecs = entry_pathspecs(entry)
    local full_path = opts.cwd ~= nil and vim.fs.joinpath(opts.cwd, entry.path)
        or entry.path
    local stat = vim.uv.fs_stat(full_path)

    if is_worktree_new_file(entry, section) then
        if stat ~= nil and stat.type == 'directory' then
            return {}, 'Diff preview is not available for untracked directories'
        end

        args = { 'diff', '--no-index', '--', null_device_path(), entry.path }
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

    local out = git.run(args, opts)

    if out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '') then
        return {}, return_result(out)
    end

    return parse_diff(out.output)
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

    local args = { 'diff', '--no-ext-diff', '-M', base, '--' }
    vim.list_extend(args, entry_pathspecs(entry))
    local out = git.run(args, root_opts(root))
    if out.exit_code ~= 0 then
        return {}, return_result(out)
    end
    return parse_diff(out.output), nil
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
