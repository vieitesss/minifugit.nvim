---@diagnostic disable: undefined-field
---@type table
local git = require('minifugit.git')
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

describe('minifugit.git', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type string?
    local other_repo
    ---@type string?
    local sub_repo
    local original_git_dir
    local original_git_work_tree

    before_each(function()
        original_cwd = vim.fn.getcwd()
        other_repo = nil
        sub_repo = nil
        original_git_dir = vim.env.GIT_DIR
        original_git_work_tree = vim.env.GIT_WORK_TREE
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, 'p')

        helpers.run({ 'git', 'init', '-b', 'main' }, repo)
        helpers.run({ 'git', 'config', 'user.name', 'Minifugit Test' }, repo)
        helpers.run(
            { 'git', 'config', 'user.email', 'minifugit@example.test' },
            repo
        )

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'one' })
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'initial commit' }, repo)

        vim.cmd.cd(vim.fn.fnameescape(repo))
    end)

    after_each(function()
        vim.env.GIT_DIR = original_git_dir
        vim.env.GIT_WORK_TREE = original_git_work_tree
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
        if other_repo ~= nil then
            vim.fn.delete(other_repo, 'rf')
        end
        if sub_repo ~= nil then
            vim.fn.delete(sub_repo, 'rf')
        end
    end)

    local function change_to_other_repo()
        other_repo = helpers.change_to_other_repo(repo)
        helpers.run({ 'git', 'checkout', '-b', 'other' }, other_repo)
    end

    it('honours an explicit root for snapshots after cwd changes', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        change_to_other_repo()

        local snapshot = git.status_snapshot(repo)

        assert.are.equal('main', snapshot.branch)
        assert.are.equal(repo, snapshot.root)
        assert.are.same({
            { staged = '?', unstaged = '?', path = 'only-a.txt' },
        }, snapshot.entries)
        assert.are.equal('initial commit', snapshot.unpushed_commits[1].message)
    end)

    for _, methods in ipairs({
        { stage = 'stage', unstage = 'unstage' },
        { stage = 'stage_entries', unstage = 'unstage_entries' },
    }) do
        it('honours an explicit root for ' .. methods.unstage, function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'changed in A' }
            )
            local entry = { staged = 'M', unstaged = ' ', path = 'tracked.txt' }
            local selected = methods.stage == 'stage' and entry or { entry }
            change_to_other_repo()

            assert.is_true(git[methods.stage](selected, repo))
            assert.are.equal(
                'M  tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, repo)
            )
            assert.is_true(git[methods.unstage](selected, repo))
            assert.are.equal(
                ' M tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, repo)
            )
            assert.are.equal(
                ' M tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, other_repo)
            )
        end)
    end

    for _, section in ipairs({ 'staged', 'unstaged', 'untracked' }) do
        it('reads ' .. section .. ' diffs from an explicit root', function()
            local name = section == 'untracked' and 'new.txt' or 'tracked.txt'
            helpers.write_file(vim.fs.joinpath(repo, name), { 'changed in A' })
            if section == 'staged' then
                helpers.run({ 'git', 'add', name }, repo)
            end
            local entry = helpers.entry_by_path(git.status(), name)
            change_to_other_repo()
            helpers.write_file(
                vim.fs.joinpath(other_repo, name),
                { 'changed in B' }
            )

            local lines, err = git.diff(entry, section, repo)
            assert.is_nil(err)
            helpers.assert_has_line_containing(lines, '+changed in A')
            local split, split_err = git.split_diff(entry, section, repo)
            assert.is_nil(split_err)
            assert.are.same({ 'changed in A' }, split.right.lines)
            assert.are.same(
                section == 'untracked' and {} or { 'one' },
                split.left.lines
            )
        end)
    end

    -- Windows does not allow symlinks without extra privileges.
    local unix_it = vim.fn.has('win32') == 1 and pending or it
    unix_it(
        'reads a symlink target as the worktree side of split previews',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'target.txt'), { 'one' })
            helpers.run({ 'git', 'add', 'target.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add target' }, repo)
            vim.fn.delete(vim.fs.joinpath(repo, 'tracked.txt'))
            assert.is_not_nil(
                vim.uv.fs_symlink(
                    'target.txt',
                    vim.fs.joinpath(repo, 'tracked.txt')
                )
            )
            local entry = helpers.entry_by_path(git.status(), 'tracked.txt')

            local split, err = git.split_diff(entry, 'unstaged', repo)

            assert.is_nil(err)
            assert.are.same({ 'one' }, split.left.lines)
            assert.are.same({ 'target.txt' }, split.right.lines)
        end
    )

    unix_it(
        'splits a newline-bearing symlink target into buffer-safe lines',
        function()
            vim.fn.delete(vim.fs.joinpath(repo, 'tracked.txt'))
            assert.is_not_nil(
                vim.uv.fs_symlink(
                    'missing\ntarget.txt',
                    vim.fs.joinpath(repo, 'tracked.txt')
                )
            )
            local entry = helpers.entry_by_path(git.status(), 'tracked.txt')

            local split, err = git.split_diff(entry, 'unstaged', repo)

            assert.is_nil(err)
            assert.are.same({ 'one' }, split.left.lines)
            assert.are.same({ 'missing', 'target.txt' }, split.right.lines)
        end
    )

    ---Create a submodule source repository; `after_each` deletes it.
    ---@return string first
    ---@return string second
    local function create_sub_repo()
        local source, first, second = helpers.create_sub_repo()
        sub_repo = source
        return first, second
    end

    it(
        'previews a submodule split from the index commit id to its checked-out HEAD',
        function()
            local first, second = create_sub_repo()
            helpers.record_submodule(repo, 'sub', sub_repo, first)
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)
            local entry = helpers.entry_by_path(git.status(), 'sub')

            local split, err = git.split_diff(entry, 'unstaged', repo)

            assert.is_nil(err)
            assert.are.same({ 'Subproject commit ' .. first }, split.left.lines)
            assert.are.same(
                { 'Subproject commit ' .. second },
                split.right.lines
            )
        end
    )

    it(
        'reads the checked-out submodule HEAD after the root is pinned',
        function()
            local first, second = create_sub_repo()
            helpers.record_submodule(repo, 'sub', sub_repo, first)
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)

            local root = git.root(repo)
            assert.are.not_equal('', root)
            local entry =
                helpers.entry_by_path(git.status_snapshot(root).entries, 'sub')

            local split, err = git.split_diff(entry, 'unstaged', root)

            assert.is_nil(err)
            assert.are.same({ 'Subproject commit ' .. first }, split.left.lines)
            assert.are.same(
                { 'Subproject commit ' .. second },
                split.right.lines
            )
        end
    )

    it(
        'previews a staged submodule split from HEAD to the index commit id',
        function()
            local first, second = create_sub_repo()
            helpers.record_submodule(repo, 'sub', sub_repo, first)
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)
            helpers.run({ 'git', 'add', 'sub' }, repo)
            local entry = helpers.entry_by_path(git.status(), 'sub')

            local split, err = git.split_diff(entry, 'staged', repo)

            assert.is_nil(err)
            assert.are.same({ 'Subproject commit ' .. first }, split.left.lines)
            assert.are.same(
                { 'Subproject commit ' .. second },
                split.right.lines
            )
        end
    )

    for _, kind in ipairs({ 'stage', 'unstage', 'discard' }) do
        it('applies a ' .. kind .. ' hunk in an explicit root', function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'changed in A' }
            )
            local patch = vim.split(
                vim.trim(
                    helpers.run({ 'git', 'diff', '--', 'tracked.txt' }, repo)
                ),
                '\n',
                { plain = true }
            )
            if kind == 'unstage' then
                helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
            end
            change_to_other_repo()

            local ok, err = git.apply_hunk(patch, kind, repo)
            assert.is_true(ok, err)
            local expected = ({
                stage = 'M  tracked.txt\n',
                unstage = ' M tracked.txt\n',
                discard = '',
            })[kind]
            assert.are.equal(
                expected,
                helpers.run({ 'git', 'status', '--short' }, repo)
            )
            assert.are.equal(
                ' M tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, other_repo)
            )
            assert.are.same(
                { 'changed in B' },
                vim.fn.readfile(vim.fs.joinpath(other_repo, 'tracked.txt'))
            )
        end)
    end

    it('inspects staged changes in an explicit root', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        helpers.run({ 'git', 'add', 'only-a.txt' }, repo)
        change_to_other_repo()

        local has_changes, err = git.has_staged_changes(repo)

        assert.is_nil(err)
        assert.is_true(has_changes)
    end)

    it('builds a commit template from an explicit root', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        helpers.run({ 'git', 'add', 'only-a.txt' }, repo)
        change_to_other_repo()

        local lines = git.commit_template(repo)

        helpers.assert_has_line_containing(lines, 'only-a.txt')
        helpers.assert_has_line_containing(lines, 'On branch main')
        for _, line in ipairs(lines) do
            assert.is_nil(line:find('tracked.txt', 1, true))
        end
    end)

    it('commits a message file in an explicit root', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        helpers.run({ 'git', 'add', 'only-a.txt' }, repo)
        change_to_other_repo()
        local path = vim.fs.joinpath(repo, '.git', 'test-message')
        helpers.write_file(path, { 'commit in A' })

        local ok, err = git.commit_file(path, repo)

        assert.is_true(ok, err)
        assert.are.equal(
            'commit in A\n',
            helpers.run({ 'git', 'log', '-1', '--pretty=%s' }, repo)
        )
        assert.are.equal(
            'initial commit\n',
            helpers.run({ 'git', 'log', '-1', '--pretty=%s' }, other_repo)
        )
        assert.are.equal(
            ' M tracked.txt\n',
            helpers.run({ 'git', 'status', '--short' }, other_repo)
        )
    end)

    it('shows a commit from an explicit root', function()
        change_to_other_repo()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'commit A' })
        helpers.run({ 'git', 'add', 'only-a.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'only in A' }, repo)
        local hash = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))

        local lines, err = git.show_commit({ hash = hash }, repo)

        assert.is_nil(err)
        helpers.assert_has_line_containing(lines, 'only in A')
        helpers.assert_has_line_containing(lines, '+commit A')
    end)

    it('scopes upstream error messages to the explicit root', function()
        change_to_other_repo()

        local upstream, upstream_err = git.upstream(repo)
        local destination, destination_err = git.push_destination(repo)

        assert.is_nil(upstream)
        assert.is_nil(destination)
        local expected = 'No upstream configured. Run git push -u origin main'
        assert.are.equal(expected, upstream_err)
        assert.are.equal(expected, destination_err)
    end)

    for _, async in ipairs({ false, true }) do
        it(
            'pushes from an explicit root'
                .. (async and ' asynchronously' or ''),
            function()
                local remote = vim.fs.joinpath(repo, '.git', 'test-remote.git')
                helpers.run({ 'git', 'init', '--bare', remote }, repo)
                helpers.run({ 'git', 'remote', 'add', 'origin', remote }, repo)
                helpers.run({ 'git', 'push', '-u', 'origin', 'main' }, repo)
                change_to_other_repo()
                helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
                helpers.run({ 'git', 'add', 'only-a.txt' }, repo)
                helpers.run({ 'git', 'commit', '-m', 'push from A' }, repo)

                local ok, output
                if async then
                    git.push_async(function(success, message)
                        ok, output = success, message
                    end, repo)
                    assert.is_true(vim.wait(2000, function()
                        return ok ~= nil
                    end))
                else
                    ok, output = git.push(repo)
                end

                assert.is_true(ok, output)
                assert.are.equal(
                    'push from A\n',
                    helpers.run({
                        'git',
                        '--git-dir=' .. remote,
                        'log',
                        'main',
                        '-1',
                        '--pretty=%s',
                    }, repo)
                )
                assert.are.equal(
                    ' M tracked.txt\n',
                    helpers.run({ 'git', 'status', '--short' }, other_repo)
                )
                assert.are.equal(
                    'initial commit\n',
                    helpers.run(
                        { 'git', 'log', '-1', '--pretty=%s' },
                        other_repo
                    )
                )
            end
        )
    end

    for _, kind in ipairs({ 'unstaged', 'untracked' }) do
        it('discards ' .. kind .. ' files in an explicit root', function()
            local name = kind == 'untracked' and 'new.txt' or 'tracked.txt'
            helpers.write_file(vim.fs.joinpath(repo, name), { 'changed in A' })
            local entries = git.status()
            change_to_other_repo()
            helpers.write_file(
                vim.fs.joinpath(other_repo, name),
                { 'changed in B' }
            )
            local other_status =
                helpers.run({ 'git', 'status', '--short' }, other_repo)

            local ok, err = git['discard_' .. kind .. '_entries'](entries, repo)

            assert.is_true(ok, err)
            assert.are.equal(
                '',
                helpers.run({ 'git', 'status', '--short' }, repo)
            )
            assert.are.equal(
                other_status,
                helpers.run({ 'git', 'status', '--short' }, other_repo)
            )
            assert.are.same(
                { 'changed in B' },
                vim.fn.readfile(vim.fs.joinpath(other_repo, name))
            )
        end)
    end

    it('returns a safe snapshot outside a git repository', function()
        local not_repo = vim.fn.tempname()
        vim.fn.mkdir(not_repo, 'p')
        vim.cmd.cd(vim.fn.fnameescape(not_repo))

        ---@type GitStatusSnapshot
        local snapshot = git.status_snapshot()

        assert.are.equal('', snapshot.root)
        assert.are.equal('', snapshot.branch)
        assert.are.same({}, snapshot.entries)
        assert.are.equal('Not inside a git repository', snapshot.error)

        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.fn.delete(not_repo, 'rf')
    end)

    it('finds the root again when the repository changes', function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        vim.cmd.cd(vim.fn.fnameescape(dir))

        assert.are.equal('', git.root())

        helpers.run({ 'git', 'init', '-b', 'main' }, dir)
        assert.are.equal(vim.fn.resolve(dir), vim.fn.resolve(git.root()))

        vim.fn.delete(vim.fs.joinpath(dir, '.git'), 'rf')
        assert.are_not.equal(vim.fn.resolve(dir), vim.fn.resolve(git.root()))

        vim.cmd.cd(vim.fn.fnameescape(repo))
        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))
        vim.fn.delete(dir, 'rf')
    end)

    it('finds newly created nested repositories', function()
        local child = vim.fs.joinpath(repo, 'child')
        local inner = vim.fs.joinpath(child, 'inner')
        vim.fn.mkdir(inner, 'p')
        vim.cmd.cd(vim.fn.fnameescape(inner))

        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))

        helpers.run({ 'git', 'init', '-b', 'main' }, child)
        assert.are.equal(vim.fn.resolve(child), vim.fn.resolve(git.root()))

        helpers.run({ 'git', 'init', '-b', 'main' }, inner)
        assert.are.equal(vim.fn.resolve(inner), vim.fn.resolve(git.root()))
    end)

    it('finds the root again when Git discovery environment changes', function()
        vim.env.GIT_DIR = nil
        vim.env.GIT_WORK_TREE = nil
        local other = vim.fs.joinpath(repo, 'other')
        vim.fn.mkdir(other, 'p')
        helpers.run({ 'git', 'init', '-b', 'main' }, other)

        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))

        vim.env.GIT_DIR = vim.fs.joinpath(other, '.git')
        vim.env.GIT_WORK_TREE = other
        assert.are.equal(vim.fn.resolve(other), vim.fn.resolve(git.root()))

        vim.env.GIT_WORK_TREE = repo
        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))

        vim.env.GIT_WORK_TREE = other
        assert.are.equal(vim.fn.resolve(other), vim.fn.resolve(git.root()))

        vim.env.GIT_WORK_TREE = repo
        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))
        vim.env.GIT_DIR = vim.fs.joinpath(repo, 'missing-git-dir')
        assert.are.equal('', git.root())
    end)

    it('finds an explicit worktree from outside it without hanging', function()
        local outside = vim.fn.tempname()
        vim.fn.mkdir(outside, 'p')
        local script = vim.fs.joinpath(outside, 'check_root.lua')
        vim.fn.writefile({
            "local git = require('minifugit.git')",
            'local expected = vim.fn.resolve(vim.env.GIT_WORK_TREE)',
            'assert(vim.fn.resolve(git.root()) == expected)',
            'assert(vim.fn.resolve(git.root()) == expected)',
        }, script)

        local result = vim.system({
            vim.v.progpath,
            '--headless',
            '--noplugin',
            '-u',
            vim.fs.joinpath(vim.fs.dirname(spec_dir), 'minimal_init.lua'),
            '-l',
            script,
        }, {
            cwd = outside,
            env = {
                GIT_DIR = vim.fs.joinpath(repo, '.git'),
                GIT_WORK_TREE = repo,
            },
            text = true,
        }):wait(5000)
        vim.fn.delete(outside, 'rf')

        assert.are.equal(0, result.code, result.stderr)
    end)

    it('collects branch, root, and porcelain status entries', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.write_file(vim.fs.joinpath(repo, 'staged.txt'), { 'staged' })
        helpers.write_file(
            vim.fs.joinpath(repo, 'untracked.txt'),
            { 'untracked' }
        )
        helpers.run({ 'git', 'add', 'staged.txt' }, repo)

        ---@type GitStatusSnapshot
        local snapshot = git.status_snapshot()

        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(snapshot.root))
        assert.are.equal('main', snapshot.branch)
        assert.is_nil(snapshot.error)

        ---@type GitStatusEntry?
        local tracked = helpers.entry_by_path(snapshot.entries, 'tracked.txt')
        ---@type GitStatusEntry?
        local staged = helpers.entry_by_path(snapshot.entries, 'staged.txt')
        ---@type GitStatusEntry?
        local untracked =
            helpers.entry_by_path(snapshot.entries, 'untracked.txt')

        assert.are.same(
            { staged = ' ', unstaged = 'M', path = 'tracked.txt' },
            tracked
        )
        assert.are.same(
            { staged = 'A', unstaged = ' ', path = 'staged.txt' },
            staged
        )
        assert.are.same(
            { staged = '?', unstaged = '?', path = 'untracked.txt' },
            untracked
        )
    end)

    -- Windows does not allow control characters in file names.
    local unix_it = vim.fn.has('win32') == 1 and pending or it
    unix_it('keeps CRLF and lone carriage returns in status paths', function()
        for _, path in ipairs({ 'line\r\nbreak.txt', 'trailing\r' }) do
            helpers.write_file(repo .. '/' .. path, { 'new' })
        end

        assert.are.same({
            { staged = '?', unstaged = '?', path = 'line\r\nbreak.txt' },
            { staged = '?', unstaged = '?', path = 'trailing\r' },
        }, git.status())
    end)

    unix_it('finds roots whose paths contain carriage returns', function()
        local parent = vim.fn.tempname()

        for _, name in ipairs({ 'repo\r\npath', 'repo\r' }) do
            local dir = vim.fs.joinpath(parent, name)
            vim.fn.mkdir(dir, 'p')
            helpers.run({ 'git', 'init', '-b', 'main' }, dir)

            assert.are.equal(vim.fn.resolve(dir), vim.fn.resolve(git.root(dir)))
        end

        vim.fn.delete(parent, 'rf')
    end)

    unix_it('normalizes text by default but preserves raw -z output', function()
        helpers.run({ 'git', 'config', 'core.autocrlf', 'false' }, repo)
        helpers.write_file(repo .. '/tracked.txt', { 'one\r', 'two\r' })
        helpers.write_file(repo .. '/line\r\nbreak.txt', { 'new' })
        helpers.run({ 'git', 'add', '.' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'track CRLF content' }, repo)

        local text = git.run({ 'show', 'HEAD:tracked.txt' })
        assert.are.equal(0, text.exit_code, text.stderr)
        assert.are.equal('one\ntwo\n', text.output)

        local raw = git.run({ 'ls-files', '-z' }, { text = false })
        assert.are.equal(0, raw.exit_code, raw.stderr)
        assert.are.equal('line\r\nbreak.txt\0tracked.txt\0', raw.output)
    end)

    it('lists files inside untracked directories recursively', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'new-dir/file.txt'),
            { 'file' }
        )
        helpers.write_file(
            vim.fs.joinpath(repo, 'new-dir/inner-dir/nested.txt'),
            { 'nested' }
        )

        local entries = git.status_snapshot().entries

        assert.are.same(
            { staged = '?', unstaged = '?', path = 'new-dir/file.txt' },
            helpers.entry_by_path(entries, 'new-dir/file.txt')
        )
        assert.are.same({
            staged = '?',
            unstaged = '?',
            path = 'new-dir/inner-dir/nested.txt',
        }, helpers.entry_by_path(
            entries,
            'new-dir/inner-dir/nested.txt'
        ))
        assert.is_nil(helpers.entry_by_path(entries, 'new-dir/'))
    end)

    it('previews a diff for an untracked file', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'new-dir/file.txt'),
            { 'new content' }
        )

        local entry = helpers.entry_by_path(git.status(), 'new-dir/file.txt')
        local lines, err = git.diff(entry, 'untracked')

        assert.is_nil(err)
        helpers.assert_has_line_containing(lines, 'new file mode')
        helpers.assert_has_line_containing(lines, '+new content')
    end)

    it('previews an unstaged new file as a full-file diff', function()
        helpers.write_file(vim.fs.joinpath(repo, 'intent.txt'), {
            'new content',
        })
        helpers.run({ 'git', 'add', '-N', 'intent.txt' }, repo)

        local entry = helpers.entry_by_path(git.status(), 'intent.txt')
        local lines, err = git.diff(entry, 'unstaged')

        assert.is_nil(err)
        helpers.assert_has_line_containing(lines, 'new file mode')
        helpers.assert_has_line_containing(lines, '+new content')
    end)

    it(
        'stages, unstages, and discards files through public API calls',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'changed' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )

            ---@type GitStatusEntry?
            local tracked = helpers.entry_by_path(git.status(), 'tracked.txt')
            local ok = git.stage(tracked)
            assert.is_true(ok)
            assert.are.equal(
                'M',
                helpers.entry_by_path(git.status(), 'tracked.txt').staged
            )

            ok = git.unstage(helpers.entry_by_path(git.status(), 'tracked.txt'))
            assert.is_true(ok)
            assert.are.equal(
                ' ',
                helpers.entry_by_path(git.status(), 'tracked.txt').staged
            )

            ok = git.discard_unstaged_entries({
                helpers.entry_by_path(git.status(), 'tracked.txt'),
            })
            assert.is_true(ok)
            assert.is_nil(helpers.entry_by_path(git.status(), 'tracked.txt'))

            ok = git.discard_untracked_entries({
                helpers.entry_by_path(git.status(), 'untracked.txt'),
            })
            assert.is_true(ok)
            assert.is_nil(helpers.entry_by_path(git.status(), 'untracked.txt'))
        end
    )

    it('stages edits to a file whose rename is already staged', function()
        helpers.run({ 'git', 'mv', 'tracked.txt', 'renamed.txt' }, repo)
        helpers.write_file(
            vim.fs.joinpath(repo, 'renamed.txt'),
            { 'one', 'two' }
        )
        local entry = helpers.entry_by_path(git.status(), 'renamed.txt')
        assert.are.equal('R', entry.staged)
        assert.are.equal('M', entry.unstaged)
        assert.are.equal('tracked.txt', entry.orig_path)

        local ok, err = git.stage(entry)

        assert.is_true(ok, err)
        assert.are.equal(
            'R  tracked.txt -> renamed.txt\n',
            helpers.run({ 'git', 'status', '--short' }, repo)
        )
        assert.are.equal(
            'one\ntwo\n',
            helpers.run({ 'git', 'show', ':renamed.txt' }, repo)
        )
    end)

    for _, paths in ipairs({
        { path = ':(literal)report.txt', unrelated = 'report.txt' },
        { path = 'star*.txt', unrelated = 'star-other.txt' },
    }) do
        describe('literal filename ' .. paths.path, function()
            before_each(function()
                helpers.write_file(
                    repo .. '/' .. paths.path,
                    { 'selected content' }
                )
                helpers.write_file(
                    repo .. '/' .. paths.unrelated,
                    { 'unrelated content' }
                )
            end)

            it('stages only selected entries', function()
                local entry =
                    helpers.entry_by_path(git.status(repo), paths.path)
                local ok, err = git.stage_entries({ entry }, repo)

                assert.is_true(ok, err)
                local entries = git.status(repo)
                assert.are.equal(
                    'A',
                    helpers.entry_by_path(entries, paths.path).staged
                )
                assert.are.equal(
                    '?',
                    helpers.entry_by_path(entries, paths.unrelated).staged
                )
            end)

            it('unstages only selected entries', function()
                helpers.run({ 'git', 'add', '.' }, repo)
                local entry =
                    helpers.entry_by_path(git.status(repo), paths.path)
                local ok, err = git.unstage_entries({ entry }, repo)

                assert.is_true(ok, err)
                local entries = git.status(repo)
                assert.are.equal(
                    '?',
                    helpers.entry_by_path(entries, paths.path).staged
                )
                assert.are.equal(
                    'A',
                    helpers.entry_by_path(entries, paths.unrelated).staged
                )
            end)

            it('discards only selected untracked entries', function()
                local entry =
                    helpers.entry_by_path(git.status(repo), paths.path)
                local ok, err = git.discard_untracked_entries({ entry }, repo)

                assert.is_true(ok, err)
                assert.are.equal(
                    0,
                    vim.fn.filereadable(repo .. '/' .. paths.path)
                )
                assert.are.same(
                    { 'unrelated content' },
                    vim.fn.readfile(repo .. '/' .. paths.unrelated)
                )
            end)

            describe('when both files are committed', function()
                before_each(function()
                    helpers.run({ 'git', 'add', '.' }, repo)
                    helpers.run({ 'git', 'commit', '-m', 'add files' }, repo)
                    helpers.write_file(
                        repo .. '/' .. paths.path,
                        { 'selected edit' }
                    )
                    helpers.write_file(
                        repo .. '/' .. paths.unrelated,
                        { 'unrelated edit', 'added line', 'another line' }
                    )
                end)

                it('discards only selected unstaged entries', function()
                    local entry =
                        helpers.entry_by_path(git.status(repo), paths.path)
                    local ok, err =
                        git.discard_unstaged_entries({ entry }, repo)

                    assert.is_true(ok, err)
                    assert.are.same(
                        { 'selected content' },
                        vim.fn.readfile(repo .. '/' .. paths.path)
                    )
                    assert.are.same(
                        { 'unrelated edit', 'added line', 'another line' },
                        vim.fn.readfile(repo .. '/' .. paths.unrelated)
                    )
                end)

                it('counts changes of the selected file only', function()
                    local counts, err = git.file_change_counts(paths.path)

                    assert.is_nil(err)
                    assert.are.same(
                        { added = 0, modified = 1, deleted = 0 },
                        counts
                    )
                end)
            end)
        end)
    end

    it('reports whether the index has staged changes', function()
        local has_changes, err = git.has_staged_changes()
        assert.is_false(has_changes)
        assert.is_nil(err)

        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        has_changes, err = git.has_staged_changes()
        assert.is_false(has_changes)
        assert.is_nil(err)

        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)

        has_changes, err = git.has_staged_changes()
        assert.is_true(has_changes)
        assert.is_nil(err)
    end)

    it('counts added, modified, and deleted lines for a file', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one changed', 'two', 'four' }
        )

        local counts, err = git.file_change_counts('tracked.txt')

        assert.is_nil(err)
        assert.are.same({ added = 2, modified = 1, deleted = 0 }, counts)
    end)

    unix_it('counts tracked CRLF file changes from snapshot paths', function()
        local path = 'line\r\nbreak.txt'
        helpers.write_file(repo .. '/' .. path, { 'one', 'two' })
        helpers.run({ 'git', 'add', '--', path }, repo)
        helpers.run({ 'git', 'commit', '-m', 'track CRLF filename' }, repo)
        helpers.write_file(
            repo .. '/' .. path,
            { 'one changed', 'two', 'three' }
        )

        local snapshot = git.status_snapshot(repo)
        assert.is_nil(snapshot.error)
        assert.are.equal(1, #snapshot.entries)
        local counts, err = git.file_change_counts(snapshot.entries[1].path)

        assert.is_nil(err)
        assert.are.same({ added = 1, modified = 1, deleted = 0 }, counts)
        assert.are.equal(path, snapshot.entries[1].path)
    end)

    it('counts untracked file lines as added', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'untracked.txt'),
            { 'one', 'two' }
        )

        local counts, err = git.file_change_counts('untracked.txt')

        assert.is_nil(err)
        assert.are.same({ added = 2, modified = 0, deleted = 0 }, counts)
    end)

    it('counts deleted lines for a file', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two', 'three' }
        )
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'track multiple lines' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'one' })

        local counts, err = git.file_change_counts('tracked.txt')

        assert.is_nil(err)
        assert.are.same({ added = 0, modified = 0, deleted = 2 }, counts)
    end)

    it('rejects directories for file change counts', function()
        vim.fn.mkdir(vim.fs.joinpath(repo, 'tracked-dir'), 'p')
        helpers.write_file(vim.fs.joinpath(repo, 'tracked-dir/file.txt'), {
            'one',
        })
        helpers.run({ 'git', 'add', 'tracked-dir/file.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'track directory' }, repo)

        local counts, err = git.file_change_counts('tracked-dir')

        assert.are.equal(
            'File change counts are not available for directories',
            err
        )
        assert.are.same({ added = 0, modified = 0, deleted = 0 }, counts)
    end)

    it('rejects the repository root for file change counts', function()
        local counts, err = git.file_change_counts(repo)

        assert.are.equal(
            'File change counts are not available for directories',
            err
        )
        assert.are.same({ added = 0, modified = 0, deleted = 0 }, counts)
    end)

    it('reports useful push errors for edge cases', function()
        local ok, message = git.push()

        assert.is_false(ok)
        assert.are.equal(
            'No upstream configured. Run git push -u origin main',
            message
        )

        helpers.run({ 'git', 'checkout', '--detach' }, repo)
        ok, message = git.push()

        assert.is_false(ok)
        assert.are.equal('Cannot push from detached HEAD', message)
    end)
end)

describe('minifugit.git Git discovery environment', function()
    ---@type string
    local original_cwd
    ---@type string?
    local original_git_dir
    ---@type string?
    local original_git_work_tree
    ---@type string[]
    local temp_dirs

    before_each(function()
        original_cwd = vim.fn.getcwd()
        original_git_dir = vim.env.GIT_DIR
        original_git_work_tree = vim.env.GIT_WORK_TREE
        temp_dirs = {}
    end)

    after_each(function()
        vim.env.GIT_DIR = original_git_dir
        vim.env.GIT_WORK_TREE = original_git_work_tree
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs(temp_dirs) do
            vim.fn.delete(dir, 'rf')
        end
    end)

    ---@return string
    local function temp_dir()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        table.insert(temp_dirs, dir)
        return dir
    end

    ---@param path string Relative path in the repository.
    ---@return string repo
    local function temp_repo(path)
        local repo = helpers.create_repo({ [path] = { 'one' } })
        table.insert(temp_dirs, repo)
        return repo
    end

    ---Paths staged in `repo` according to Git, ignoring the editor's
    ---environment on purpose: assertions must not depend on the values under
    ---test.
    ---@param repo string
    ---@return string
    local function staged_paths(repo)
        return helpers.run({
            'git',
            '--git-dir=' .. vim.fs.joinpath(repo, '.git'),
            '--work-tree=' .. repo,
            'diff',
            '--cached',
            '--name-only',
        }, repo)
    end

    it('ignores inherited variables for an explicit directory', function()
        local repo = temp_repo('tracked-a.txt')
        local plain = temp_dir()

        vim.env.GIT_DIR = vim.fs.joinpath(repo, '.git')
        vim.env.GIT_WORK_TREE = repo

        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root(repo)))
        assert.are.equal('', git.root(plain))
    end)

    it(
        'pins an explicit root so later calls ignore inherited variables',
        function()
            local environment = temp_repo('tracked-a.txt')
            local repo = temp_repo('tracked-b.txt')
            helpers.write_file(
                vim.fs.joinpath(environment, 'tracked-a.txt'),
                { 'one', 'two' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked-b.txt'),
                { 'one', 'two' }
            )
            vim.env.GIT_DIR = vim.fs.joinpath(environment, '.git')
            vim.env.GIT_WORK_TREE = environment
            local root = git.root(repo)
            local entry = helpers.entry_by_path(
                git.status_snapshot(root).entries,
                'tracked-b.txt'
            )

            assert.is_not_nil(entry)
            assert.is_true(git.stage(entry, root))
            assert.are.equal('tracked-b.txt\n', staged_paths(repo))
            assert.are.equal('', staged_paths(environment))
        end
    )

    it('resolves relative variables from the discovery directory', function()
        local repo = temp_repo('tracked.txt')
        local sub = vim.fs.joinpath(repo, 'sub')
        vim.fn.mkdir(sub, 'p')
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.write_file(vim.fs.joinpath(repo, 'untracked.txt'), { 'new' })
        vim.cmd.cd(vim.fn.fnameescape(sub))
        vim.env.GIT_DIR = '../.git'
        vim.env.GIT_WORK_TREE = '..'

        local root = git.root()

        assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(root))

        local snapshot = git.status_snapshot(root)
        local paths = {}

        assert.is_nil(snapshot.error)
        assert.are.equal('main', snapshot.branch)
        for _, entry in ipairs(snapshot.entries) do
            paths[entry.path] = entry.unstaged
        end
        assert.are.equal('M', paths['tracked.txt'])
        assert.are.equal('?', paths['untracked.txt'])
    end)

    it('keeps an environment-only repository working', function()
        local worktree = temp_dir()
        local git_dir = temp_dir()
        helpers.run({ 'git', 'init', '--bare' }, git_dir)
        helpers.write_file(vim.fs.joinpath(worktree, 'dotfile'), { 'dot' })
        vim.env.GIT_DIR = git_dir
        vim.env.GIT_WORK_TREE = worktree

        local root = git.root()

        assert.are.equal(vim.fn.resolve(worktree), vim.fn.resolve(root))

        local snapshot = git.status_snapshot()

        assert.is_nil(snapshot.error)
        assert.are.equal(
            vim.fn.resolve(worktree),
            vim.fn.resolve(snapshot.root)
        )
        local entry = helpers.entry_by_path(snapshot.entries, 'dotfile')
        assert.is_not_nil(entry)
        assert.is_true(git.stage(entry, root))
        assert.are.equal(
            'dotfile\n',
            helpers.run({
                'git',
                '--git-dir=' .. git_dir,
                '--work-tree=' .. worktree,
                'diff',
                '--cached',
                '--name-only',
            }, worktree)
        )
    end)
