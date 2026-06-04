---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@param expected string
local function assert_has_line(lines, expected)
    for _, line in ipairs(lines) do
        if line == expected then
            return
        end
    end

    assert.fail('Expected line not found: ' .. expected)
end

---@param buf integer
---@param text string
---@return integer
local function row_containing(buf, text)
    for row, line in ipairs(buffer_lines(buf)) do
        if line:find(text, 1, true) ~= nil then
            return row
        end
    end

    error('Expected row containing not found: ' .. text)
end

---@param win integer
---@return table<string, any>
local function capture_winopts(win)
    return {
        number = vim.wo[win].number,
        relativenumber = vim.wo[win].relativenumber,
        signcolumn = vim.wo[win].signcolumn,
        foldcolumn = vim.wo[win].foldcolumn,
        wrap = vim.wo[win].wrap,
        cursorline = vim.wo[win].cursorline,
        winfixwidth = vim.wo[win].winfixwidth,
        winbar = vim.wo[win].winbar,
        diff = vim.wo[win].diff,
        fillchars = vim.wo[win].fillchars,
        statuscolumn = vim.wo[win].statuscolumn,
    }
end

---@param actual table<string, any>
---@param expected table<string, any>
local function assert_winopts(actual, expected)
    for key, value in pairs(expected) do
        assert.are.equal(value, actual[key], key)
    end
end

---@param keys string
local function normal_keys(keys)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        'nx',
        false
    )
end

---@param actual table<string, any>
---@param expected table<string, any>
---@return boolean
local function winopts_match(actual, expected)
    for key, value in pairs(expected) do
        if actual[key] ~= value then
            return false
        end
    end

    return true
end

---@param buf integer
---@param expected_opts? table<string, any>
local function wait_for_current_buf(buf, expected_opts)
    assert.is_true(vim.wait(1000, function()
        if vim.api.nvim_get_current_buf() ~= buf then
            return false
        end

        return expected_opts == nil
            or winopts_match(
                capture_winopts(vim.api.nvim_get_current_win()),
                expected_opts
            )
    end))
end

---@param tabpage integer
---@return boolean
local function tabpage_is_valid(tabpage)
    for _, existing in ipairs(vim.api.nvim_list_tabpages()) do
        if existing == tabpage then
            return true
        end
    end

    return false
end

---@param tabpage integer
---@return integer[]
local function normal_windows(tabpage)
    local wins = {}

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_get_config(win).relative == '' then
            table.insert(wins, win)
        end
    end

    return wins
end

