---@diagnostic disable: undefined-field
-- Conflicts preview as two merge stages. Resolution happens in the file; the
-- preview only shows what Git holds in the index for each side.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local project_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local REFUSAL =
    '[minifugit] Resolve the conflict in the file, then stage it with `s`'

---@param action fun()
---@return string[] messages
local function capture_notifications(action)
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
        table.insert(messages, message)
    end
    local ok, err = pcall(action)
    vim.notify = original_notify
    if not ok then
        error(err, 0)
    end
    return messages
end

---@param repo string
---@return string[]
local function porcelain(repo)
    local lines = vim.split(
        vim.trim(helpers.run({ 'git', 'status', '--porcelain' }, repo)),
        '\n'
    )
    table.sort(lines)
    return lines
end

---Line groups applied to each 1-based buffer row of a stacked diff.
---@param buf integer
---@return table<integer, string>
local function line_highlight_groups(buf)
    local namespace = vim.api.nvim_create_namespace('minifugit.ui.render')
    local groups = {}

    for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {
            details = true,
        }))
    do
        local group = mark[4].line_hl_group

        if group ~= nil then
            groups[mark[2] + 1] = group
        end
    end

    return groups
end

---New-side number of a stacked diff row. Gutter fields are right-aligned to
---`width`, so read the second field by position.
---@param row string
---@param width integer
---@return integer?
local function worktree_number(row, width)
    return tonumber((row:sub(width + 2, 2 * width + 1):gsub(' ', '')))
end

