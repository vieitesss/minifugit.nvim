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

    before_each(function()
        original_cwd = vim.fn.getcwd()
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
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

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