describe('minifugit status UI', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Minifugit
    local minifugit

    before_each(function()
        package.loaded.minifugit = nil
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
        vim.cmd.enew()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20 },
        })
    end)

    after_each(function()
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
        'opens a status window with the expected buffer options and contents',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'staged.txt'),
                { 'staged' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            helpers.run({ 'git', 'add', 'staged.txt' }, repo)

            minifugit.status()

            ---@type GitStatusWindow
            local gsw = minifugit.gsw
            assert.is_not_nil(gsw)
            assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
            assert.is_true(vim.api.nvim_buf_is_valid(gsw.buf.id))
            assert.are.equal(gsw.buf.id, vim.api.nvim_win_get_buf(gsw.win))
            assert.are.equal('nofile', vim.bo[gsw.buf.id].buftype)
            assert.are.equal('hide', vim.bo[gsw.buf.id].bufhidden)
            assert.are.equal(false, vim.bo[gsw.buf.id].modifiable)
            assert.are.equal('minifugit', vim.bo[gsw.buf.id].filetype)
            assert.are.equal(false, vim.wo[gsw.win].number)
            assert.are.equal(false, vim.wo[gsw.win].relativenumber)
            assert.are.equal('no', vim.wo[gsw.win].signcolumn)
            assert.are.equal(true, vim.wo[gsw.win].cursorline)
            assert.are.equal(true, vim.wo[gsw.win].winfixwidth)

            local lines = buffer_lines(gsw.buf.id)
            assert_has_line(lines, 'HEAD: main')
            assert_has_line(lines, 'Unstaged (1)')
            assert_has_line(lines, ' M tracked.txt')
            assert_has_line(lines, 'Staged (1)')
            assert_has_line(lines, 'A  staged.txt')
            assert_has_line(lines, 'Untracked (1)')
            assert_has_line(lines, '?? untracked.txt')
        end
    )

    it('previews a diff for an untracked file', function()
        helpers.write_file(vim.fs.joinpath(repo, 'new-dir/file.txt'), {
            'new content',
        })
        minifugit.options.preview.diff_layout = 'stacked'
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'new-dir/file.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        assert.is_not_nil(gsw.diff_buf)
        helpers.assert_has_line_containing(
            buffer_lines(gsw.diff_buf.id),
            '+new content'
        )
    end)

    it(
        'refreshes and reuses the existing status buffer on repeated calls',
        function()
            minifugit.status()

            ---@type GitStatusWindow
            local first = minifugit.gsw
            local first_buf = first.buf.id
            local first_win = assert(first.win)

            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            minifugit.status()

            assert.are.equal(first, minifugit.gsw)
            assert.are.equal(first_buf, minifugit.gsw.buf.id)
            assert.are.equal(first_win, minifugit.gsw.win)
            assert.are.equal(first_buf, vim.api.nvim_win_get_buf(first_win))
            assert_has_line(buffer_lines(first_buf), '?? untracked.txt')
        end
    )

    it('closes the status window through its normal mode mapping', function()
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local win = assert(gsw.win)
        local buf = gsw.buf.id

        vim.api.nvim_set_current_win(win)
        vim.cmd.normal('q')

        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_nil(gsw.win)
    end)

    it('opens the status workflow in a new tab when configured', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20, open_in_tab = true },
        })
        local original_tab = vim.api.nvim_get_current_tabpage()
        local tab_count = #vim.api.nvim_list_tabpages()

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        assert.is_not_nil(gsw)
        assert.are_not.equal(original_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(tab_count + 1, #vim.api.nvim_list_tabpages())
        assert.are.equal(
            vim.api.nvim_get_current_tabpage(),
            vim.api.nvim_win_get_tabpage(gsw.win)
        )
        assert.are.equal(gsw.buf.id, vim.api.nvim_win_get_buf(gsw.win))
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('reopens tab diff previews with the configured status width', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.4, min_width = 20, open_in_tab = true },
            preview = { diff_layout = 'stacked' },
        })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local status_win = assert(gsw.win)
        local expected_status_width =
            math.max(math.floor(vim.o.columns * 0.4), 20)
        vim.api.nvim_win_set_cursor(
            status_win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        assert.are.equal(
            expected_status_width,
            vim.api.nvim_win_get_width(status_win)
        )

        local diff_win = assert(gsw.diff_win)
        vim.api.nvim_set_current_win(diff_win)
        vim.cmd.quit()

        assert.is_true(vim.wait(1000, function()
            return vim.api.nvim_win_is_valid(status_win)
                and #vim.api.nvim_tabpage_list_wins(0) == 1
        end))

        vim.api.nvim_set_current_win(status_win)
        assert.is_true(gsw:diff_entry())

        local reopened_diff_win = assert(gsw.diff_win)
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(
            expected_status_width,
            vim.api.nvim_win_get_width(status_win)
        )
        assert.are.equal(
            vim.o.columns - expected_status_width - 1,
            vim.api.nvim_win_get_width(reopened_diff_win)
        )
    end)

    it('ignores floating windows when opening status-only previews', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.4, min_width = 20 },
            preview = { diff_layout = 'stacked' },
        })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local status_win = assert(gsw.win)

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if
                win ~= status_win
                and vim.api.nvim_win_get_config(win).relative == ''
            then
                vim.api.nvim_win_close(win, true)
            end
        end

        local float_buf = vim.api.nvim_create_buf(false, true)
        local float_win = vim.api.nvim_open_win(float_buf, false, {
            relative = 'editor',
            row = 1,
            col = 1,
            width = 10,
            height = 1,
            style = 'minimal',
        })
        local expected_status_width =
            math.max(math.floor(vim.o.columns * 0.4), 20)

        vim.api.nvim_set_current_win(status_win)
        vim.api.nvim_win_set_cursor(
            status_win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())

        local diff_win = assert(gsw.diff_win)
        assert.are.same(2, #normal_windows(vim.api.nvim_get_current_tabpage()))
        assert.are.equal(
            expected_status_width,
            vim.api.nvim_win_get_width(status_win)
        )
        assert.are.equal(
            vim.o.columns - expected_status_width - 1,
            vim.api.nvim_win_get_width(diff_win)
        )
        assert.is_true(vim.api.nvim_win_is_valid(float_win))

        vim.api.nvim_win_close(float_win, true)
    end)

    it(
        'auto-closes the status tab when only minifugit buffers remain',
        function()
            minifugit = require('minifugit').setup({
                status = { width = 0.5, min_width = 20, open_in_tab = true },
            })
            local tab_count = #vim.api.nvim_list_tabpages()

            minifugit.status()

            ---@type GitStatusWindow
            local gsw = minifugit.gsw
            local tabpage = vim.api.nvim_get_current_tabpage()
            vim.api.nvim_set_current_win(gsw.win)
            vim.cmd.normal('q')

            assert.is_true(vim.wait(1000, function()
                return not tabpage_is_valid(tabpage)
            end))
            assert.are.equal(tab_count, #vim.api.nvim_list_tabpages())
        end
    )

    it('keeps the status tab after a foreign buffer is opened', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20, open_in_tab = true },
        })
        local tab_count = #vim.api.nvim_list_tabpages()

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local tabpage = vim.api.nvim_get_current_tabpage()
        local target_win = assert(gsw.target_win)
        assert.is_true(vim.api.nvim_win_is_valid(target_win))
        local foreign_path = vim.fs.joinpath(repo, 'foreign.txt')
        helpers.write_file(foreign_path, { 'foreign' })
        vim.api.nvim_set_current_win(target_win)
        vim.cmd.edit(vim.fn.fnameescape(foreign_path))
        assert.is_true(vim.wait(1000, function()
            return gsw.tab_foreign_buffer == true
        end))

        vim.api.nvim_set_current_win(gsw.win)
        vim.cmd.normal('q')

        assert.is_true(vim.wait(1000, function()
            return tabpage_is_valid(tabpage)
                and #vim.api.nvim_list_tabpages() == tab_count + 1
        end))
    end)

    it('opens status entries in the status tab as workflow buffers', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20, open_in_tab = true },
        })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local tabpage = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:enter_entry())

        assert.are.equal(tabpage, vim.api.nvim_get_current_tabpage())
        assert.are.equal(
            vim.uv.fs_realpath(vim.fs.joinpath(repo, 'tracked.txt')),
            vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0))
        )
        assert.is_false(gsw.tab_foreign_buffer)
    end)

    it('does not open the commit window without staged files', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local status_win = assert(gsw.win)
        local status_buf = gsw.buf.id
        local notifications = {}
        local original_notify = vim.notify

        vim.notify = function(message, level)
            table.insert(notifications, { message = message, level = level })
        end

        local commit_call_ok, ok = pcall(function()
            return gsw:commit()
        end)
        vim.notify = original_notify

        assert.is_true(commit_call_ok)
        assert.is_false(ok)
        assert.are.equal(status_win, vim.api.nvim_get_current_win())
        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert.are.same({
            {
                message = '[minifugit] No staged files to commit',
                level = vim.log.levels.WARN,
            },
        }, notifications)

        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) then
                assert.are_not.equal('gitcommit', vim.bo[buf].filetype)
            end
        end
    end)

    it('keeps the window when closing the commit buffer with :q', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local status_buf = gsw.buf.id
        local original_status_win = assert(gsw.win)
        local window_count = #vim.api.nvim_tabpage_list_wins(0)

        assert.is_true(gsw:commit())
        local commit_win = vim.api.nvim_get_current_win()
        local commit_buf = vim.api.nvim_get_current_buf()
        assert.are.equal(original_status_win, commit_win)
        assert.are.equal('gitcommit', vim.bo[commit_buf].filetype)

        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(':q   <CR>', true, false, true),
            'xt',
            false
        )

        assert.is_true(vim.wait(1000, function()
            return gsw.win == commit_win
                and vim.api.nvim_win_is_valid(commit_win)
                and vim.api.nvim_win_get_buf(commit_win) == status_buf
                and vim.api.nvim_get_current_buf() == status_buf
        end))
        assert.are.equal(window_count, #vim.api.nvim_tabpage_list_wins(0))
        assert.is_false(vim.api.nvim_buf_is_valid(commit_buf))
        assert_has_line(buffer_lines(status_buf), 'Staged (1)')
        assert_has_line(buffer_lines(status_buf), 'M  tracked.txt')
    end)

    for _, command in ipairs({ 'wq', 'x', 'xit', 'exit' }) do
        it(
            'keeps the window when saving and closing the commit buffer with :'
                .. command,
            function()
                helpers.write_file(
                    vim.fs.joinpath(repo, 'tracked.txt'),
                    { 'one', 'two' }
                )
                helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
                minifugit.status()

                ---@type GitStatusWindow
                local gsw = minifugit.gsw
                local status_buf = gsw.buf.id
                local original_status_win = assert(gsw.win)
                local window_count = #vim.api.nvim_tabpage_list_wins(0)

                assert.is_true(gsw:commit())
                local commit_win = vim.api.nvim_get_current_win()
                local commit_buf = vim.api.nvim_get_current_buf()
                assert.are.equal(original_status_win, commit_win)
                assert.are.equal('gitcommit', vim.bo[commit_buf].filetype)

                vim.api.nvim_buf_set_lines(
                    commit_buf,
                    0,
                    0,
                    false,
                    { 'commit from :' .. command }
                )
                vim.api.nvim_feedkeys(
                    vim.api.nvim_replace_termcodes(
                        ':' .. command .. '   <CR>',
                        true,
                        false,
                        true
                    ),
                    'xt',
                    false
                )

                assert.is_true(vim.wait(1000, function()
                    return gsw.win == commit_win
                        and vim.api.nvim_win_is_valid(commit_win)
                        and vim.api.nvim_win_get_buf(commit_win) == status_buf
                        and vim.api.nvim_get_current_buf() == status_buf
                end))
                assert.are.equal(
                    window_count,
                    #vim.api.nvim_tabpage_list_wins(0)
                )
                assert.is_false(vim.api.nvim_buf_is_valid(commit_buf))
                assert.are.equal(
                    'commit from :' .. command,
                    vim.trim(
                        helpers.run({ 'git', 'log', '-1', '--pretty=%s' }, repo)
                    )
                )
            end
        )
    end

    it('keeps modified commit buffers open without :q!', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local status_buf = gsw.buf.id
        local status_win = assert(gsw.win)
        local notifications = {}
        local original_notify = vim.notify

        assert.is_true(gsw:commit())
        local commit_win = vim.api.nvim_get_current_win()
        local commit_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(commit_buf, 0, 0, false, { 'message' })
        assert.is_true(vim.bo[commit_buf].modified)

        vim.notify = function(message, level)
            table.insert(notifications, { message = message, level = level })
        end

        local notify_call_ok, notify_err = pcall(function()
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes(':q   <CR>', true, false, true),
                'xt',
                false
            )

            assert.is_true(vim.wait(1000, function()
                return #notifications > 0
            end))
        end)
        vim.notify = original_notify
        assert(notify_call_ok, notify_err)
        assert.are.same({
            {
                message = '[minifugit] No write since last change (add ! to override)',
                level = vim.log.levels.WARN,
            },
        }, notifications)
        assert.are.equal(commit_win, vim.api.nvim_get_current_win())
        assert.are.equal(commit_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(status_win, commit_win)
        assert.are.equal(commit_buf, vim.api.nvim_win_get_buf(commit_win))

        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(':q!   <CR>', true, false, true),
            'xt',
            false
        )

        assert.is_true(vim.wait(1000, function()
            return gsw.win == commit_win
                and vim.api.nvim_win_is_valid(commit_win)
                and vim.api.nvim_win_get_buf(commit_win) == status_buf
                and vim.api.nvim_get_current_buf() == status_buf
        end))
        assert.is_false(vim.api.nvim_buf_is_valid(commit_buf))
    end)

    it(
        'cleans up modified commit buffers after a forced window close',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
            minifugit.status()

            ---@type GitStatusWindow
            local gsw = minifugit.gsw
            local status_buf = gsw.buf.id
            local window_count = #vim.api.nvim_tabpage_list_wins(0)

            assert.is_true(gsw:commit())
            local commit_win = vim.api.nvim_get_current_win()
            local commit_buf = vim.api.nvim_get_current_buf()
            local commit_path = vim.api.nvim_buf_get_name(commit_buf)
            vim.api.nvim_buf_set_lines(commit_buf, 0, 0, false, { 'message' })
            assert.is_true(vim.bo[commit_buf].modified)

            vim.api.nvim_win_close(commit_win, true)

            assert.is_true(vim.wait(1000, function()
                return gsw.win ~= nil
                    and vim.api.nvim_win_is_valid(gsw.win)
                    and vim.api.nvim_win_get_buf(gsw.win) == status_buf
                    and vim.api.nvim_get_current_buf() == status_buf
                    and not vim.api.nvim_buf_is_valid(commit_buf)
            end))
            assert.are.equal(window_count, #vim.api.nvim_tabpage_list_wins(0))
            assert.is_nil(vim.uv.fs_stat(commit_path))
            assert_has_line(buffer_lines(status_buf), 'Staged (1)')
            assert_has_line(buffer_lines(status_buf), 'M  tracked.txt')
        end
    )

    it('does not show an inherited winbar in the commit window', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        vim.wo.winbar = 'real file winbar'
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw

        assert.is_true(gsw:commit())
        local commit_win = vim.api.nvim_get_current_win()
        local commit_buf = vim.api.nvim_get_current_buf()
        assert.are.equal('gitcommit', vim.bo[commit_buf].filetype)
        assert.are.equal('', vim.wo[commit_win].winbar)

        assert.is_true(vim.wait(1000, function()
            return gsw.win == nil
        end))
        assert.are.equal('', vim.wo[commit_win].winbar)

        vim.cmd.quit()
    end)

    it('renders a helpful message outside a git repository', function()
        local not_repo = vim.fn.tempname()
        vim.fn.mkdir(not_repo, 'p')
        vim.cmd.cd(vim.fn.fnameescape(not_repo))

        minifugit.status()

        local lines = buffer_lines(minifugit.gsw.buf.id)
        assert_has_line(lines, 'HEAD: (none)')
        helpers.assert_has_line_containing(lines, 'Not inside a git repository')

        vim.fn.delete(not_repo, 'rf')
    end)

    it(
        'opens an already visible modified entry without re-editing it',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'unsaved' })
            assert.is_true(vim.bo[file_buf].modified)

            minifugit.status()
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            vim.api.nvim_win_set_cursor(
                minifugit.gsw.win,
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )

            assert.is_true(minifugit.gsw:enter_entry())

            assert.are.equal(file_win, vim.api.nvim_get_current_win())
            assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
            assert.is_true(vim.bo[file_buf].modified)
        end
    )

    it(
        'keeps a real file window options unchanged after focusing status',
        function()
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            vim.wo[file_win].cursorline = false
            vim.wo[file_win].winfixwidth = false
            vim.wo[file_win].winbar = 'real file'
            vim.wo[file_win].statuscolumn = 'user-statuscolumn'
            local before = capture_winopts(file_win)

            minifugit.status()
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            vim.cmd.normal('q')

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'restores a real file window options after closing stacked diff',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            vim.wo[file_win].cursorline = true
            vim.wo[file_win].winfixwidth = false
            vim.wo[file_win].winbar = 'real file'
            vim.wo[file_win].statuscolumn = 'user-statuscolumn'
            local before = capture_winopts(file_win)

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            assert.are.equal(
                minifugit.gsw.diff_buf.id,
                vim.api.nvim_win_get_buf(file_win)
            )
            assert.are.equal(false, vim.wo[file_win].number)
            assert.are.equal(false, vim.wo[file_win].relativenumber)
            assert.are.equal('no', vim.wo[file_win].signcolumn)

            minifugit.gsw:close()

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'focuses an already open diff when showing the same entry diff',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            vim.api.nvim_win_set_cursor(
                minifugit.gsw.win,
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )

            assert.is_true(minifugit.gsw:diff_entry())
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            assert.is_true(minifugit.gsw:diff_entry())

            assert.are.equal(
                minifugit.gsw.diff_win,
                vim.api.nvim_get_current_win()
            )
        end
    )

    it('restores real file window options after closing split diff', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo[file_win].number = false
        vim.wo[file_win].relativenumber = true
        vim.wo[file_win].signcolumn = 'auto:2'
        vim.wo[file_win].foldcolumn = '1'
        vim.wo[file_win].wrap = true
        vim.wo[file_win].cursorline = true
        vim.wo[file_win].winfixwidth = false
        vim.wo[file_win].winbar = 'real file split'
        vim.wo[file_win].statuscolumn = 'split-statuscolumn'
        local before = capture_winopts(file_win)

        minifugit.options.preview.diff_layout = 'split'
        minifugit.status()
        vim.api.nvim_win_set_cursor(
            minifugit.gsw.win,
            { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
        )
        minifugit.gsw:diff_entry()

        assert.are.equal(
            minifugit.gsw.diff_left_buf.id,
            vim.api.nvim_win_get_buf(file_win)
        )
        assert.are.equal(true, vim.wo[file_win].diff)
        assert.are.equal(false, vim.wo[file_win].relativenumber)
        assert.are.equal('yes:1', vim.wo[file_win].signcolumn)

        minifugit.gsw:close()

        assert.is_true(vim.api.nvim_win_is_valid(file_win))
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), before)
    end)

    it('restores file options when Ctrl-O leaves the status buffer', function()
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo.number = true
        vim.wo.relativenumber = true
        vim.wo.signcolumn = 'yes:2'
        vim.wo.foldcolumn = '2'
        vim.wo.wrap = true
        vim.wo.cursorline = false
        vim.wo.winbar = 'real file jump'
        vim.wo.statuscolumn = 'jump-statuscolumn'
        local file_opts = capture_winopts(vim.api.nvim_get_current_win())

        minifugit.status()
        local status_win = assert(minifugit.gsw.win)
        local status_buf = minifugit.gsw.buf.id
        local status_opts = capture_winopts(status_win)

        vim.api.nvim_set_current_win(status_win)
        normal_keys('<C-O>')
        wait_for_current_buf(file_buf, file_opts)

        local current_win = vim.api.nvim_get_current_win()
        assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
        assert_winopts(capture_winopts(current_win), file_opts)

        normal_keys('<C-I>')
        wait_for_current_buf(status_buf, status_opts)

        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert_winopts(
            capture_winopts(vim.api.nvim_get_current_win()),
            status_opts
        )
    end)

    it(
        'restores file options when Ctrl-O leaves a stacked diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo.number = true
            vim.wo.relativenumber = true
            vim.wo.signcolumn = 'yes:2'
            vim.wo.foldcolumn = '2'
            vim.wo.wrap = true
            vim.wo.cursorline = true
            vim.wo.winbar = 'real file diff jump'
            vim.wo.statuscolumn = 'diff-jump-statuscolumn'
            local file_opts = capture_winopts(vim.api.nvim_get_current_win())

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            local diff_win = assert(minifugit.gsw.diff_win)
            local diff_buf = minifugit.gsw.diff_buf.id
            local diff_opts = capture_winopts(diff_win)
            vim.api.nvim_set_current_win(diff_win)
            normal_keys('<C-O>')
            wait_for_current_buf(file_buf, file_opts)

            assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                file_opts
            )

            normal_keys('<C-I>')
            wait_for_current_buf(diff_buf, diff_opts)

            assert.are.equal(diff_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                diff_opts
            )
        end
    )

    it(
        'restores file options when a file replaces a stacked diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'other' })
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            local file_opts = capture_winopts(file_win)

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            vim.api.nvim_set_current_win(file_win)
            vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'other.txt')))
            assert.is_true(vim.wait(1000, function()
                return winopts_match(capture_winopts(file_win), file_opts)
            end))
            assert_winopts(capture_winopts(file_win), file_opts)
        end
    )

    it(
        'restores file options when a file replaces a split diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'other' })
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            local file_opts = capture_winopts(file_win)

            minifugit.options.preview.diff_layout = 'split'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            vim.api.nvim_set_current_win(file_win)
            vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'other.txt')))
            assert.is_true(vim.wait(1000, function()
                return winopts_match(capture_winopts(file_win), file_opts)
            end))
            assert_winopts(capture_winopts(file_win), file_opts)
        end
    )

    it(
        'restores file options when Ctrl-O leaves a split diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo.number = false
            vim.wo.relativenumber = true
            vim.wo.signcolumn = 'auto:2'
            vim.wo.foldcolumn = '1'
            vim.wo.wrap = true
            vim.wo.cursorline = true
            vim.wo.winbar = 'real file split jump'
            vim.wo.statuscolumn = 'split-jump-statuscolumn'
            local file_opts = capture_winopts(vim.api.nvim_get_current_win())

            minifugit.options.preview.diff_layout = 'split'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            local diff_win = assert(minifugit.gsw.diff_left_win)
            local diff_buf = minifugit.gsw.diff_left_buf.id
            local diff_opts = capture_winopts(diff_win)
            vim.api.nvim_set_current_win(diff_win)
            normal_keys('<C-O>')
            wait_for_current_buf(file_buf, file_opts)

            assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                file_opts
            )

            normal_keys('<C-I>')
            wait_for_current_buf(diff_buf, diff_opts)

            assert.are.equal(diff_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                diff_opts
            )
        end
    )
end)