end)

describe('minifugit.git conflict split diffs', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo

    ---@param args string[]
    ---@return string
    local function run_git(args)
        return helpers.run(vim.list_extend({ 'git' }, args), repo)
    end

    ---@param path string
    ---@param lines string[]
    local function write(path, lines)
        helpers.write_file(vim.fs.joinpath(repo, path), lines)
    end

    ---Commit `theirs` on `feature` and `ours` on `main`, then merge `feature`.
    ---@param ours string[]
    ---@param theirs string[]
    local function merge_conflict(ours, theirs)
        run_git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', theirs)
        run_git({ 'commit', '-qam', 'theirs' })
        run_git({ 'checkout', '-q', 'main' })
        write('a.txt', ours)
        run_git({ 'commit', '-qam', 'ours' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)
    end

    ---@return GitStatusEntry?
    local function conflict_entry()
        return helpers.entry_by_path(git.status(), 'a.txt')
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({ ['a.txt'] = { 'one', 'two' } })
        vim.cmd.cd(vim.fn.fnameescape(repo))
    end)

    after_each(function()
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        vim.fn.delete(repo, 'rf')
    end)

    it('diffs stage 2 against stage 3 and titles both side refs', function()
        merge_conflict({ 'ours' }, { 'theirs' })

        local split, err = git.split_diff(conflict_entry(), 'conflicts', repo)

        assert.is_nil(err)
        assert.are.equal('HEAD (main)', split.left.title)
        assert.are.equal('MERGE_HEAD (feature)', split.right.title)
        assert.are.same({ 'ours' }, split.left.lines)
        assert.are.same({ 'theirs' }, split.right.lines)
        helpers.assert_has_line_containing(split.diff_lines, '-ours')
        helpers.assert_has_line_containing(split.diff_lines, '+theirs')
    end)

    it('names the incoming side by short hash when no branch has it', function()
        run_git({ 'checkout', '-q', '--detach', 'main' })
        write('a.txt', { 'theirs' })
        run_git({ 'commit', '-qam', 'theirs' })
        local theirs = vim.trim(run_git({ 'rev-parse', 'HEAD' }))
        run_git({ 'checkout', '-q', 'main' })
        write('a.txt', { 'ours' })
        run_git({ 'commit', '-qam', 'ours' })
        helpers.run({ 'sh', '-c', 'git merge ' .. theirs .. ' || true' }, repo)

        local split, err = git.split_diff(conflict_entry(), 'conflicts', repo)

        assert.is_nil(err)
        assert.are.equal(
            'MERGE_HEAD (' .. theirs:sub(1, 7) .. ')',
            split.right.title
        )
    end)

    it('names the first side from a detached HEAD during a rebase', function()
        run_git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', { 'theirs' })
        run_git({ 'commit', '-qam', 'theirs' })
        run_git({ 'checkout', '-q', 'main' })
        write('a.txt', { 'ours' })
        run_git({ 'commit', '-qam', 'ours' })
        run_git({ 'checkout', '-q', 'feature' })
        helpers.run({ 'sh', '-c', 'git rebase main || true' }, repo)

        local split, err = git.split_diff(conflict_entry(), 'conflicts', repo)

        assert.is_nil(err)
        assert.are.equal('HEAD', split.left.title)
        assert.are.equal('REBASE_HEAD (feature)', split.right.title)
    end)

    it('keeps the deleted side empty and says so in its title', function()
        -- Deleted by us: stage 2 is missing, the worktree file is gone.
        run_git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', { 'theirs' })
        run_git({ 'commit', '-qam', 'theirs' })
        run_git({ 'checkout', '-q', 'main' })
        run_git({ 'rm', '-q', 'a.txt' })
        run_git({ 'commit', '-qm', 'ours deletes' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)

        local entry = conflict_entry()
        assert.are.same({ 'D', 'U' }, { entry.staged, entry.unstaged })

        local split, err = git.split_diff(entry, 'conflicts', repo)

        assert.is_nil(err)
        assert.are.equal('HEAD (main) (deleted)', split.left.title)
        assert.are.equal('MERGE_HEAD (feature)', split.right.title)
        assert.are.same({}, split.left.lines)
        assert.are.same({ 'theirs' }, split.right.lines)
        helpers.assert_has_line_containing(split.diff_lines, '+theirs')
    end)

    it('reads both stages of an add/add conflict', function()
        run_git({ 'checkout', '-q', '-b', 'feature' })
        write('c.txt', { 'theirs' })
        run_git({ 'add', 'c.txt' })
        run_git({ 'commit', '-qm', 'theirs adds' })
        run_git({ 'checkout', '-q', 'main' })
        write('c.txt', { 'ours' })
        run_git({ 'add', 'c.txt' })
        run_git({ 'commit', '-qm', 'ours adds' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)

        local split, err = git.split_diff(
            helpers.entry_by_path(git.status(), 'c.txt'),
            'conflicts',
            repo
        )

        assert.is_nil(err)
        assert.are.same({ 'ours' }, split.left.lines)
        assert.are.same({ 'theirs' }, split.right.lines)
    end)

    it('shows submodule stages as commit ids, not their trees', function()
        local tree = vim.trim(run_git({ 'rev-parse', 'HEAD^{tree}' }))
        local commits = {}

        for index = 1, 3 do
            commits[index] = vim.trim(run_git({
                'commit-tree',
                tree,
                '-m',
                'submodule ' .. index,
            }))
        end

        local info = vim.fn.tempname()
        helpers.write_file(info, {
            '160000 ' .. commits[1] .. ' 1\tsub',
            '160000 ' .. commits[2] .. ' 2\tsub',
            '160000 ' .. commits[3] .. ' 3\tsub',
        })
        helpers.run({
            'sh',
            '-c',
            'git update-index --index-info < ' .. vim.fn.shellescape(info),
        }, repo)

        local split, err = git.split_diff(
            helpers.entry_by_path(git.status(), 'sub'),
            'conflicts',
            repo
        )

        assert.is_nil(err)
        assert.are.same(
            { 'Subproject commit ' .. commits[2] },
            split.left.lines
        )
        assert.are.same(
            { 'Subproject commit ' .. commits[3] },
            split.right.lines
        )
        helpers.assert_has_line_containing(
            split.diff_lines,
            '-Subproject commit ' .. commits[2]
        )
        helpers.assert_has_line_containing(
            split.diff_lines,
            '+Subproject commit ' .. commits[3]
        )
    end)

    it('titles both merge sides from refs', function()
        merge_conflict({ 'ours' }, { 'theirs' })

        assert.are.same(
            { left = 'HEAD (main)', right = 'MERGE_HEAD (feature)' },
            git.conflict_side_titles(conflict_entry(), repo)
        )
    end)

    it('titles both merge sides from refs asynchronously', function()
        merge_conflict({ 'ours' }, { 'theirs' })
        local titles

        git.conflict_side_titles_async(conflict_entry(), repo, function(result)
            titles = result
        end)

        assert.is_true(vim.wait(2000, function()
            return titles ~= nil
        end, 10))
        assert.are.same(
            { left = 'HEAD (main)', right = 'MERGE_HEAD (feature)' },
            titles
        )
    end)

    it('suffixes a side that has no stage blob', function()
        -- Deleted by us: stage 2 is missing, so the title says so.
        run_git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', { 'theirs' })
        run_git({ 'commit', '-qam', 'theirs' })
        run_git({ 'checkout', '-q', 'main' })
        run_git({ 'rm', '-q', 'a.txt' })
        run_git({ 'commit', '-qm', 'ours deletes' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)

        assert.are.same(
            { left = 'HEAD (main) (deleted)', right = 'MERGE_HEAD (feature)' },
            git.conflict_side_titles(conflict_entry(), repo)
        )
    end)

    it('has nothing to show for a conflict deleted on both sides', function()
        local hash = vim.trim(run_git({ 'rev-parse', 'HEAD:a.txt' }))
        run_git({ 'rm', '-q', 'a.txt' })
        local info = vim.fn.tempname()
        helpers.write_file(info, { '100644 ' .. hash .. ' 1\ta.txt' })
        helpers.run({
            'sh',
            '-c',
            'git update-index --index-info < ' .. vim.fn.shellescape(info),
        }, repo)

        local split, err = git.split_diff(conflict_entry(), 'conflicts', repo)

        assert.is_nil(split)
        assert.are.equal('Conflict has no sides to diff', err)
    end)
end)
