---@diagnostic disable: undefined-field
local helpers = dofile('tests/helpers.lua')

local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function keys(value)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(value, true, false, true),
        'mx',
        false
    )
end

local function select_entry(buf, path)
    for row, line in ipairs(lines(buf)) do
        if line:find(path, 1, true) then
            vim.api.nvim_set_current_buf(buf)
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            return
        end
    end
    error('Missing entry: ' .. path)
end

local function diff_window(name)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if
            vim.fs
                .basename(vim.api.nvim_buf_get_name(buf))
                :match('^(.-) %[%d+%]$') == name
        then
            return win, buf
        end
    end
    error('Missing preview: ' .. name)
end

local function hide_status_buffer(status_win)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= status_win then
            vim.api.nvim_win_set_buf(status_win, vim.api.nvim_win_get_buf(win))
            return
        end
    end
end

describe('read-only base mode UI', function()
    local repo
    local base
    local minifugit
    local original_cwd
    local original_notify
    local notifications

    local function run(args)
        return helpers.run(vim.list_extend({ 'git' }, args), repo)
    end

    local function write(path, contents)
        helpers.write_file(repo .. '/' .. path, contents)
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        original_notify = vim.notify
        notifications = {}
        vim.notify = function(message)
            table.insert(notifications, message)
        end
        repo, base = helpers.create_repo({
            ['modified.txt'] = { 'base first', 'base second', 'unchanged' },
            ['deleted.txt'] = { 'delete me' },
            ['old.txt'] = { 'rename me', 'unchanged rename content' },
            ['.gitignore'] = { 'ignored.txt' },
        })
        vim.cmd.cd(repo)
        vim.cmd.enew()
        package.loaded.minifugit = nil
        minifugit = require('minifugit').setup({
            status = { width = 0.5 },
            preview = { show_line_numbers = false },
        })
    end)

    after_each(function()
        minifugit.reset()
        vim.cmd('silent! tabonly!')
        vim.cmd('silent! only!')
        vim.cmd('%bwipeout!')
        vim.cmd.cd(original_cwd)
        vim.notify = original_notify
        vim.fn.delete(repo, 'rf')
    end)

    local function changes_since_base()
        write('modified.txt', { 'committed first', 'base second', 'unchanged' })
        run({ 'add', 'modified.txt' })
        run({ 'commit', '-m', 'modify' })
        run({ 'rm', 'deleted.txt' })
        run({ 'commit', '-m', 'delete' })
        run({ 'mv', 'old.txt', 'renamed.txt' })
        run({ 'commit', '-m', 'rename' })
        -- NUL bytes make Git classify this as binary.
        vim.fn.writefile(
            vim.fn.list2blob({ 98, 0, 105, 110 }),
            repo .. '/binary.bin'
        )
        run({ 'add', 'binary.bin' })
        run({ 'commit', '-m', 'binary' })
        write(
            'modified.txt',
            { 'committed first', 'uncommitted second', 'unchanged' }
        )
        write('untracked.txt', { 'new untracked content' })
        write('ignored.txt', { 'must not appear' })
    end

    it(
        'lists the whole branch and worktree with markers and a read-only pinned header',
        function()
            changes_since_base()
            assert.is_true(minifugit.open({ cwd = repo, base = base }))
            local buf = vim.api.nvim_get_current_buf()
            local text = lines(buf)
            helpers.assert_has_line_containing(
                text,
                'Base: ' .. base:sub(1, 7) .. ' (read-only)'
            )
            helpers.assert_has_line_containing(
                text,
                'Changes since ' .. base:sub(1, 7) .. ' (5)'
            )
            assert.is_true(vim.tbl_contains(text, ' A binary.bin'))
            assert.is_true(vim.tbl_contains(text, ' D deleted.txt'))
            assert.is_true(vim.tbl_contains(text, ' M modified.txt'))
            assert.is_true(vim.tbl_contains(text, ' R old.txt -> renamed.txt'))
            assert.is_true(vim.tbl_contains(text, '?? untracked.txt'))
            for _, line in ipairs(text) do
                assert.is_nil(line:find('Unpushed', 1, true))
                assert.is_nil(line:find('ignored.txt', 1, true))
                assert.is_nil(line:find('Staged', 1, true))
                assert.is_nil(line:find('Unstaged', 1, true))
            end
            assert.are.equal('minifugit', vim.bo[buf].filetype)
            assert.is_false(vim.bo[buf].modifiable)
        end
    )

    it(
        'previews committed and uncommitted edits together in the stacked layout',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'modified.txt')
            keys('=')
            local _, preview = diff_window('Minifugit diff')
            assert.are.equal(status, vim.api.nvim_get_current_buf())
            assert.is_true(vim.tbl_contains(lines(preview), 'base first'))
            assert.is_true(vim.tbl_contains(lines(preview), 'base second'))
            assert.is_true(vim.tbl_contains(lines(preview), 'committed first'))
            assert.is_true(
                vim.tbl_contains(lines(preview), 'uncommitted second')
            )
        end
    )

    it(
        'previews committed and uncommitted edits together in split and restores the target after layout toggles',
        function()
            changes_since_base()
            local target = vim.api.nvim_get_current_win()
            local original_buf = vim.api.nvim_get_current_buf()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'modified.txt')
            keys('al=')
            local left_win, left = diff_window('Minifugit diff left')
            local _, right = diff_window('Minifugit diff right')
            assert.are.equal(target, left_win)
            assert.is_true(vim.tbl_contains(lines(left), 'base first'))
            assert.is_true(vim.tbl_contains(lines(left), 'base second'))
            assert.is_true(vim.tbl_contains(lines(right), 'committed first'))
            assert.is_true(vim.tbl_contains(lines(right), 'uncommitted second'))
            assert.are.equal(status, vim.api.nvim_get_current_buf())
            keys('al')
            local preview_win = diff_window('Minifugit diff')
            vim.api.nvim_set_current_win(preview_win)
            keys('q')
            assert.are.equal(original_buf, vim.api.nvim_win_get_buf(target))
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        end
    )

    it(
        'blocks all repository-changing status keymaps and preserves status, index and worktree',
        function()
            changes_since_base()
            write('staged.txt', { 'keep staged' })
            run({ 'add', 'staged.txt' })
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            local before = run({ 'status', '--porcelain=v1' })
            local index = run({ 'ls-files', '--stage' })
            local head = run({ 'rev-parse', 'HEAD' })
            local message = '[minifugit] read-only: changes since '
                .. base:sub(1, 7)
            for _, key in ipairs({
                's',
                'u',
                'S',
                'U',
                'd',
                'D',
                'c',
                'p',
                'V s',
                'V u',
            }) do
                select_entry(status, 'modified.txt')
                keys(key)
                keys('<Esc>')
                assert.are.equal(message, notifications[#notifications], key)
                assert.are.equal(
                    before,
                    run({ 'status', '--porcelain=v1' }),
                    key
                )
                assert.are.equal(index, run({ 'ls-files', '--stage' }), key)
                assert.are.equal(head, run({ 'rev-parse', 'HEAD' }), key)
                assert.are.equal(status, vim.api.nvim_get_current_buf(), key)
            end
            assert.are.same(
                { 'committed first', 'uncommitted second', 'unchanged' },
                vim.fn.readfile(repo .. '/modified.txt')
            )
            assert.are.same(
                { 'new untracked content' },
                vim.fn.readfile(repo .. '/untracked.txt')
            )
        end
    )

    it(
        'blocks hunk actions in stacked and both split buffers without changing the repository',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'modified.txt')
            keys('=')
            local before = run({ 'status', '--porcelain=v1' })
            local index = run({ 'ls-files', '--stage' })
            local message = '[minifugit] read-only: changes since '
                .. base:sub(1, 7)
            local function check(preview_win)
                vim.api.nvim_set_current_win(preview_win)
                for _, key in ipairs({ 's', 'u', 'd' }) do
                    keys(key)
                    assert.are.equal(
                        message,
                        notifications[#notifications],
                        key
                    )
                    assert.are.equal(
                        before,
                        run({ 'status', '--porcelain=v1' })
                    )
                    assert.are.equal(index, run({ 'ls-files', '--stage' }))
                end
            end
            check(diff_window('Minifugit diff'))
            keys('al')
            check(diff_window('Minifugit diff left'))
            check(diff_window('Minifugit diff right'))
        end
    )

    it(
        'destroys hidden normal status when reopened with an explicit base',
        function()
            changes_since_base()
            minifugit.open()
            local old = vim.api.nvim_get_current_buf()
            keys('q')
            assert.are.equal(0, #vim.fn.win_findbuf(old))
            minifugit.open({ base = base })
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'Changes since ' .. base:sub(1, 7)
            )
        end
    )

    it(
        'replaces visible normal status with an explicit base and runs its close callback',
        function()
            changes_since_base()
            local closed = 0
            minifugit.open({
                on_close = function()
                    closed = closed + 1
                end,
            })
            local old = vim.api.nvim_get_current_buf()
            minifugit.open({ base = base })
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            assert.is_true(vim.wait(1000, function()
                return closed == 1
            end))
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'Changes since ' .. base:sub(1, 7)
            )
        end
    )

    it(
        'replaces a visible same-root owned-tab candidate with an explicit different base',
        function()
            changes_since_base()
            local origin = vim.api.nvim_get_current_tabpage()
            local closed = 0
            minifugit.open({
                base = base,
                open_in_tab = true,
                on_close = function()
                    closed = closed + 1
                end,
            })
            local old = vim.api.nvim_get_current_buf()
            local owned = vim.api.nvim_get_current_tabpage()
            vim.api.nvim_set_current_tabpage(origin)
            minifugit.open({ base = 'HEAD', open_in_tab = true })
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            assert.is_false(vim.api.nvim_tabpage_is_valid(owned))
            assert.are.equal(2, #vim.api.nvim_list_tabpages())
            assert.is_true(vim.wait(1000, function()
                return closed == 1
            end))
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'Base: ' .. vim.trim(run({ 'rev-parse', 'HEAD' })):sub(1, 7)
            )
        end
    )

    it(
        'shows a binary placeholder in either requested layout even with metadata hidden',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'binary.bin')
            keys('am=')
            local _, preview = diff_window('Minifugit diff')
            assert.is_true(vim.tbl_contains(lines(preview), 'binary file'))
            keys('al')
            local _, split_placeholder = diff_window('Minifugit diff')
            assert.is_true(
                vim.tbl_contains(lines(split_placeholder), 'binary file')
            )
        end
    )

    it(
        'rejects empty and option-like base revisions without editor side effects',
        function()
            for _, revision in ipairs({ '', '-h', '--all' }) do
                local unchanged = helpers.snapshot_editor_state()
                local ok, err = minifugit.open({
                    cwd = repo,
                    base = revision,
                    open_in_tab = true,
                })
                assert.is_nil(ok)
                assert.are.equal('Invalid base revision: ' .. revision, err)
                unchanged()
            end
        end
    )

    it(
        'rejects base mode outside Git with explicit or omitted cwd without editor side effects',
        function()
            local outside = vim.fn.tempname()
            vim.fn.mkdir(outside, 'p')
            vim.cmd.cd(outside)
            for _, explicit in ipairs({ false, true }) do
                local unchanged = helpers.snapshot_editor_state()
                local ok, err = minifugit.open({
                    cwd = explicit and outside or nil,
                    base = 'HEAD',
                    open_in_tab = true,
                })
                assert.is_nil(ok)
                local expected_cwd = explicit
                        and vim.fs.normalize(vim.fn.fnamemodify(outside, ':p'))
                    or vim.fn.getcwd()
                assert.are.equal(
                    'Not inside a git repository: ' .. expected_cwd,
                    err
                )
                unchanged()
            end
            vim.cmd.cd(repo)
            vim.fn.delete(outside, 'rf')
        end
    )

    it(
        'validates the base option and constructor types before creating editor resources',
        function()
            local unchanged = helpers.snapshot_editor_state()
            assert.has_error(function()
                minifugit.open({ base = 123 })
            end)
            unchanged()
            local capture, restore = helpers.capture_status_windows()
            minifugit.open({ base = base })
            assert.is_not_nil(capture())
            local after_open = helpers.snapshot_editor_state()
            assert.has_error(function()
                require('minifugit.ui.status').new(minifugit.options, repo, 123)
            end)
            after_open()
            restore()
        end
    )

    it('keeps HEAD pinned when refresh follows a new commit', function()
        changes_since_base()
        local pinned = vim.trim(run({ 'rev-parse', 'HEAD' }))
        minifugit.open({ base = 'HEAD' })
        local buf = vim.api.nvim_get_current_buf()
        run({ 'add', 'modified.txt', 'untracked.txt' })
        run({ 'commit', '-m', 'after opening' })
        keys('r')
        local text = lines(buf)
        helpers.assert_has_line_containing(text, 'Base: ' .. pinned:sub(1, 7))
        assert.is_true(vim.tbl_contains(text, ' M modified.txt'))
        assert.is_true(vim.tbl_contains(text, ' A untracked.txt'))
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
    end)

    it(
        'shows the empty state for a clean base comparison without unpushed commits',
        function()
            minifugit.open({ base = 'HEAD' })
            local text = lines(vim.api.nvim_get_current_buf())
            assert.is_true(
                vim.tbl_contains(text, 'No changes since ' .. base:sub(1, 7))
            )
            for _, line in ipairs(text) do
                assert.is_nil(line:find('Unpushed', 1, true))
                assert.is_nil(line:find('Working tree clean', 1, true))
            end
        end
    )

    it(
        'keeps visible base status when base is omitted and refreshes equivalent revisions in place',
        function()
            changes_since_base()
            run({ 'tag', 'review-base', base })
            minifugit.open({ base = base })
            local buf = vim.api.nvim_get_current_buf()
            local win = vim.api.nvim_get_current_win()
            write('later.txt', { 'added after opening' })
            vim.cmd.wincmd('p')
            minifugit.open({ cwd = repo, base = 'review-base' })
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
            assert.are.equal(win, vim.api.nvim_get_current_win())
            assert.is_true(vim.tbl_contains(lines(buf), '?? later.txt'))
            minifugit.status()
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
            helpers.assert_has_line_containing(
                lines(buf),
                'Base: ' .. base:sub(1, 7)
            )
            keys('s')
            assert.are.equal(
                '[minifugit] read-only: changes since ' .. base:sub(1, 7),
                notifications[#notifications]
            )
        end
    )

    it(
        'recreates hidden base status as normal status when base is omitted',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local old = vim.api.nvim_get_current_buf()
            keys('q')
            minifugit.open()
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            local text = lines(vim.api.nvim_get_current_buf())
            assert.is_true(vim.tbl_contains(text, ' M modified.txt'))
            helpers.assert_has_line_containing(text, 'HEAD: main')
            helpers.assert_has_line_containing(text, 'Unstaged (1)')
            helpers.assert_has_line_containing(text, 'Unpushed')
            for _, line in ipairs(text) do
                assert.is_nil(line:find('read-only', 1, true))
            end
        end
    )

    it(
        'replaces hidden base status for a different hash but reuses an equivalent hidden pin',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local first = vim.api.nvim_get_current_buf()
            keys('q')
            minifugit.open({ base = base .. '^0' })
            assert.are.equal(first, vim.api.nvim_get_current_buf())
            keys('q')
            minifugit.open({ base = 'HEAD' })
            assert.is_false(vim.api.nvim_buf_is_valid(first))
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'Base: ' .. vim.trim(run({ 'rev-parse', 'HEAD' })):sub(1, 7)
            )
        end
    )

    it('replaces visible base status for an explicit different hash', function()
        changes_since_base()
        minifugit.open({ base = base })
        local old = vim.api.nvim_get_current_buf()
        minifugit.open({ base = 'HEAD' })
        assert.is_false(vim.api.nvim_buf_is_valid(old))
        local text = lines(vim.api.nvim_get_current_buf())
        assert.is_true(vim.tbl_contains(text, ' M modified.txt'))
        for _, line in ipairs(text) do
            assert.is_nil(line:find('deleted.txt', 1, true))
            assert.is_nil(line:find('renamed.txt', 1, true))
        end
    end)

    it(
        'filters base entries and opens the working tree file with Enter',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            local original_input = vim.ui.input
            vim.ui.input = function(_, callback)
                callback('MODIFIED')
            end
            keys('/')
            vim.ui.input = original_input
            local text = lines(status)
            helpers.assert_has_line_containing(text, 'filter=MODIFIED')
            assert.is_true(vim.tbl_contains(text, ' M modified.txt'))
            for _, line in ipairs(text) do
                assert.is_nil(line:find('untracked.txt', 1, true))
            end
            select_entry(status, 'modified.txt')
            keys('<CR>')
            assert.are.equal(
                vim.fn.resolve(repo) .. '/modified.txt',
                vim.api.nvim_buf_get_name(0)
            )
            assert.are.same(
                { 'committed first', 'uncommitted second', 'unchanged' },
                lines(vim.api.nvim_get_current_buf())
            )
            vim.api.nvim_set_current_win(vim.fn.win_findbuf(status)[1])
            keys('<BS>')
            assert.is_true(vim.tbl_contains(lines(status), '?? untracked.txt'))
        end
    )

    it('keeps the normal deleted-file Enter behavior in base mode', function()
        changes_since_base()
        minifugit.open({ base = base })
        local status = vim.api.nvim_get_current_buf()
        select_entry(status, 'deleted.txt')
        local unchanged = helpers.snapshot_editor_state()
        keys('<CR>')
        unchanged()
        assert.are.equal(
            '[minifugit] Cannot open missing worktree path: deleted.txt',
            notifications[#notifications]
        )
    end)

    it(
        'replaces a hidden same-root owned-tab candidate for an explicit different base',
        function()
            changes_since_base()
            local origin = vim.api.nvim_get_current_tabpage()
            minifugit.open({ base = base, open_in_tab = true })
            local old = vim.api.nvim_get_current_buf()
            local old_tab = vim.api.nvim_get_current_tabpage()
            hide_status_buffer(vim.api.nvim_get_current_win())
            assert.are.equal(0, #vim.fn.win_findbuf(old))
            vim.api.nvim_set_current_tabpage(origin)
            minifugit.open({ base = 'HEAD', open_in_tab = true })
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            assert.is_false(vim.api.nvim_tabpage_is_valid(old_tab))
            assert.are.equal(2, #vim.api.nvim_list_tabpages())
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'Base: ' .. vim.trim(run({ 'rev-parse', 'HEAD' })):sub(1, 7)
            )
        end
    )

    it(
        'recreates a hidden owned-tab base candidate in normal mode when base is omitted',
        function()
            local origin = vim.api.nvim_get_current_tabpage()
            minifugit.open({ base = base, open_in_tab = true })
            local old = vim.api.nvim_get_current_buf()
            local old_tab = vim.api.nvim_get_current_tabpage()
            hide_status_buffer(vim.api.nvim_get_current_win())
            vim.api.nvim_set_current_tabpage(origin)
            minifugit.open({ open_in_tab = true })
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            assert.is_false(vim.api.nvim_tabpage_is_valid(old_tab))
            assert.are.equal(2, #vim.api.nvim_list_tabpages())
            helpers.assert_has_line_containing(
                lines(vim.api.nvim_get_current_buf()),
                'HEAD: main'
            )
        end
    )

    it(
        'keeps a visible owned-tab base candidate when omitted or equivalent and refreshes it',
        function()
            local origin = vim.api.nvim_get_current_tabpage()
            minifugit.open({ base = base, open_in_tab = true })
            local buf = vim.api.nvim_get_current_buf()
            local tab = vim.api.nvim_get_current_tabpage()
            write('later.txt', { 'later' })
            vim.api.nvim_set_current_tabpage(origin)
            minifugit.open({ base = base .. '^0', open_in_tab = true })
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.is_true(vim.tbl_contains(lines(buf), '?? later.txt'))
            vim.api.nvim_set_current_tabpage(origin)
            minifugit.open({ open_in_tab = true })
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
            helpers.assert_has_line_containing(
                lines(buf),
                'Base: ' .. base:sub(1, 7)
            )
        end
    )

    it(
        're-selects the surviving status pin after replacing an owned base tab',
        function()
            changes_since_base()
            local origin = vim.api.nvim_get_current_tabpage()
            minifugit.open({ base = 'HEAD', open_in_tab = false })
            local survivor = vim.api.nvim_get_current_buf()
            local survivor_win = vim.api.nvim_get_current_win()
            vim.cmd.tabnew()
            local launch = vim.api.nvim_get_current_tabpage()
            minifugit.open({ base = base, open_in_tab = true })
            local old = vim.api.nvim_get_current_buf()
            local owned = vim.api.nvim_get_current_tabpage()
            vim.cmd(vim.api.nvim_tabpage_get_number(launch) .. 'tabclose')
            minifugit.open({ base = 'HEAD', open_in_tab = false })
            assert.are.equal(origin, vim.api.nvim_get_current_tabpage())
            assert.are.equal(survivor, vim.api.nvim_get_current_buf())
            assert.are.equal(survivor_win, vim.api.nvim_get_current_win())
            assert.is_false(vim.api.nvim_buf_is_valid(old))
            assert.is_false(vim.api.nvim_tabpage_is_valid(owned))
            assert.are.equal(1, #vim.api.nvim_list_tabpages())
            assert.are.equal(2, #vim.api.nvim_list_wins())
        end
    )

    it(
        'keeps viewing toggles and hunk jumping available in base mode',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'modified.txt')
            keys('=')
            local preview_win, preview = diff_window('Minifugit diff')
            vim.api.nvim_set_current_win(preview_win)
            keys('aw')
            assert.is_true(vim.wo[preview_win].wrap)
            keys('an')
            helpers.assert_has_line_containing(
                lines(preview),
                'committed first'
            )
            assert.is_false(vim.tbl_contains(lines(preview), 'committed first'))
            keys('am')
            for _, line in ipairs(lines(preview)) do
                assert.is_nil(line:find('diff --git', 1, true))
            end
            vim.api.nvim_win_set_cursor(preview_win, { #lines(preview), 0 })
            keys('[h')
            local row = vim.api.nvim_win_get_cursor(preview_win)[1]
            assert.is_true(lines(preview)[row]:match('^@@') ~= nil)
            keys('al')
            local right_win = diff_window('Minifugit diff right')
            vim.api.nvim_set_current_win(right_win)
            keys('an')
            assert.is_false(vim.wo[right_win].number)
            keys(']h')
            local left_win = diff_window('Minifugit diff left')
            assert.are.same(
                vim.api.nvim_win_get_cursor(right_win),
                vim.api.nvim_win_get_cursor(left_win)
            )
            assert.are.equal(0, #notifications)
        end
    )

    it(
        'shows pure-rename metadata in split mode without changing the chosen layout or leaving empty windows',
        function()
            changes_since_base()
            local target = vim.api.nvim_get_current_win()
            local original_buf = vim.api.nvim_get_current_buf()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'renamed.txt')
            keys('al=')
            local _, stacked = diff_window('Minifugit diff')
            assert.is_true(
                vim.tbl_contains(lines(stacked), 'rename from old.txt')
            )
            assert.is_true(
                vim.tbl_contains(lines(stacked), 'rename to renamed.txt')
            )
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            keys('al')
            assert.is_true(
                vim.tbl_contains(lines(stacked), 'rename to renamed.txt')
            )
            keys('al')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            select_entry(status, 'modified.txt')
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = status })
            assert.is_true(vim.wait(1000, function()
                local visible = pcall(diff_window, 'Minifugit diff left')
                return visible
            end))
            local _, left = diff_window('Minifugit diff left')
            local _, right = diff_window('Minifugit diff right')
            assert.is_true(vim.tbl_contains(lines(left), 'base first'))
            assert.is_true(vim.tbl_contains(lines(right), 'uncommitted second'))
            select_entry(status, 'renamed.txt')
            keys('=')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            local preview_win, metadata = diff_window('Minifugit diff')
            assert.is_true(
                vim.tbl_contains(lines(metadata), 'rename from old.txt')
            )
            vim.api.nvim_set_current_win(preview_win)
            keys('q')
            assert.are.equal(original_buf, vim.api.nvim_win_get_buf(target))
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(status, vim.api.nvim_get_current_buf())
        end
    )

    it('previews deleted entries in stacked and split layouts', function()
        changes_since_base()
        minifugit.open({ base = base })
        local status = vim.api.nvim_get_current_buf()
        select_entry(status, 'deleted.txt')
        keys('=')
        local _, stacked = diff_window('Minifugit diff')
        assert.is_true(vim.tbl_contains(lines(stacked), 'delete me'))
        keys('al')
        local _, left = diff_window('Minifugit diff left')
        local right_win, right = diff_window('Minifugit diff right')
        assert.is_true(vim.tbl_contains(lines(left), 'delete me'))
        assert.is_nil(
            table.concat(lines(right), '\n'):find('delete me', 1, true)
        )
        assert.is_true(
            vim.wo[right_win].winbar:find('/dev/null', 1, true) ~= nil
        )
    end)

    it(
        'previews untracked files in both layouts and untracked binary files safely',
        function()
            changes_since_base()
            minifugit.open({ base = base })
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'untracked.txt')
            keys('=')
            local _, stacked = diff_window('Minifugit diff')
            assert.is_true(
                vim.tbl_contains(lines(stacked), 'new untracked content')
            )
            keys('al')
            local left_win, left = diff_window('Minifugit diff left')
            local _, right = diff_window('Minifugit diff right')
            assert.is_true(
                vim.tbl_contains(lines(right), 'new untracked content')
            )
            assert.is_nil(
                table
                    .concat(lines(left), '\n')
                    :find('new untracked content', 1, true)
            )
            assert.is_true(
                vim.wo[left_win].winbar:find('/dev/null', 1, true) ~= nil
            )
            vim.fn.writefile(
                vim.fn.list2blob({ 0, 98 }),
                repo .. '/untracked.bin'
            )
            keys('r')
            select_entry(status, 'untracked.bin')
            keys('=')
            local _, binary = diff_window('Minifugit diff')
            assert.is_true(vim.tbl_contains(lines(binary), 'binary file'))
        end
    )

    it(
        'resolves and previews against explicit cwd without changing or following the editor cwd',
        function()
            changes_since_base()
            local other = vim.fn.tempname()
            vim.fn.mkdir(other, 'p')
            vim.cmd.cd(other)
            local cwd = vim.fn.getcwd()
            minifugit.open({ cwd = repo, base = base })
            assert.are.equal(cwd, vim.fn.getcwd())
            local status = vim.api.nvim_get_current_buf()
            select_entry(status, 'modified.txt')
            keys('=')
            local _, stacked = diff_window('Minifugit diff')
            assert.is_true(vim.tbl_contains(lines(stacked), 'base first'))
            assert.is_true(
                vim.tbl_contains(lines(stacked), 'uncommitted second')
            )
            keys('al')
            local _, left = diff_window('Minifugit diff left')
            local _, right = diff_window('Minifugit diff right')
            assert.is_true(vim.tbl_contains(lines(left), 'base first'))
            assert.is_true(vim.tbl_contains(lines(right), 'uncommitted second'))
            keys('r')
            assert.are.equal(cwd, vim.fn.getcwd())
            vim.cmd.cd(repo)
            vim.fn.delete(other, 'rf')
        end
    )

    it(
        'returns invalid revision errors without creating windows, buffers or tabs',
        function()
            local unchanged = helpers.snapshot_editor_state()
            local ok, err = minifugit.open({
                base = 'unknown-revision',
                open_in_tab = true,
            })
            assert.is_nil(ok)
            assert.are.equal('Invalid base revision: unknown-revision', err)
            unchanged()
        end
    )
end)
