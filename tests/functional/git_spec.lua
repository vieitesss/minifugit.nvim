---@diagnostic disable: undefined-field
---@type table
local git = require('minifugit.git')
---@type MinifugitTestHelpers
local helpers = dofile(vim.fn.getcwd() .. '/tests/helpers.lua')

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
