---@diagnostic disable: undefined-field
---@type table
local git = require('minifugit.git')
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

---@param entries GitStatusEntry[]
---@param path string
---@return GitStatusEntry?
local function entry_by_path(entries, path)
    for _, entry in ipairs(entries) do
        if entry.path == path then
            return entry
        end
    end
end

describe('minifugit.git', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type string?
    local other_repo
    local original_git_dir
    local original_git_work_tree

    before_each(function()
        original_cwd = vim.fn.getcwd()
        other_repo = nil
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
    end)

    local function change_to_other_repo()
        other_repo = helpers.clone_repo_with_changed_file(
            repo,
            'tracked.txt',
            { 'changed in B' }
        )
        helpers.run({ 'git', 'checkout', '-b', 'other' }, other_repo)
        vim.cmd.cd(vim.fn.fnameescape(other_repo))
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
            local entry = entry_by_path(git.status(), name)
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
        local tracked = entry_by_path(snapshot.entries, 'tracked.txt')
        ---@type GitStatusEntry?
        local staged = entry_by_path(snapshot.entries, 'staged.txt')
        ---@type GitStatusEntry?
        local untracked = entry_by_path(snapshot.entries, 'untracked.txt')

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
            entry_by_path(entries, 'new-dir/file.txt')
        )
        assert.are.same({
            staged = '?',
            unstaged = '?',
            path = 'new-dir/inner-dir/nested.txt',
        }, entry_by_path(entries, 'new-dir/inner-dir/nested.txt'))
        assert.is_nil(entry_by_path(entries, 'new-dir/'))
    end)

    it('previews a diff for an untracked file', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'new-dir/file.txt'),
            { 'new content' }
        )

        local entry = entry_by_path(git.status(), 'new-dir/file.txt')
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

        local entry = entry_by_path(git.status(), 'intent.txt')
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
            local tracked = entry_by_path(git.status(), 'tracked.txt')
            local ok = git.stage(tracked)
            assert.is_true(ok)
            assert.are.equal(
                'M',
                entry_by_path(git.status(), 'tracked.txt').staged
            )

            ok = git.unstage(entry_by_path(git.status(), 'tracked.txt'))
            assert.is_true(ok)
            assert.are.equal(
                ' ',
                entry_by_path(git.status(), 'tracked.txt').staged
            )

            ok = git.discard_unstaged_entries({
                entry_by_path(git.status(), 'tracked.txt'),
            })
            assert.is_true(ok)
            assert.is_nil(entry_by_path(git.status(), 'tracked.txt'))

            ok = git.discard_untracked_entries({
                entry_by_path(git.status(), 'untracked.txt'),
            })
            assert.is_true(ok)
            assert.is_nil(entry_by_path(git.status(), 'untracked.txt'))
        end
    )

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
                local entry = entry_by_path(git.status(repo), paths.path)
                local ok, err = git.stage_entries({ entry }, repo)

                assert.is_true(ok, err)
                local entries = git.status(repo)
                assert.are.equal('A', entry_by_path(entries, paths.path).staged)
                assert.are.equal(
                    '?',
                    entry_by_path(entries, paths.unrelated).staged
                )
            end)

            it('unstages only selected entries', function()
                helpers.run({ 'git', 'add', '.' }, repo)
                local entry = entry_by_path(git.status(repo), paths.path)
                local ok, err = git.unstage_entries({ entry }, repo)

                assert.is_true(ok, err)
                local entries = git.status(repo)
                assert.are.equal('?', entry_by_path(entries, paths.path).staged)
                assert.are.equal(
                    'A',
                    entry_by_path(entries, paths.unrelated).staged
                )
            end)

            it('discards only selected untracked entries', function()
                local entry = entry_by_path(git.status(repo), paths.path)
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
                    local entry = entry_by_path(git.status(repo), paths.path)
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