describe('minifugit conflict preview', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Minifugit
    local minifugit
    ---@type fun(): GitStatusWindow?
    local status_window
    local restore_constructor

    ---Base file with two regions far enough apart to conflict separately.
    local base_lines = {}
    for index = 1, 12 do
        table.insert(base_lines, 'l' .. index)
    end

    ---Replace `line` of `lines` with `text`.
    ---@param lines string[]
    ---@param line string
    ---@param text string
    ---@return string[]
    local function replacing(lines, line, text)
        local copy = vim.deepcopy(lines)
        copy[tonumber(line:sub(2))] = text
        return copy
    end

    ---@param path string
    ---@param lines string[]
    local function write(path, lines)
        helpers.write_file(vim.fs.joinpath(repo, path), lines)
    end

    ---@param args string[]
    local function git(args)
        helpers.run(vim.list_extend({ 'git' }, args), repo)
    end

    ---Merge `feature` into `main` and accept the conflict.
    ---@param theirs string[]
    ---@param ours string[]
    local function merge_conflict(theirs, ours)
        git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', theirs)
        git({ 'commit', '-qam', 'theirs' })
        git({ 'checkout', '-q', 'main' })
        write('a.txt', ours)
        git({ 'commit', '-qam', 'ours' })
        helpers.run({ 'sh', '-c', 'git merge -q feature || true' }, repo)
    end

    ---@param preview? MinifugitPreviewOptions
    local function open(preview)
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit = helpers.awaiting_reads(
            require('minifugit').setup({
                status = { width = 0.5, min_width = 20 },
                preview = preview,
            }),
            status_window
        )
        assert.is_true(minifugit.open({ cwd = repo }))
    end

    ---Preview the status entry containing `text`.
    ---@param text string
    ---@return string[] messages
    local function preview_entry(text)
        local win = assert(status_window())
        vim.api.nvim_win_set_cursor(
            win.win,
            { helpers.row_containing(win.buf.id, text), 0 }
        )

        return capture_notifications(function()
            assert.is_true(win:diff_entry())
            helpers.wait_idle(status_window)
        end)
    end

    ---@return integer win, integer buf
    local function stacked_diff()
        return helpers.diff_win_named('Minifugit diff')
    end

    before_each(function()
        if not vim.tbl_contains(vim.opt.runtimepath:get(), project_root) then
            vim.opt.runtimepath:prepend(project_root)
        end
        local lua_path = project_root
            .. '/lua/?.lua;'
            .. project_root
            .. '/lua/?/init.lua'
        if not package.path:find(project_root, 1, true) then
            package.path = lua_path .. ';' .. package.path
        end

        helpers.reload_minifugit()
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({
            ['a.txt'] = base_lines,
            ['b.txt'] = { 'b' },
        })
    end)

    after_each(function()
        restore_constructor()
        if minifugit ~= nil then
            minifugit.reset()
        end

        vim.cmd('silent! tabonly!')
        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('%bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))

        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

    it(
        'shows @@@ hunks with worktree line numbers and side highlights',
        function()
            merge_conflict(
                replacing(
                    replacing(base_lines, 'l2', 'theirs-2'),
                    'l11',
                    'theirs-11'
                ),
                replacing(
                    replacing(base_lines, 'l2', 'ours-2'),
                    'l11',
                    'ours-11'
                )
            )
            assert.are.same({ 'UU a.txt' }, porcelain(repo))
            open()

            preview_entry('UU a.txt')

            local win, buf = stacked_diff()
            local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local groups = line_highlight_groups(buf)
            local worktree = vim.fn.readfile(vim.fs.joinpath(repo, 'a.txt'))

            ---@param text string
            ---@return integer
            local function row_with(text)
                for row, line in ipairs(rows) do
                    if line:find(text, 1, true) ~= nil then
                        return row
                    end
                end

                error('Expected row containing not found: ' .. text)
            end

            ---Worktree line of `text`, the source of truth for new-side numbers.
            ---@param text string
            ---@return integer
            local function worktree_line(text)
                for line_number, line in ipairs(worktree) do
                    if line == text then
                        return line_number
                    end
                end

                error('Expected worktree line not found: ' .. text)
            end

            local width = #tostring(#worktree)
            local hunks = 0

            for _, line in ipairs(rows) do
                if vim.startswith(line, '@@@') then
                    hunks = hunks + 1
                end
            end

            assert.are.equal(2, hunks)

            for _, text in ipairs({
                'ours-2',
                'theirs-2',
                'ours-11',
                'theirs-11',
            }) do
                assert.are.equal(
                    worktree_line(text),
                    worktree_number(rows[row_with(text)], width)
                )
            end

            assert.are.equal(
                'MiniFugitDiffConflictHead',
                groups[row_with('ours-2')]
            )
            assert.are.equal(
                'MiniFugitDiffConflictIncoming',
                groups[row_with('theirs-2')]
            )
            assert.are.equal(
                'MiniFugitDiffConflictMarker',
                groups[row_with('<<<<<<< HEAD')]
            )

            for row, group in pairs(groups) do
                assert.are_not.equal(
                    'MiniFugitDiffAdded',
                    group,
                    'row ' .. row .. ' must not read as a plain addition'
                )
            end

            -- ]h visits both conflict hunks.
            local first_hunk = row_with('@@@')

            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
            vim.cmd('normal ]h')
            assert.are.equal(first_hunk, vim.api.nvim_win_get_cursor(win)[1])

            vim.cmd('normal ]h')
            assert.is_true(vim.api.nvim_win_get_cursor(win)[1] > first_hunk)
            assert.is_true(
                vim.startswith(
                    rows[vim.api.nvim_win_get_cursor(win)[1]] or '',
                    '@@@'
                )
            )
        end
    )

    it('labels the stacked header with the two merge sides', function()
        merge_conflict(
            replacing(
                replacing(base_lines, 'l2', 'theirs-2'),
                'l11',
                'theirs-11'
            ),
            replacing(replacing(base_lines, 'l2', 'ours-2'), 'l11', 'ours-11')
        )
        open()

        assert.are.same({}, preview_entry('UU a.txt'))

        local _, buf = stacked_diff()
        local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

        assert.are.equal('HEAD (main) vs MERGE_HEAD (feature)', header)
    end)

    it('splits a conflict into the two merge stages by title', function()
        merge_conflict(
            replacing(
                replacing(base_lines, 'l2', 'theirs-2'),
                'l11',
                'theirs-11'
            ),
            replacing(replacing(base_lines, 'l2', 'ours-2'), 'l11', 'ours-11')
        )
        open({ diff_layout = 'split' })

        assert.are.same({}, preview_entry('UU a.txt'))

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win, right_buf =
            helpers.diff_win_named('Minifugit diff right')
        local rows = function(buf)
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end

        ---@param buf integer
        ---@param text string
        ---@return integer?
        local function row_of(buf, text)
            for row, line in ipairs(rows(buf)) do
                if line:find(text, 1, true) ~= nil then
                    return row
                end
            end
        end

        -- Each pane holds exactly one merge stage: ours on the left, theirs on
        -- the right, with no conflict markers copied into the file view.
        for _, text in ipairs({ 'ours-2', 'ours-11' }) do
            assert.is_not_nil(row_of(left_buf, text))
        end

        for _, text in ipairs({ 'theirs-2', 'theirs-11' }) do
            assert.is_not_nil(row_of(right_buf, text))
        end

        for _, buf in ipairs({ left_buf, right_buf }) do
            for _, line in ipairs(rows(buf)) do
                assert.is_nil(line:find('<<<<<<<', 1, true))
                assert.is_nil(line:find('>>>>>>>', 1, true))
            end
        end

        ---@param buf integer
        ---@param row integer
        ---@return string?
        local function line_group(buf, row)
            local namespace =
                vim.api.nvim_create_namespace('minifugit.ui.split_line')

            for _, mark in
                ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {
                    details = true,
                }))
            do
                if mark[2] + 1 == row then
                    return mark[4].hl_group
                end
            end
        end

        assert.are.equal(
            'MiniFugitDiffRemoved',
            line_group(left_buf, assert(row_of(left_buf, 'ours-2')))
        )
        assert.are.equal(
            'MiniFugitDiffAdded',
            line_group(right_buf, assert(row_of(right_buf, 'theirs-2')))
        )
        assert.are.equal(
            'MiniFugitDiffRemoved',
            line_group(left_buf, assert(row_of(left_buf, 'ours-11')))
        )
        -- Word diff marks the changed part of each line, as for any diff.
        local intraline =
            vim.api.nvim_create_namespace('minifugit.ui.split_intra')
        assert.is_true(
            #vim.api.nvim_buf_get_extmarks(right_buf, intraline, 0, -1, {}) > 0
        )
        assert.is_match('%[1/2%] HEAD %(main%)$', vim.wo[left_win].winbar)
        assert.is_match(
            '%[2/2%] MERGE_HEAD %(feature%)$',
            vim.wo[right_win].winbar
        )
    end)

    it('names the rebase side from REBASE_HEAD', function()
        git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', replacing(base_lines, 'l2', 'theirs-2'))
        git({ 'commit', '-qam', 'theirs' })
        git({ 'checkout', '-q', 'main' })
        write('a.txt', replacing(base_lines, 'l2', 'ours-2'))
        git({ 'commit', '-qam', 'ours' })
        git({ 'checkout', '-q', 'feature' })
        helpers.run({ 'sh', '-c', 'git rebase main || true' }, repo)
        assert.is_true(
            vim.fn.filereadable(vim.fs.joinpath(repo, '.git', 'REBASE_HEAD'))
                == 1
        )
        assert.are.same({ 'UU a.txt' }, porcelain(repo))
        open()

        assert.are.same({}, preview_entry('UU a.txt'))

        local _, buf = stacked_diff()
        local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

        assert.are.equal('HEAD vs REBASE_HEAD (feature)', header)
    end)

    it('names the cherry-pick side from CHERRY_PICK_HEAD', function()
        git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', replacing(base_lines, 'l2', 'theirs-2'))
        git({ 'commit', '-qam', 'theirs' })
        git({ 'checkout', '-q', 'main' })
        write('a.txt', replacing(base_lines, 'l2', 'ours-2'))
        git({ 'commit', '-qam', 'ours' })
        helpers.run({ 'sh', '-c', 'git cherry-pick feature || true' }, repo)
        assert.is_true(
            vim.fn.filereadable(
                vim.fs.joinpath(repo, '.git', 'CHERRY_PICK_HEAD')
            ) == 1
        )
        assert.are.same({ 'UU a.txt' }, porcelain(repo))
        open()

        assert.are.same({}, preview_entry('UU a.txt'))

        local _, buf = stacked_diff()
        local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

        assert.are.equal('HEAD (main) vs CHERRY_PICK_HEAD (feature)', header)
    end)

    it('falls back to theirs when no incoming ref is recorded', function()
        git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', replacing(base_lines, 'l2', 'theirs-2'))
        git({ 'commit', '-qam', 'theirs' })
        git({ 'checkout', '-q', 'main' })
        -- An unmerged worktree edit is enough for `checkout -m` to conflict;
        -- it records no MERGE_HEAD, so no ref names the incoming side.
        write('a.txt', replacing(base_lines, 'l2', 'local-2'))
        helpers.run({ 'sh', '-c', 'git checkout -m feature || true' }, repo)
        assert.are.same({ 'UU a.txt' }, porcelain(repo))

        for _, ref in ipairs({
            'MERGE_HEAD',
            'CHERRY_PICK_HEAD',
            'REVERT_HEAD',
            'REBASE_HEAD',
        }) do
            assert.are.equal(
                0,
                vim.fn.filereadable(vim.fs.joinpath(repo, '.git', ref))
            )
        end

        open()

        assert.are.same({}, preview_entry('UU a.txt'))

        local _, buf = stacked_diff()
        local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

        -- `checkout -m feature` moves HEAD onto the incoming branch.
        assert.are.equal('HEAD (feature) vs theirs', header)
    end)

    ---@param buf integer
    ---@return string[] lines Non-empty rows of a pane; alignment adds fillers.
    local function content_lines(buf)
        return vim.tbl_filter(function(line)
            return line ~= ''
        end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end

    ---@param win integer
    ---@param text string
    local function winbar_has(win, text)
        return vim.wo[win].winbar:find(text, 1, true) ~= nil
    end

    it('leaves the deleted side empty in a DU conflict', function()
        -- Deleted by us: the worktree has no file, stage 2 is missing.
        git({ 'checkout', '-q', '-b', 'feature' })
        write('a.txt', replacing(base_lines, 'l2', 'theirs-2'))
        git({ 'commit', '-qam', 'theirs modifies' })
        git({ 'checkout', '-q', 'main' })
        git({ 'rm', '-q', 'a.txt' })
        git({ 'commit', '-qm', 'ours deletes' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)
        assert.are.same({ 'DU a.txt' }, porcelain(repo))
        open({ diff_layout = 'split' })

        assert.are.same({}, preview_entry('DU a.txt'))

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win, right_buf =
            helpers.diff_win_named('Minifugit diff right')

        -- The missing stage is filler rows only, never content.
        assert.are.same({}, content_lines(left_buf))
        assert.are.equal('theirs-2', content_lines(right_buf)[2])
        assert.is_true(winbar_has(left_win, 'HEAD (main) (deleted)'))
        assert.is_true(winbar_has(right_win, 'MERGE_HEAD (feature)'))
        assert.is_false(winbar_has(right_win, '(deleted)'))
    end)

    it('leaves the deleted side empty in a UD conflict', function()
        -- Deleted by them: stage 3 is missing, so the right pane is empty.
        git({ 'checkout', '-q', '-b', 'feature' })
        git({ 'rm', '-q', 'a.txt' })
        git({ 'commit', '-qm', 'theirs deletes' })
        git({ 'checkout', '-q', 'main' })
        write('a.txt', replacing(base_lines, 'l2', 'ours-2'))
        git({ 'commit', '-qam', 'ours modifies' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)
        assert.are.same({ 'UD a.txt' }, porcelain(repo))
        open({ diff_layout = 'split' })

        assert.are.same({}, preview_entry('UD a.txt'))

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win, right_buf =
            helpers.diff_win_named('Minifugit diff right')

        assert.are.equal('ours-2', content_lines(left_buf)[2])
        assert.are.same({}, content_lines(right_buf))
        assert.is_true(winbar_has(left_win, 'HEAD (main)'))
        assert.is_true(winbar_has(right_win, 'MERGE_HEAD (feature) (deleted)'))
    end)

    it('marks a side that never had the file as absent', function()
        -- Added by us: stage 2 exists, stage 3 never did.
        local hash =
            vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD:a.txt' }, repo))
        git({ 'rm', '-q', '--cached', 'a.txt' })
        local info = vim.fn.tempname()
        helpers.write_file(info, { '100644 ' .. hash .. ' 2\ta.txt' })
        helpers.run({
            'sh',
            '-c',
            'git update-index --index-info < ' .. vim.fn.shellescape(info),
        }, repo)
        assert.are.same({ 'AU a.txt' }, porcelain(repo))
        open({ diff_layout = 'split' })

        assert.are.same({}, preview_entry('AU a.txt'))

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win, right_buf =
            helpers.diff_win_named('Minifugit diff right')

        assert.are.equal('l2', content_lines(left_buf)[2])
        assert.are.same({}, content_lines(right_buf))
        assert.is_true(winbar_has(left_win, 'HEAD (main)'))
        assert.is_true(winbar_has(right_win, 'theirs (absent)'))
    end)

    it('reports a conflict deleted on both sides', function()
        local hash =
            vim.trim(helpers.run({ 'git', 'rev-parse', 'HEAD:a.txt' }, repo))
        git({ 'rm', '-q', 'a.txt' })
        local info = vim.fn.tempname()
        helpers.write_file(info, { '100644 ' .. hash .. ' 1\ta.txt' })
        helpers.run({
            'sh',
            '-c',
            'git update-index --index-info < ' .. vim.fn.shellescape(info),
        }, repo)
        assert.are.same({ 'DD a.txt' }, porcelain(repo))
        open({ diff_layout = 'split' })

        assert.are.same({}, preview_entry('DD a.txt'))

        local _, buf = stacked_diff()
        assert.are.same(
            { 'Deleted on both sides' },
            vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        )
        assert.are.equal(0, #vim.tbl_filter(function(win)
            return vim.wo[win].winbar:find('[1/2]', 1, true) ~= nil
        end, vim.api.nvim_tabpage_list_wins(0)))
    end)

    it('previews an add/add conflict like a content conflict', function()
        git({ 'checkout', '-q', '-b', 'feature' })
        write('c.txt', { 'theirs' })
        git({ 'add', 'c.txt' })
        git({ 'commit', '-qm', 'theirs adds' })
        git({ 'checkout', '-q', 'main' })
        write('c.txt', { 'ours' })
        git({ 'add', 'c.txt' })
        git({ 'commit', '-qm', 'ours adds' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)
        assert.are.same({ 'AA c.txt' }, porcelain(repo))
        open()

        assert.are.same({}, preview_entry('AA c.txt'))

        local _, buf = stacked_diff()
        local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local groups = line_highlight_groups(buf)

        assert.are.equal('HEAD (main) vs MERGE_HEAD (feature)', rows[1])

        ---@param text string
        ---@return integer
        local function row_with(text)
            for row, line in ipairs(rows) do
                if line:find(text, 1, true) ~= nil then
                    return row
                end
            end

            error('Expected row containing not found: ' .. text)
        end

        assert.are.equal('MiniFugitDiffConflictHead', groups[row_with('ours')])
        assert.are.equal(
            'MiniFugitDiffConflictIncoming',
            groups[row_with('theirs')]
        )
        assert.are.equal(
            'MiniFugitDiffConflictMarker',
            groups[row_with('<<<<<<<')]
        )
    end)

    it('refuses hunk actions and keeps the conflict in the index', function()
        merge_conflict(
            replacing(
                replacing(base_lines, 'l2', 'theirs-2'),
                'l11',
                'theirs-11'
            ),
            replacing(replacing(base_lines, 'l2', 'ours-2'), 'l11', 'ours-11')
        )
        open()

        assert.are.same({}, preview_entry('UU a.txt'))

        local win, buf = stacked_diff()
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(
            win,
            { helpers.row_containing(buf, '@@@'), 0 }
        )

        for _, key in ipairs({ 's', 'u', 'd' }) do
            assert.are.same(
                REFUSAL,
                capture_notifications(function()
                    vim.cmd('normal ' .. key)
                end)[1]
            )
            assert.are.same({ 'UU a.txt' }, porcelain(repo))
        end
    end)

    it('names stacked sides without building the stage diff', function()
        merge_conflict(
            replacing(base_lines, 'l2', 'theirs-2'),
            replacing(base_lines, 'l2', 'ours-2')
        )
        open()

        -- `before_each` reloads the plugin, so require the live module here.
        local plugin_git = require('minifugit.git')
        local original = plugin_git.split_diff
        local calls = 0

        plugin_git.split_diff = function(...)
            calls = calls + 1
            return original(...)
        end

        local ok, err = pcall(function()
            preview_entry('UU a.txt')

            local _, buf = stacked_diff()
            local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

            -- The header still names both sides, from refs alone.
            assert.are.equal('HEAD (main) vs MERGE_HEAD (feature)', header)
        end)

        plugin_git.split_diff = original
        assert.is_true(ok, err)
        assert.are.equal(0, calls)
    end)

    it('reads both merge stages once for the split layout', function()
        merge_conflict(
            replacing(base_lines, 'l2', 'theirs-2'),
            replacing(base_lines, 'l2', 'ours-2')
        )
        open({ diff_layout = 'split' })

        local plugin_git = require('minifugit.git')
        local original = plugin_git.split_diff
        local calls = 0

        plugin_git.split_diff = function(...)
            calls = calls + 1
            return original(...)
        end

        local ok, err = pcall(function()
            preview_entry('UU a.txt')
        end)

        plugin_git.split_diff = original
        assert.is_true(ok, err)
        assert.are.equal(1, calls)
    end)

    it('keeps partially resolved rows on their worktree lines', function()
        -- Both sides insert a line before `z`; the user deletes `z` and keeps
        -- the markers, so Git reports the deleted line once per parent.
        write('f.txt', { 'a', 'z' })
        git({ 'add', 'f.txt' })
        git({ 'commit', '-qm', 'base f' })
        git({ 'checkout', '-q', '-b', 'feature' })
        write('f.txt', { 'a', 'theirs', 'z' })
        git({ 'commit', '-qam', 'theirs' })
        git({ 'checkout', '-q', 'main' })
        write('f.txt', { 'a', 'ours', 'z' })
        git({ 'commit', '-qam', 'ours' })
        helpers.run({ 'sh', '-c', 'git merge feature || true' }, repo)
        write('f.txt', {
            'a',
            '<<<<<<< HEAD',
            'ours',
            '=======',
            'theirs',
            '>>>>>>> feature',
        })
        assert.are.same({ 'UU f.txt' }, porcelain(repo))
        open()
        assert.are.same({}, preview_entry('UU f.txt'))

        local _, buf = stacked_diff()
        local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local groups = line_highlight_groups(buf)
        local worktree = vim.fn.readfile(vim.fs.joinpath(repo, 'f.txt'))
        local width = #tostring(#worktree)
        local first = helpers.row_containing(buf, '@@@') + 1
        local expected = {
            { 'a', 1, 1, nil },
            { '<<<<<<< HEAD', nil, 2, 'MiniFugitDiffConflictMarker' },
            { 'ours', 2, 3, 'MiniFugitDiffConflictHead' },
            { 'z', 3, nil, 'MiniFugitDiffRemoved' },
            { '=======', nil, 4, 'MiniFugitDiffConflictMarker' },
            { 'theirs', nil, 5, 'MiniFugitDiffConflictIncoming' },
            { 'z', nil, nil, 'MiniFugitDiffRemoved' },
            { '>>>>>>> feature', nil, 6, 'MiniFugitDiffConflictMarker' },
        }

        for offset, want in ipairs(expected) do
            local row = first + offset - 1
            local line = rows[row]
            local where = 'row ' .. offset .. ' (' .. want[1] .. ')'
            local old = tonumber(vim.trim(line:sub(1, width)))
            local new = tonumber(vim.trim(line:sub(width + 2, 2 * width + 1)))
            local content = vim.trim(line:sub(2 * width + 2))

            assert.are.equal(want[1], content, where)
            assert.are.equal(want[2], old, 'old of ' .. where)
            assert.are.equal(want[3], new, 'new of ' .. where)
            assert.are.equal(want[4], groups[row], 'group of ' .. where)
        end

        -- Worktree numbering runs 1..6: no removal row steals a line.
        local numbered = {}

        for offset = 0, 7 do
            local new = tonumber(
                vim.trim(rows[first + offset]:sub(width + 2, 2 * width + 1))
            )

            if new ~= nil then
                table.insert(numbered, new)
            end
        end

        assert.are.same({ 1, 2, 3, 4, 5, 6 }, numbered)

        for row, group in pairs(groups) do
            assert.are_not.equal('MiniFugitDiffAdded', group, 'row ' .. row)
        end
    end)
end)
