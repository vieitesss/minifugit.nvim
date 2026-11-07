---@diagnostic disable: undefined-field
local helpers = dofile('tests/helpers.lua')
local git = require('minifugit.git')

describe('base revision git API', function()
    local repo
    local original_cwd
    local base

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo, base = helpers.create_repo({
            ['tracked.txt'] = { 'base text' },
        })
    end)

    after_each(function()
        vim.cmd.cd(original_cwd)
        vim.fn.delete(repo, 'rf')
    end)

    it(
        'collects tracked changes and non-ignored untracked files without duplicating staged additions',
        function()
            helpers.write_file(repo .. '/tracked.txt', { 'committed text' })
            helpers.write_file(repo .. '/added.txt', { 'added' })
            helpers.write_file(repo .. '/.gitignore', { 'ignored.txt' })
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'changes' }, repo)
            helpers.write_file(repo .. '/tracked.txt', { 'working text' })
            helpers.write_file(repo .. '/untracked.txt', { 'untracked' })
            helpers.write_file(repo .. '/ignored.txt', { 'ignored' })
            helpers.write_file(repo .. '/staged.txt', { 'staged addition' })
            helpers.run({ 'git', 'add', 'staged.txt' }, repo)
            local entries, err = git.base_entries(base, repo)
            assert.is_nil(err)
            assert.are.same({
                { staged = ' ', unstaged = 'A', path = '.gitignore' },
                { staged = ' ', unstaged = 'A', path = 'added.txt' },
                { staged = ' ', unstaged = 'A', path = 'staged.txt' },
                { staged = ' ', unstaged = 'M', path = 'tracked.txt' },
                { staged = '?', unstaged = '?', path = 'untracked.txt' },
            }, entries)
        end
    )

    -- Windows does not allow control characters in file names.
    local unix_it = vim.fn.has('win32') == 1 and pending or it
    unix_it('keeps tracked and untracked CRLF base entry paths', function()
        local tracked = 'tracked\r\nbreak.txt'
        local untracked = 'untracked\r\nbreak.txt'
        helpers.write_file(repo .. '/' .. tracked, { 'original' })
        helpers.run({ 'git', 'add', '--', tracked }, repo)
        helpers.run({ 'git', 'commit', '-m', 'track CRLF filename' }, repo)
        base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
        helpers.write_file(repo .. '/' .. tracked, { 'changed' })
        helpers.write_file(repo .. '/' .. untracked, { 'new' })

        local entries, err = git.base_entries(base, repo)

        assert.is_nil(err)
        assert.are.same({
            { staged = ' ', unstaged = 'M', path = tracked },
            { staged = '?', unstaged = '?', path = untracked },
        }, entries)
    end)

    it(
        'keeps copies as additions regardless of rename configuration',
        function()
            helpers.write_file(repo .. '/copy.txt', { 'base text' })
            helpers.write_file(repo .. '/tracked.txt', { 'base text', 'extra' })
            helpers.run({ 'git', 'add', '.' }, repo)

            for _, settings in ipairs({
                { diff = 'copies', status = 'true' },
                { diff = 'true', status = 'copies' },
                { diff = 'copies', status = 'copies' },
            }) do
                helpers.run(
                    { 'git', 'config', 'diff.renames', settings.diff },
                    repo
                )
                helpers.run(
                    { 'git', 'config', 'status.renames', settings.status },
                    repo
                )
                local entries, err = git.base_entries(base, repo)
                assert.is_nil(err)
                assert.are.same({
                    { staged = ' ', unstaged = 'A', path = 'copy.txt' },
                    { staged = ' ', unstaged = 'M', path = 'tracked.txt' },
                }, entries)
            end
        end
    )

    it(
        'builds one patch containing committed and uncommitted changes from the base',
        function()
            helpers.write_file(repo .. '/tracked.txt', { 'committed text' })
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'modify' }, repo)
            helpers.write_file(
                repo .. '/tracked.txt',
                { 'committed text', 'uncommitted text' }
            )
            local patch, err = git.base_diff(
                { path = 'tracked.txt', staged = ' ', unstaged = 'M' },
                base,
                repo
            )
            assert.is_nil(err)
            assert.is_true(vim.tbl_contains(patch, '-base text'))
            assert.is_true(vim.tbl_contains(patch, '+committed text'))
            assert.is_true(vim.tbl_contains(patch, '+uncommitted text'))
        end
    )

    for _, paths in ipairs({
        {
            path = ':(literal)report.txt',
            unrelated = 'report.txt',
            renamed = ':(literal)renamed.txt',
            other_renamed = 'renamed.txt',
        },
        {
            path = 'star*.txt',
            unrelated = 'star-other.txt',
            renamed = 'renamed*.txt',
            other_renamed = 'renamed-other.txt',
        },
    }) do
        describe('literal filename ' .. paths.path, function()
            before_each(function()
                helpers.write_file(
                    repo .. '/' .. paths.path,
                    { 'selected base' }
                )
                for _, path in ipairs({ paths.unrelated, paths.other_renamed }) do
                    helpers.write_file(
                        repo .. '/' .. path,
                        { 'unrelated base' }
                    )
                end
                helpers.run({ 'git', 'add', '.' }, repo)
                helpers.run(
                    { 'git', 'commit', '-m', 'special filenames' },
                    repo
                )
                base =
                    vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            end)

            it('previews only the selected file from the base', function()
                helpers.write_file(
                    repo .. '/' .. paths.path,
                    { 'selected change' }
                )
                helpers.write_file(
                    repo .. '/' .. paths.unrelated,
                    { 'unrelated change' }
                )

                local patch, err = git.base_diff(
                    { path = paths.path, staged = ' ', unstaged = 'M' },
                    base,
                    repo
                )

                assert.is_nil(err)
                assert.is_true(vim.tbl_contains(patch, '-selected base'))
                assert.is_true(vim.tbl_contains(patch, '+selected change'))
                assert.is_false(vim.tbl_contains(patch, '+unrelated change'))
            end)

            it('previews both rename paths literally from the base', function()
                helpers.run(
                    { 'git', 'mv', '--', paths.path, paths.renamed },
                    repo
                )
                for _, path in ipairs({ paths.unrelated, paths.other_renamed }) do
                    helpers.write_file(
                        repo .. '/' .. path,
                        { 'unrelated change' }
                    )
                end

                local patch, err = git.base_diff({
                    path = paths.renamed,
                    orig_path = paths.path,
                    staged = ' ',
                    unstaged = 'R',
                }, base, repo)

                assert.is_nil(err)
                assert.is_true(
                    vim.tbl_contains(patch, 'rename from ' .. paths.path)
                )
                assert.is_true(
                    vim.tbl_contains(patch, 'rename to ' .. paths.renamed)
                )
                assert.is_false(vim.tbl_contains(patch, '+unrelated change'))
            end)
        end)
    end

    it(
        'builds split sides from the base blob and working tree, not HEAD or index',
        function()
            helpers.write_file(repo .. '/tracked.txt', { 'committed text' })
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'modify' }, repo)
            helpers.write_file(repo .. '/tracked.txt', { 'working text' })
            local diff, err = git.base_split_diff(
                { path = 'tracked.txt', staged = ' ', unstaged = 'M' },
                base,
                repo
            )
            assert.is_nil(err)
            assert.are.same({ 'base text' }, diff.left.lines)
            assert.are.same({ 'working text' }, diff.right.lines)
            assert.are.equal(base .. ':tracked.txt', diff.left.title)
            assert.are.equal('worktree:tracked.txt', diff.right.title)
        end
    )

    it(
        'rejects unknown, empty and option-like revisions with string errors',
        function()
            for _, revision in ipairs({ 'missing', '', '-h', '--all' }) do
                local hash, err = git.resolve_commit(revision, repo)
                assert.is_nil(hash)
                assert.are.equal('Invalid base revision: ' .. revision, err)
            end
        end
    )

    it(
        'keeps rename origins and unusual filenames in the existing entry shape',
        function()
            helpers.run(
                { 'git', 'mv', 'tracked.txt', 'renamed name.txt' },
                repo
            )
            helpers.write_file(repo .. '/tab\tname.txt', { 'untracked' })
            helpers.run({ 'git', 'commit', '-m', 'rename' }, repo)
            vim.cmd.cd(repo)
            local entries, err = git.base_entries(base)
            assert.is_nil(err)
            assert.are.same({
                {
                    staged = ' ',
                    unstaged = 'R',
                    orig_path = 'tracked.txt',
                    path = 'renamed name.txt',
                },
                { staged = '?', unstaged = '?', path = 'tab\tname.txt' },
            }, entries)
            local patch = git.base_diff(entries[1], base)
            assert.is_true(vim.tbl_contains(patch, 'rename from tracked.txt'))
            assert.is_true(
                vim.tbl_contains(patch, 'rename to renamed name.txt')
            )
            local diff = git.base_split_diff(entries[1], base)
            assert.are.same({ 'base text' }, diff.left.lines)
            assert.are.same({ 'base text' }, diff.right.lines)
        end
    )

    it(
        'builds added, deleted and untracked preview sides without missing-blob errors',
        function()
            helpers.write_file(repo .. '/added.txt', { 'added content' })
            helpers.run({ 'git', 'rm', 'tracked.txt' }, repo)
            helpers.run({ 'git', 'add', 'added.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add and delete' }, repo)
            helpers.write_file(
                repo .. '/untracked.txt',
                { 'untracked content' }
            )
            local entries = git.base_entries(base, repo)
            local by_path = {}
            for _, entry in ipairs(entries) do
                by_path[entry.path] = entry
            end
            local added, add_err =
                git.base_split_diff(by_path['added.txt'], base, repo)
            assert.is_nil(add_err)
            assert.are.same({}, added.left.lines)
            assert.are.same({ 'added content' }, added.right.lines)
            local deleted, delete_err =
                git.base_split_diff(by_path['tracked.txt'], base, repo)
            assert.is_nil(delete_err)
            assert.are.same({ 'base text' }, deleted.left.lines)
            assert.are.same({}, deleted.right.lines)
            local untracked, untracked_err =
                git.base_split_diff(by_path['untracked.txt'], base, repo)
            assert.is_nil(untracked_err)
            assert.are.same({}, untracked.left.lines)
            assert.are.same({ 'untracked content' }, untracked.right.lines)
            assert.is_true(
                vim.tbl_contains(
                    git.base_diff(by_path['untracked.txt'], base, repo),
                    '+untracked content'
                )
            )
        end
    )

    it(
        'resolves a revision to its full commit in the requested root',
        function()
            local hash, err = git.resolve_commit('HEAD', repo)
            assert.is_nil(err)
            assert.are.equal(base, hash)
            vim.cmd.cd(repo)
            assert.are.equal(base, git.resolve_commit('HEAD'))
        end
    )
end)
