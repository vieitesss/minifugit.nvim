---@diagnostic disable: undefined-field
local helpers = dofile('tests/helpers.lua')
local git = require('minifugit.git')

describe('base revision git API', function()
    local repo
    local original_cwd
    local base
    local extra_repos

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo, base = helpers.create_repo({
            ['tracked.txt'] = { 'base text' },
        })
        extra_repos = {}
    end)

    after_each(function()
        vim.cmd.cd(original_cwd)
        vim.fn.delete(repo, 'rf')
        for _, path in ipairs(extra_repos) do
            vim.fn.delete(path, 'rf')
        end
    end)

    ---Create a submodule source repository with two commits.
    ---@return string sub_repo
    ---@return string first
    ---@return string second
    local function create_sub_repo()
        local sub_repo, first =
            helpers.create_repo({ ['sub.txt'] = { 'sub content' } })
        helpers.run(
            { 'git', 'commit', '--allow-empty', '-m', 'second' },
            sub_repo
        )
        local second =
            vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, sub_repo))
        table.insert(extra_repos, sub_repo)
        return sub_repo, first, second
    end

    ---@param path string
    ---@param sub_repo string
    local function add_submodule(path, sub_repo)
        helpers.run({
            'git',
            '-c',
            'protocol.file.allow=always',
            'submodule',
            'add',
            sub_repo,
            path,
        }, repo)
    end

    ---Write exact bytes: `helpers.write_file` always ends the file with a NL.
    ---@param path string
    ---@param contents string
    local function write_raw(path, contents)
        local file = assert(vim.uv.fs_open(path, 'w', 420))
        assert(vim.uv.fs_write(file, contents, 0))
        assert(vim.uv.fs_close(file))
    end

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
        'merges a cached deletion and its untracked file into one modified entry',
        function()
            helpers.run({ 'git', 'rm', '--cached', 'tracked.txt' }, repo)
            helpers.write_file(repo .. '/tracked.txt', { 'worktree text' })

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            assert.are.same({
                { staged = ' ', unstaged = 'M', path = 'tracked.txt' },
            }, entries)
        end
    )

    it(
        'previews a merged cached deletion from the base blob to the worktree file',
        function()
            helpers.run({ 'git', 'rm', '--cached', 'tracked.txt' }, repo)
            helpers.write_file(repo .. '/tracked.txt', { 'worktree text' })
            local entries = select(1, git.base_entries(base, repo))
            local entry = entries[1]

            local patch, err = git.base_diff(entry, base, repo)

            assert.is_nil(err)
            helpers.assert_has_line_containing(patch, '-base text')
            helpers.assert_has_line_containing(patch, '+worktree text')
            assert.is_true(vim.tbl_contains(patch, '--- a/tracked.txt'))
            assert.is_true(vim.tbl_contains(patch, '+++ b/tracked.txt'))
            assert.is_true(
                vim.tbl_contains(
                    patch,
                    'diff --git a/tracked.txt b/tracked.txt'
                )
            )

            local diff, split_err = git.base_split_diff(entry, base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'base text' }, diff.left.lines)
            assert.are.same({ 'worktree text' }, diff.right.lines)
        end
    )

    it(
        'keeps a cached deletion of a file without a final newline unchanged',
        function()
            write_raw(repo .. '/no-newline.txt', 'single line')
            helpers.run({ 'git', 'add', 'no-newline.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add no-newline file' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', 'rm', '--cached', 'no-newline.txt' }, repo)

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            local entry = entry_by_path(entries, 'no-newline.txt')
            assert.are.same(
                { staged = ' ', unstaged = 'M', path = 'no-newline.txt' },
                entry
            )

            local patch, patch_err = git.base_diff(entry, base, repo)

            assert.is_nil(patch_err)
            assert.are.same({}, patch)

            local diff, split_err = git.base_split_diff(entry, base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'single line' }, diff.left.lines)
            assert.are.same({ 'single line' }, diff.right.lines)
        end
    )

    it(
        'keeps a cached deletion of a CRLF file unchanged and still diffs an edit',
        function()
            local path = repo .. '/crlf.txt'
            write_raw(path, 'first line\r\nsecond line\r\n')
            helpers.run({ 'git', 'add', 'crlf.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add CRLF file' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', 'rm', '--cached', 'crlf.txt' }, repo)

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            local entry = entry_by_path(entries, 'crlf.txt')
            assert.are.same(
                { staged = ' ', unstaged = 'M', path = 'crlf.txt' },
                entry
            )

            local patch, patch_err = git.base_diff(entry, base, repo)

            assert.is_nil(patch_err)
            assert.are.same({}, patch)

            write_raw(path, 'first line\r\nchanged line\r\n')

            patch, patch_err = git.base_diff(entry, base, repo)

            assert.is_nil(patch_err)
            helpers.assert_has_line_containing(patch, '-second line')
            helpers.assert_has_line_containing(patch, '+changed line')
        end
    )

    unix_it(
        'quotes a cached deletion of a newline path in the patch header',
        function()
            local name = 'new\nline.txt'
            local path = repo .. '/' .. name
            write_raw(path, 'path content')
            helpers.run({ 'git', 'add', '--', name }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add newline path' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', 'rm', '--cached', '--', name }, repo)
            write_raw(path, 'edited content')

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            local entry = entry_by_path(entries, name)
            assert.are.same(
                { staged = ' ', unstaged = 'M', path = name },
                entry
            )

            local patch, patch_err = git.base_diff(entry, base, repo)

            assert.is_nil(patch_err)
            assert.is_true(
                vim.tbl_contains(
                    patch,
                    'diff --git "a/new\\nline.txt" "b/new\\nline.txt"'
                )
            )
            helpers.assert_has_line_containing(patch, '+edited content')
            for _, line in ipairs(patch) do
                assert.is_nil(line:find('\n', 1, true))
                assert.is_nil(line:find(repo, 1, true))
            end
        end
    )

    unix_it(
        'keeps a cached deletion of an executable file unchanged',
        function()
            local path = repo .. '/script.sh'
            write_raw(path, '#!/bin/sh\necho hi\n')
            assert.is_true(vim.uv.fs_chmod(path, 493))
            helpers.run({ 'git', 'add', 'script.sh' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add script' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', 'rm', '--cached', 'script.sh' }, repo)

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            local entry = entry_by_path(entries, 'script.sh')
            assert.are.same(
                { staged = ' ', unstaged = 'M', path = 'script.sh' },
                entry
            )

            local patch, patch_err = git.base_diff(entry, base, repo)

            assert.is_nil(patch_err)
            assert.are.same({}, patch)

            local diff, split_err = git.base_split_diff(entry, base, repo)

            assert.is_nil(split_err)
            assert.are.same({ '#!/bin/sh', 'echo hi' }, diff.left.lines)
            assert.are.same({ '#!/bin/sh', 'echo hi' }, diff.right.lines)
        end
    )

    unix_it(
        'reads a symlink target as the worktree side of base split previews',
        function()
            helpers.write_file(repo .. '/target.txt', { 'target content' })
            helpers.run({ 'git', 'add', 'target.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add target' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            vim.fn.delete(repo .. '/tracked.txt')
            assert.is_not_nil(
                vim.uv.fs_symlink('target.txt', repo .. '/tracked.txt')
            )

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            assert.are.same({
                { staged = ' ', unstaged = 'T', path = 'tracked.txt' },
            }, entries)

            local diff, split_err = git.base_split_diff(entries[1], base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'base text' }, diff.left.lines)
            assert.are.same({ 'target.txt' }, diff.right.lines)
        end
    )

    unix_it(
        'splits a newline-bearing symlink target into buffer-safe lines',
        function()
            helpers.write_file(repo .. '/target.txt', { 'target content' })
            helpers.run({ 'git', 'add', 'target.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add target' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            vim.fn.delete(repo .. '/tracked.txt')
            assert.is_not_nil(
                vim.uv.fs_symlink('missing\ntarget.txt', repo .. '/tracked.txt')
            )

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            assert.are.same({
                { staged = ' ', unstaged = 'T', path = 'tracked.txt' },
            }, entries)

            local diff, split_err = git.base_split_diff(entries[1], base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'base text' }, diff.left.lines)
            assert.are.same({ 'missing', 'target.txt' }, diff.right.lines)
        end
    )

    it(
        'previews a submodule from the base commit id to its checked-out HEAD',
        function()
            local sub_repo, first, second = create_sub_repo()
            add_submodule('sub', sub_repo)
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', first }, repo)
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add submodule' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            assert.are.same({
                { staged = ' ', unstaged = 'M', path = 'sub' },
            }, entries)

            local diff, split_err = git.base_split_diff(entries[1], base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'Subproject commit ' .. first }, diff.left.lines)
            assert.are.same(
                { 'Subproject commit ' .. second },
                diff.right.lines
            )
        end
    )

    it('reads the submodule HEAD after the parent root is pinned', function()
        local sub_repo, first, second = create_sub_repo()
        add_submodule('sub', sub_repo)
        helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', first }, repo)
        helpers.run({ 'git', 'add', '.' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'add submodule' }, repo)
        base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
        helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)

        local root = git.root(repo)
        assert.are.not_equal('', root)

        local entries, err = git.base_entries(base, root)

        assert.is_nil(err)
        local entry = entry_by_path(entries, 'sub')
        assert.are.same({ staged = ' ', unstaged = 'M', path = 'sub' }, entry)

        local diff, split_err = git.base_split_diff(entry, base, root)

        assert.is_nil(split_err)
        assert.are.same({ 'Subproject commit ' .. first }, diff.left.lines)
        assert.are.same({ 'Subproject commit ' .. second }, diff.right.lines)
    end)

    it(
        'shows a placeholder for an unchecked-out submodule worktree side',
        function()
            local sub_repo, first, second = create_sub_repo()
            add_submodule('sub', sub_repo)
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', first }, repo)
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add submodule' }, repo)
            base = vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD' }, repo))
            helpers.run({ 'git', '-C', 'sub', 'checkout', '-q', second }, repo)
            helpers.run({ 'git', 'add', 'sub' }, repo)
            helpers.run(
                { 'git', 'submodule', 'deinit', '-f', '--', 'sub' },
                repo
            )

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            assert.are.same(
                { { staged = ' ', unstaged = 'M', path = 'sub' } },
                entries
            )

            local diff, split_err = git.base_split_diff(entries[1], base, repo)

            assert.is_nil(split_err)
            assert.are.same({ 'Subproject commit ' .. first }, diff.left.lines)
            assert.are.same(
                { 'Subproject commit (not checked out)' },
                diff.right.lines
            )
        end
    )

    it(
        'previews a submodule added since the base from its worktree HEAD',
        function()
            local sub_repo, _, second = create_sub_repo()
            add_submodule('sub', sub_repo)
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add submodule' }, repo)

            local entries, err = git.base_entries(base, repo)

            assert.is_nil(err)
            local entry
            for _, candidate in ipairs(entries) do
                if candidate.path == 'sub' then
                    entry = candidate
                end
            end
            assert.are.same(
                { staged = ' ', unstaged = 'A', path = 'sub' },
                entry
            )

            local diff, split_err = git.base_split_diff(entry, base, repo)

            assert.is_nil(split_err)
            assert.are.same({}, diff.left.lines)
            assert.are.same(
                { 'Subproject commit ' .. second },
                diff.right.lines
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
