---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local project_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
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
        scrollbind = vim.wo[win].scrollbind,
        cursorbind = vim.wo[win].cursorbind,
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

---@param keys string
local function mapped_normal_keys(keys)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        'mx',
        false
    )
end

---@param action fun()
---@return string? message
---@return integer? level
local function capture_notification(action)
    local original_notify = vim.notify
    local message
    local level
    vim.notify = function(notified_message, notified_level)
        message = notified_message
        level = notified_level
    end
    local ok, err = pcall(action)
    vim.notify = original_notify
    if not ok then
        error(err, 0)
    end
    return message, level
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

---@param tabpage integer
---@return integer[]
local function status_windows(tabpage)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'minifugit' then
            table.insert(wins, win)
        end
    end
    return wins
end

---@param tabpage integer
---@return integer
local function activate_status_window(tabpage)
    vim.api.nvim_set_current_tabpage(tabpage)
    local win = status_windows(tabpage)[1]
    vim.api.nvim_set_current_win(win)
    return win
end

---@param bufnr integer
---@return integer?
local function win_showing_buf(bufnr)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            return win
        end
    end

    return nil
end

---@param buf integer
---@return boolean
local function has_source_syntax_extmarks(buf)
    local ns = vim.api.nvim_create_namespace('minifugit.ui.render')
    local marks =
        vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

    for _, mark in ipairs(marks) do
        local details = mark[4]
        local group = details and details.hl_group

        if
            type(group) == 'string'
            and (group:sub(1, 1) == '@' or group:match('^lua') ~= nil)
        then
            return true
        end
    end

    return false
end

describe('minifugit status UI', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type string?
    local other_repo
    ---@type string?
    local third_repo
    ---@type Minifugit
    local minifugit
    local status_window
    local restore_constructor

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
        other_repo = nil
        third_repo = nil
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
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20 },
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
        if other_repo ~= nil then
            vim.fn.delete(other_repo, 'rf')
        end
        if third_repo ~= nil then
            vim.fn.delete(third_repo, 'rf')
        end
    end)

    ---@class MinifugitTestStatusTab
    ---@field tabpage integer
    ---@field buffer integer

    ---@return MinifugitTestStatusTab
    ---@return MinifugitTestStatusTab
    local function open_two_status_tabs()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'changed A' }
        )
        minifugit.status()
        local status_a = {
            tabpage = vim.api.nvim_get_current_tabpage(),
            buffer = vim.api.nvim_get_current_buf(),
        }
        vim.cmd.tabnew()
        other_repo = helpers.change_to_other_repo(repo)
        helpers.write_file(vim.fs.joinpath(other_repo, 'only-b.txt'), { 'B' })
        minifugit.status()
        return status_a,
            {
                tabpage = vim.api.nvim_get_current_tabpage(),
                buffer = vim.api.nvim_get_current_buf(),
            }
    end

    ---@param status MinifugitTestStatusTab
    local function preview_tracked_entry(status)
        local win = activate_status_window(status.tabpage)
        vim.api.nvim_win_set_cursor(
            win,
            { helpers.row_containing(status.buffer, 'tracked.txt'), 0 }
        )
        mapped_normal_keys('=')
    end

    it(
        'opens and stages in an explicit linked worktree from repository A',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
            other_repo = helpers.clone_repo_with_changed_file(
                repo,
                'tracked.txt',
                { 'changed in main B' }
            )
            local worktree = vim.fs.joinpath(other_repo, 'linked-worktree')
            helpers.run(
                { 'git', 'worktree', 'add', '--detach', worktree },
                other_repo
            )
            helpers.write_file(vim.fs.joinpath(worktree, 'only-b.txt'), { 'B' })
            helpers.write_file(
                vim.fs.joinpath(worktree, 'tracked.txt'),
                { 'linked B' }
            )
            vim.fn.mkdir(vim.fs.joinpath(worktree, 'nested'), 'p')
            local cwd = vim.fn.getcwd()
            local tab = vim.api.nvim_get_current_tabpage()

            assert.is_true(
                minifugit.open({ cwd = worktree .. '/nested/../nested' })
            )

            local buf = vim.api.nvim_get_current_buf()
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(cwd, vim.fn.getcwd())
            assert_has_line(
                buffer_lines(buf),
                'Root: ' .. vim.fn.resolve(worktree)
            )
            assert_has_line(buffer_lines(buf), '?? only-b.txt')
            for _, line in ipairs(buffer_lines(buf)) do
                assert.is_nil(line:find('only-a.txt', 1, true))
            end
            vim.api.nvim_win_set_cursor(
                vim.api.nvim_get_current_win(),
                { helpers.row_containing(buf, 'tracked.txt'), 0 }
            )
            mapped_normal_keys('s')
            assert.are.equal(
                'tracked.txt\n',
                helpers.run(
                    { 'git', 'diff', '--cached', '--name-only' },
                    worktree
                )
            )
            assert.are.equal(
                '',
                helpers.run({ 'git', 'diff', '--cached', '--name-only' }, repo)
            )
            assert.are.equal(
                '',
                helpers.run(
                    { 'git', 'diff', '--cached', '--name-only' },
                    other_repo
                )
            )
            assert.are.equal(1, #status_windows(tab))
        end
    )

    it(
        'overrides global tab opening with false without mutating setup',
        function()
            minifugit.setup({ status = { open_in_tab = true } })
            local tab = vim.api.nvim_get_current_tabpage()
            local tabs = #vim.api.nvim_list_tabpages()

            assert.is_true(minifugit.open({ open_in_tab = false }))

            local buf = vim.api.nvim_get_current_buf()
            assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.is_true(minifugit.options.status.open_in_tab)
            mapped_normal_keys('q')
            assert.is_true(minifugit.open({}))
            assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
            assert.are_not.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.are_not.equal(buf, vim.api.nvim_get_current_buf())
            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.are.equal(
                1,
                #status_windows(vim.api.nvim_get_current_tabpage())
            )
            assert.is_true(minifugit.options.status.open_in_tab)
            mapped_normal_keys('q')
            assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
        end
    )

    it(
        'overrides global tab opening with true and reuses the owned root',
        function()
            local caller_tab = vim.api.nvim_get_current_tabpage()
            local tabs = #vim.api.nvim_list_tabpages()

            assert.is_true(minifugit.open({ cwd = repo, open_in_tab = true }))

            local owned_tab = vim.api.nvim_get_current_tabpage()
            local buf = vim.api.nvim_get_current_buf()
            assert.are_not.equal(caller_tab, owned_tab)
            assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
            assert.is_false(minifugit.options.status.open_in_tab)
            vim.api.nvim_set_current_tabpage(caller_tab)
            assert.is_true(minifugit.open({ cwd = repo, open_in_tab = true }))
            assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
            assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #status_windows(owned_tab))

            vim.api.nvim_set_current_tabpage(caller_tab)
            assert.is_true(minifugit.open({ cwd = repo, open_in_tab = false }))
            assert.are.equal(caller_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
            assert.are_not.equal(buf, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #status_windows(caller_tab))
            assert.are.equal(1, #status_windows(owned_tab))
        end
    )

    it('reopens hidden status in a tab when explicitly requested', function()
        local tab = vim.api.nvim_get_current_tabpage()
        local tabs = #vim.api.nvim_list_tabpages()
        assert.is_true(minifugit.open({ open_in_tab = false }))
        local buf = vim.api.nvim_get_current_buf()
        mapped_normal_keys('q')

        assert.is_true(minifugit.open({ open_in_tab = true }))

        local owned_tab = vim.api.nvim_get_current_tabpage()
        assert.are_not.equal(tab, owned_tab)
        assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        assert.are.equal(1, #status_windows(owned_tab))
        assert.are.equal(0, #status_windows(tab))
        mapped_normal_keys('q')
        assert.is_false(tabpage_is_valid(owned_tab))
        assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
    end)

    it('reopens hidden owned status in its surviving foreign tab', function()
        local tabs = #vim.api.nvim_list_tabpages()
        assert.is_true(minifugit.open({ open_in_tab = true }))
        local owned_tab = vim.api.nvim_get_current_tabpage()
        local status_win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        local target_win
        for _, win in ipairs(normal_windows(owned_tab)) do
            if win ~= status_win then
                target_win = win
            end
        end
        vim.api.nvim_win_call(target_win, function()
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
        end)
        local foreign_buf = vim.api.nvim_win_get_buf(target_win)
        helpers.settle_callbacks()
        mapped_normal_keys('q')
        assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
        assert.are.equal(0, #vim.fn.win_findbuf(buf))

        assert.is_true(minifugit.open({ open_in_tab = false }))

        local new_buf = vim.api.nvim_get_current_buf()
        assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        assert.are.equal(1, #status_windows(owned_tab))
        assert.are.equal(foreign_buf, vim.api.nvim_win_get_buf(target_win))
        mapped_normal_keys('q')
        assert.are.equal(0, #vim.fn.win_findbuf(new_buf))
        assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
        minifugit.reset()
        assert.is_false(vim.api.nvim_buf_is_valid(new_buf))
        assert.are.same({ target_win }, normal_windows(owned_tab))
    end)

    for _, open_in_tab in ipairs({ false, true }) do
        it(
            'focuses visible status despite a tab-mode override from '
                .. tostring(open_in_tab),
            function()
                assert.is_true(minifugit.open({
                    cwd = repo,
                    open_in_tab = open_in_tab,
                }))
                local tab = vim.api.nvim_get_current_tabpage()
                local tabs = #vim.api.nvim_list_tabpages()
                local win = vim.api.nvim_get_current_win()
                local buf = vim.api.nvim_get_current_buf()
                for _, other_win in ipairs(normal_windows(tab)) do
                    if other_win ~= win then
                        vim.api.nvim_set_current_win(other_win)
                        break
                    end
                end
                helpers.write_file(vim.fs.joinpath(repo, 'new.txt'), { 'new' })

                assert.is_true(minifugit.open({
                    cwd = repo,
                    open_in_tab = not open_in_tab,
                }))

                assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
                assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
                assert.are.equal(win, vim.api.nvim_get_current_win())
                assert.are.equal(buf, vim.api.nvim_get_current_buf())
                assert.are.equal(1, #status_windows(tab))
                assert_has_line(buffer_lines(buf), '?? new.txt')
                mapped_normal_keys('q')
                assert.are.equal(0, #vim.fn.win_findbuf(buf))
                assert.are.equal(
                    tabs - (open_in_tab and 1 or 0),
                    #vim.api.nvim_list_tabpages()
                )
            end
        )
    end

    it('validates constructor root before creating UI', function()
        local StatusWindow = require('minifugit.ui.status')
        local assert_editor_unchanged = helpers.snapshot_editor_state()
        for _, root in ipairs({ false, 42, {}, function() end }) do
            assert.has_error(function()
                StatusWindow.new(minifugit.options, root)
            end)
        end
        assert_editor_unchanged()
    end)

    it('validates a reused tab before creating UI', function()
        local StatusWindow = require('minifugit.ui.status')
        local assert_editor_unchanged = helpers.snapshot_editor_state()
        local tabpage = vim.api.nvim_get_current_tabpage()

        for _, reused_tab in ipairs({
            'tab',
            {},
            { tabpage = 'one', foreign_buffer = false },
            { tabpage = tabpage, foreign_buffer = 1 },
        }) do
            assert.has_error(function()
                StatusWindow.new(minifugit.options, repo, nil, reused_tab)
            end)
        end

        assert_editor_unchanged()
    end)

    it('rejects a non-git cwd without windows, buffers or tabs', function()
        other_repo = vim.fn.tempname()
        vim.fn.mkdir(other_repo, 'p')
        local assert_editor_unchanged = helpers.snapshot_editor_state()

        local ok, err = minifugit.open({ cwd = other_repo, open_in_tab = true })

        assert.is_nil(ok)
        assert.are.equal('string', type(err))
        assert_editor_unchanged()
    end)

    it('runs on_close once after q while keeping the hidden buffer', function()
        local calls = 0
        local win
        local closed = false
        assert.is_true(minifugit.open({
            on_close = function()
                calls = calls + 1
                closed = not vim.api.nvim_win_is_valid(win)
            end,
        }))
        win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        assert.are.equal(0, calls)

        mapped_normal_keys('q')

        assert.is_true(vim.wait(1000, function()
            return calls == 1
        end))
        assert.is_true(closed)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.are.equal(0, #vim.fn.win_findbuf(buf))
        minifugit.reset()
        helpers.settle_callbacks()
        assert.are.equal(1, calls)
    end)

    it('keeps on_close pending while its window hides the buffer', function()
        local calls = 0
        assert.is_true(minifugit.open({
            on_close = function()
                calls = calls + 1
            end,
        }))
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()

        vim.cmd('hide enew')

        helpers.settle_callbacks()
        assert.is_true(vim.api.nvim_win_is_valid(win))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.are.equal(0, #vim.fn.win_findbuf(buf))
        assert.are.equal(0, calls)

        vim.api.nvim_win_close(win, true)

        assert.is_true(vim.wait(1000, function()
            return calls == 1
        end))
        assert.is_false(vim.api.nvim_win_is_valid(win))
        minifugit.reset()
        helpers.settle_callbacks()
        assert.are.equal(1, calls)
    end)

    it(
        'keeps on_close pending until all tracked hidden windows close',
        function()
            local calls = 0
            assert.is_true(minifugit.open({
                on_close = function()
                    calls = calls + 1
                end,
            }))
            local first = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_get_current_buf()
            vim.cmd.vsplit()
            local second = vim.api.nvim_get_current_win()

            vim.cmd('hide enew')
            vim.api.nvim_set_current_win(first)
            vim.cmd('hide enew')

            helpers.settle_callbacks()
            assert.is_true(vim.api.nvim_win_is_valid(first))
            assert.is_true(vim.api.nvim_win_is_valid(second))
            assert.are.equal(0, #vim.fn.win_findbuf(buf))
            assert.are.equal(0, calls)

            vim.api.nvim_win_close(first, true)

            helpers.settle_callbacks()
            assert.are.equal(0, calls)
            assert.is_true(vim.api.nvim_win_is_valid(second))

            vim.api.nvim_win_close(second, true)

            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, calls)
        end
    )

    for _, action in ipairs({
        'bdelete',
        'bunload',
        'bwipeout',
        'reset',
        'destroy',
    }) do
        it('runs on_close once after hidden ' .. action, function()
            local calls = 0
            assert.is_true(minifugit.open({
                on_close = function()
                    calls = calls + 1
                end,
            }))
            local gsw = status_window()
            local win = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_get_current_buf()
            vim.cmd('hide enew')
            helpers.settle_callbacks()
            assert.are.equal(0, calls)

            if action == 'reset' then
                minifugit.reset()
            elseif action == 'destroy' then
                assert.is_true(gsw:destroy())
            else
                vim.cmd[action]({ tostring(buf), bang = true })
            end

            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
            assert.is_false(vim.api.nvim_buf_is_loaded(buf))
            assert.is_true(vim.api.nvim_win_is_valid(win))

            vim.api.nvim_win_close(win, true)
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, calls)
        end)
    end

    it('keeps on_close pending until the last status view closes', function()
        local calls = 0
        local buf
        local gone = false
        assert.is_true(minifugit.open({
            on_close = function()
                calls = calls + 1
                gone = #vim.fn.win_findbuf(buf) == 0
            end,
        }))
        buf = vim.api.nvim_get_current_buf()
        local tab = vim.api.nvim_get_current_tabpage()
        vim.cmd.vsplit()
        assert.are.equal(2, #vim.fn.win_findbuf(buf))

        mapped_normal_keys('q')

        helpers.settle_callbacks()
        assert.are.equal(1, #status_windows(tab))
        assert.are.equal(1, #vim.fn.win_findbuf(buf))
        assert.are.equal(0, calls)
        vim.cmd.close()
        assert.is_true(vim.wait(1000, function()
            return calls == 1
        end))
        assert.is_true(gone)
        assert.are.equal(0, #status_windows(tab))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        minifugit.reset()
        helpers.settle_callbacks()
        assert.are.equal(1, calls)
    end)

    it(
        'waits for close to finish when BufWinLeave runs scheduled work',
        function()
            local calls = 0
            local win
            local buf
            local gone = false
            assert.is_true(minifugit.open({
                on_close = function()
                    calls = calls + 1
                    gone = not vim.api.nvim_win_is_valid(win)
                        and #vim.fn.win_findbuf(buf) == 0
                end,
            }))
            win = vim.api.nvim_get_current_win()
            buf = vim.api.nvim_get_current_buf()
            local during_leave
            local shown_during_leave = false
            vim.api.nvim_create_autocmd('BufWinLeave', {
                buffer = buf,
                once = true,
                callback = function()
                    helpers.settle_callbacks()
                    during_leave = calls
                    shown_during_leave = vim.api.nvim_win_is_valid(win)
                        and vim.api.nvim_win_get_buf(win) == buf
                end,
            })

            vim.cmd.close()

            assert.is_true(shown_during_leave)
            assert.are.equal(0, during_leave)
            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
            assert.is_true(gone)
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, calls)
        end
    )

    for _, action in ipairs({
        'close',
        'bdelete',
        'bunload',
        'bwipeout',
        'tabclose',
        'reset',
    }) do
        it('runs on_close once after ' .. action, function()
            local calls = 0
            local buf
            local gone = false
            local tabs = #vim.api.nvim_list_tabpages()
            assert.is_true(minifugit.open({
                open_in_tab = action == 'tabclose',
                on_close = function()
                    calls = calls + 1
                    gone = #vim.fn.win_findbuf(buf) == 0
                end,
            }))
            buf = vim.api.nvim_get_current_buf()
            local tab = vim.api.nvim_get_current_tabpage()
            assert.are.equal(0, calls)

            if action == 'reset' then
                minifugit.reset()
            elseif action == 'close' or action == 'tabclose' then
                vim.cmd[action]()
            else
                vim.cmd[action]({ tostring(buf), bang = true })
            end

            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
            assert.is_true(gone)
            if action == 'close' then
                assert.is_true(vim.api.nvim_buf_is_valid(buf))
            elseif action == 'tabclose' then
                assert.is_false(tabpage_is_valid(tab))
                assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
            elseif action == 'reset' or action == 'bwipeout' then
                assert.is_false(vim.api.nvim_buf_is_valid(buf))
            else
                assert.is_false(vim.api.nvim_buf_is_loaded(buf))
            end
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, calls)
        end)
    end

    it(
        'keeps callbacks pending through refresh and a second visible open',
        function()
            local calls = {}
            minifugit.open({
                on_close = function()
                    table.insert(calls, 'first')
                end,
            })
            local win = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_get_current_buf()
            mapped_normal_keys('r')
            assert.is_true(minifugit.open({
                on_close = function()
                    table.insert(calls, 'second')
                end,
            }))
            helpers.settle_callbacks()
            assert.are.same({}, calls)
            assert.are.equal(win, vim.api.nvim_get_current_win())
            assert.are.equal(buf, vim.api.nvim_get_current_buf())

            mapped_normal_keys('q')

            assert.is_true(vim.wait(1000, function()
                return #calls == 2
            end))
            assert.are.same({ 'first', 'second' }, calls)
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.same({ 'first', 'second' }, calls)
        end
    )

    it(
        'keeps all callbacks pending through a same-tick hidden reopen',
        function()
            local old_calls = 0
            local new_calls = 0
            local calls = {}
            minifugit.open({
                on_close = function()
                    old_calls = old_calls + 1
                    table.insert(calls, 'old')
                end,
            })
            local old_buf = vim.api.nvim_get_current_buf()
            mapped_normal_keys('q')
            assert.is_true(minifugit.open({
                on_close = function()
                    new_calls = new_calls + 1
                    table.insert(calls, 'new')
                end,
            }))
            helpers.settle_callbacks()
            assert.are.equal(old_buf, vim.api.nvim_get_current_buf())
            assert.are.equal(0, old_calls)
            assert.are.equal(0, new_calls)
            mapped_normal_keys('q')
            assert.is_true(vim.wait(1000, function()
                return new_calls == 1
            end))
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, old_calls)
            assert.are.equal(1, new_calls)
            assert.are.same({ 'old', 'new' }, calls)
        end
    )

    it('registers new callbacks after a settled hidden close', function()
        local calls = {}
        assert.is_true(minifugit.open({
            on_close = function()
                table.insert(calls, 'old')
            end,
        }))
        local buf = vim.api.nvim_get_current_buf()
        mapped_normal_keys('q')
        helpers.settle_callbacks()
        assert.are.same({ 'old' }, calls)

        assert.is_true(minifugit.open({
            on_close = function()
                table.insert(calls, 'new')
            end,
        }))

        helpers.settle_callbacks()
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        assert.are.same({ 'old' }, calls)
        mapped_normal_keys('q')
        helpers.settle_callbacks()
        assert.are.same({ 'old', 'new' }, calls)
        minifugit.reset()
        helpers.settle_callbacks()
        assert.are.same({ 'old', 'new' }, calls)
    end)

    it('logs a failing callback and still runs later callbacks', function()
        local calls = {}
        minifugit.open({
            on_close = function()
                table.insert(calls, 'first')
                error('test on_close failure')
            end,
        })
        minifugit.open({
            on_close = function()
                table.insert(calls, 'second')
            end,
        })
        mapped_normal_keys('q')
        assert.is_true(vim.wait(1000, function()
            return #calls == 2
        end))
        assert.are.same({ 'first', 'second' }, calls)
        helpers.assert_has_line_containing(
            vim.fn.readfile(require('minifugit.log').path()),
            'on_close callback failed:'
        )
        helpers.assert_has_line_containing(
            vim.fn.readfile(require('minifugit.log').path()),
            'test on_close failure'
        )
    end)

    it(
        'replaces a visible root when cwd is explicit and closes old callbacks',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
            other_repo = helpers.clone_repo_with_changed_file(
                repo,
                'only-b.txt',
                { 'B' }
            )
            local calls = 0
            local old_gone = false
            local old_buf
            minifugit.open({
                on_close = function()
                    calls = calls + 1
                    old_gone = not vim.api.nvim_buf_is_valid(old_buf)
                end,
            })
            old_buf = vim.api.nvim_get_current_buf()
            local tab = vim.api.nvim_get_current_tabpage()
            local tabs = #vim.api.nvim_list_tabpages()

            assert.is_true(minifugit.open({ cwd = other_repo }))

            local buf = vim.api.nvim_get_current_buf()
            assert.are_not.equal(old_buf, buf)
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
            assert.are.equal(1, #status_windows(tab))
            assert_has_line(buffer_lines(buf), '?? only-b.txt')
            assert_has_line(
                buffer_lines(buf),
                'Root: ' .. vim.fn.resolve(other_repo)
            )
            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
            assert.is_true(old_gone)
            minifugit.reset()
            helpers.settle_callbacks()
            assert.are.equal(1, calls)
        end
    )

    it('keeps the visible pin when open omits cwd after cwd changes', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        local calls = 0
        minifugit.open({
            on_close = function()
                calls = calls + 1
            end,
        })
        local buf = vim.api.nvim_get_current_buf()
        other_repo = helpers.change_to_other_repo(repo)
        helpers.write_file(vim.fs.joinpath(other_repo, 'only-b.txt'), { 'B' })

        assert.is_true(minifugit.open({}))

        helpers.settle_callbacks()
        assert.are.equal(0, calls)
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        assert_has_line(buffer_lines(buf), 'Root: ' .. vim.fn.resolve(repo))
        assert_has_line(buffer_lines(buf), '?? only-a.txt')
        for _, line in ipairs(buffer_lines(buf)) do
            assert.is_nil(line:find('only-b.txt', 1, true))
        end
    end)

    for _, open_in_tab in ipairs({ false, true }) do
        it(
            'replaces an owned root without duplicates with open_in_tab='
                .. tostring(open_in_tab),
            function()
                other_repo = helpers.clone_repo_with_changed_file(
                    repo,
                    'only-b.txt',
                    { 'B' }
                )
                local tabs = #vim.api.nvim_list_tabpages()
                local calls = 0
                minifugit.open({
                    open_in_tab = true,
                    on_close = function()
                        calls = calls + 1
                    end,
                })
                local old_buf = vim.api.nvim_get_current_buf()
                assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())

                assert.is_true(minifugit.open({
                    cwd = other_repo,
                    open_in_tab = open_in_tab,
                }))

                local buf = vim.api.nvim_get_current_buf()
                local tab = vim.api.nvim_get_current_tabpage()
                local tabs_after = #vim.api.nvim_list_tabpages()
                assert.are.equal(tabs + (open_in_tab and 1 or 0), tabs_after)
                assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
                assert_has_line(buffer_lines(buf), '?? only-b.txt')
                assert_has_line(
                    buffer_lines(buf),
                    'Root: ' .. vim.fn.resolve(other_repo)
                )
                assert.is_true(minifugit.open({
                    cwd = other_repo,
                    open_in_tab = open_in_tab,
                }))
                assert.are.equal(buf, vim.api.nvim_get_current_buf())
                assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
                assert.are.equal(tabs_after, #vim.api.nvim_list_tabpages())
                local status_count = 0
                for _, page in ipairs(vim.api.nvim_list_tabpages()) do
                    status_count = status_count + #status_windows(page)
                end
                assert.are.equal(1, status_count)
                assert.is_true(vim.wait(1000, function()
                    return calls == 1
                end))
            end
        )
    end

    it('reuses surviving status after replacing an owned tab', function()
        other_repo =
            helpers.clone_repo_with_changed_file(repo, 'only-b.txt', { 'B' })
        local tabs = #vim.api.nvim_list_tabpages()
        local wins = #vim.api.nvim_list_wins()
        local tab_a = vim.api.nvim_get_current_tabpage()
        assert.is_true(minifugit.open({ cwd = repo, open_in_tab = false }))
        local win_a = vim.api.nvim_get_current_win()
        local buf_a = vim.api.nvim_get_current_buf()
        vim.cmd.tabnew()
        local launch_tab = vim.api.nvim_get_current_tabpage()
        assert.is_true(minifugit.open({
            cwd = other_repo,
            open_in_tab = true,
        }))
        local tab_b = vim.api.nvim_get_current_tabpage()
        local buf_b = vim.api.nvim_get_current_buf()
        vim.cmd(vim.api.nvim_tabpage_get_number(launch_tab) .. 'tabclose')
        assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
        helpers.write_file(vim.fs.joinpath(repo, 'new-a.txt'), { 'new A' })

        assert.is_true(minifugit.open({ cwd = repo, open_in_tab = false }))

        assert.are.equal(tab_a, vim.api.nvim_get_current_tabpage())
        assert.are.equal(1, #status_windows(tab_a))
        assert.are.equal(win_a, vim.api.nvim_get_current_win())
        assert.are.equal(buf_a, vim.api.nvim_get_current_buf())
        assert_has_line(buffer_lines(buf_a), '?? new-a.txt')
        assert.is_false(tabpage_is_valid(tab_b))
        assert.is_false(vim.api.nvim_buf_is_valid(buf_b))
        assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
        mapped_normal_keys('q')
        assert.are.equal(0, #status_windows(tab_a))
        assert.are.equal(0, #vim.fn.win_findbuf(buf_a))
        assert.is_true(minifugit.open({ cwd = repo, open_in_tab = false }))
        assert.are.equal(buf_a, vim.api.nvim_get_current_buf())
        assert.are.equal(1, #status_windows(tab_a))
        minifugit.reset()
        helpers.settle_callbacks()
        assert.is_false(vim.api.nvim_buf_is_valid(buf_a))
        assert.are.equal(0, #status_windows(tab_a))
        assert.are.equal(wins, #vim.api.nvim_list_wins())
        assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
    end)

    for _, open_in_tab in ipairs({ false, true }) do
        it(
            'keeps an unrelated status window exposed by re-pinning an owned tab with open_in_tab='
                .. tostring(open_in_tab),
            function()
                other_repo = helpers.clone_repo_with_changed_file(
                    repo,
                    'only-b.txt',
                    { 'B' }
                )
                third_repo = helpers.clone_repo_with_changed_file(
                    repo,
                    'only-c.txt',
                    { 'C' }
                )
                local tabs = #vim.api.nvim_list_tabpages()
                local tab_a = vim.api.nvim_get_current_tabpage()
                local calls_a = 0
                assert.is_true(minifugit.open({
                    cwd = repo,
                    open_in_tab = false,
                    on_close = function()
                        calls_a = calls_a + 1
                    end,
                }))
                local win_a = vim.api.nvim_get_current_win()
                local buf_a = vim.api.nvim_get_current_buf()
                vim.cmd.tabnew()
                local launch_tab = vim.api.nvim_get_current_tabpage()
                assert.is_true(minifugit.open({
                    cwd = other_repo,
                    open_in_tab = true,
                }))
                local tab_b = vim.api.nvim_get_current_tabpage()
                local buf_b = vim.api.nvim_get_current_buf()
                vim.cmd(
                    vim.api.nvim_tabpage_get_number(launch_tab) .. 'tabclose'
                )
                assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())

                assert.is_true(minifugit.open({
                    cwd = third_repo,
                    open_in_tab = open_in_tab,
                }))

                helpers.settle_callbacks()
                local tab_c = vim.api.nvim_get_current_tabpage()
                local buf_c = vim.api.nvim_get_current_buf()
                assert.are.equal(0, calls_a)
                assert.is_false(tabpage_is_valid(tab_b))
                assert.is_false(vim.api.nvim_buf_is_valid(buf_b))
                assert.is_true(vim.api.nvim_buf_is_valid(buf_a))
                assert.are.equal(tab_a, vim.api.nvim_win_get_tabpage(win_a))
                assert.are.equal(buf_a, vim.api.nvim_win_get_buf(win_a))
                assert.are.equal(1, #status_windows(tab_a))
                assert_has_line(
                    buffer_lines(buf_a),
                    'Root: ' .. vim.fn.resolve(repo)
                )
                assert.are_not.equal(tab_a, tab_c)
                assert.are.equal(1, #status_windows(tab_c))
                assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())
                assert_has_line(buffer_lines(buf_c), '?? only-c.txt')
                assert_has_line(
                    buffer_lines(buf_c),
                    'Root: ' .. vim.fn.resolve(third_repo)
                )
                mapped_normal_keys('q')
                assert.is_false(tabpage_is_valid(tab_c))
                assert.are.equal(tab_a, vim.api.nvim_get_current_tabpage())
                assert.are.equal(1, #status_windows(tab_a))
            end
        )
    end

    for _, root_differs in ipairs({ false, true }) do
        it(
            'reuses surviving status after hidden owned '
                .. (root_differs and 're-pin' or 'mode change'),
            function()
                local owned_root = repo
                if root_differs then
                    other_repo = helpers.clone_repo_with_changed_file(
                        repo,
                        'only-b.txt',
                        { 'B' }
                    )
                    owned_root = other_repo
                end
                local tabs = #vim.api.nvim_list_tabpages()
                local wins = #vim.api.nvim_list_wins()
                local tab_a = vim.api.nvim_get_current_tabpage()
                assert.is_true(minifugit.open({
                    cwd = repo,
                    open_in_tab = false,
                }))
                local win_a = vim.api.nvim_get_current_win()
                local buf_a = vim.api.nvim_get_current_buf()
                vim.cmd.tabnew()
                local launch_tab = vim.api.nvim_get_current_tabpage()
                assert.is_true(minifugit.open({
                    cwd = owned_root,
                    open_in_tab = true,
                }))
                local owned_tab = vim.api.nvim_get_current_tabpage()
                local owned_win = vim.api.nvim_get_current_win()
                local owned_buf = vim.api.nvim_get_current_buf()
                vim.cmd(
                    vim.api.nvim_tabpage_get_number(launch_tab) .. 'tabclose'
                )
                for _, win in ipairs(normal_windows(owned_tab)) do
                    if win ~= owned_win then
                        vim.api.nvim_win_set_buf(
                            owned_win,
                            vim.api.nvim_win_get_buf(win)
                        )
                        break
                    end
                end
                assert.are.equal(0, #vim.fn.win_findbuf(owned_buf))
                assert.are.equal(tabs + 1, #vim.api.nvim_list_tabpages())

                assert.is_true(minifugit.open({
                    cwd = repo,
                    open_in_tab = false,
                }))

                assert.are.equal(tab_a, vim.api.nvim_get_current_tabpage())
                assert.are.equal(win_a, vim.api.nvim_get_current_win())
                assert.are.equal(buf_a, vim.api.nvim_get_current_buf())
                assert.are.equal(1, #status_windows(tab_a))
                assert.is_false(tabpage_is_valid(owned_tab))
                assert.is_false(vim.api.nvim_buf_is_valid(owned_buf))
                assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
                minifugit.reset()
                helpers.settle_callbacks()
                assert.is_false(vim.api.nvim_buf_is_valid(buf_a))
                assert.are.equal(0, #status_windows(tab_a))
                assert.are.equal(wins, #vim.api.nvim_list_wins())
            end
        )
    end

    it(
        're-pins a hidden window to explicit cwd instead of the editor cwd',
        function()
            other_repo = helpers.clone_repo_with_changed_file(
                repo,
                'only-b.txt',
                { 'B' }
            )
            minifugit.open({})
            local old_buf = vim.api.nvim_get_current_buf()
            local tab = vim.api.nvim_get_current_tabpage()
            mapped_normal_keys('q')
            local calls = 0

            assert.is_true(minifugit.open({
                cwd = other_repo,
                on_close = function()
                    calls = calls + 1
                end,
            }))

            helpers.settle_callbacks()
            assert.are.equal(0, calls)
            assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
            assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
            assert_has_line(
                buffer_lines(vim.api.nvim_get_current_buf()),
                '?? only-b.txt'
            )
            assert.are.equal(1, #status_windows(tab))
            mapped_normal_keys('q')
            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
        end
    )

    it(
        'leaves a visible status window and callback intact on cwd failure',
        function()
            local calls = 0
            minifugit.open({
                on_close = function()
                    calls = calls + 1
                end,
            })
            local assert_editor_unchanged = helpers.snapshot_editor_state()
            local ok, err = minifugit.open({
                cwd = vim.fs.joinpath(repo, 'missing'),
                open_in_tab = true,
            })
            assert.is_nil(ok)
            assert.are.equal('string', type(err))
            helpers.settle_callbacks()
            assert_editor_unchanged()
            assert.are.equal(0, calls)
            mapped_normal_keys('q')
            assert.is_true(vim.wait(1000, function()
                return calls == 1
            end))
        end
    )

    it('shows independent repository entries in two tabpages', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        minifugit.status()
        local tab_a = vim.api.nvim_get_current_tabpage()
        local buf_a = vim.api.nvim_get_current_buf()

        vim.cmd.tabnew()
        other_repo = helpers.change_to_other_repo(repo)
        helpers.write_file(vim.fs.joinpath(other_repo, 'only-b.txt'), { 'B' })
        local tab_b = vim.api.nvim_get_current_tabpage()

        minifugit.status()

        local buf_b = vim.api.nvim_get_current_buf()
        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage())
        assert.are_not.equal(buf_a, buf_b)
        assert_has_line(buffer_lines(buf_a), '?? only-a.txt')
        assert_has_line(buffer_lines(buf_b), '?? only-b.txt')
        assert_has_line(buffer_lines(buf_a), 'Root: ' .. vim.fn.resolve(repo))
        assert_has_line(
            buffer_lines(buf_b),
            'Root: ' .. vim.fn.resolve(other_repo)
        )
        for _, line in ipairs(buffer_lines(buf_a)) do
            assert.is_nil(line:find('only-b.txt', 1, true))
        end
        for _, line in ipairs(buffer_lines(buf_b)) do
            assert.is_nil(line:find('only-a.txt', 1, true))
        end
        assert.is_true(tabpage_is_valid(tab_a))
    end)

    it('keeps one status window per tab for the same repository', function()
        minifugit.status()
        local tab_a = vim.api.nvim_get_current_tabpage()
        local buf_a = vim.api.nvim_get_current_buf()
        minifugit.status()
        assert.are.same(
            { vim.api.nvim_get_current_win() },
            status_windows(tab_a)
        )
        assert.are.equal(buf_a, vim.api.nvim_get_current_buf())

        vim.cmd.tabnew()
        local tab_b = vim.api.nvim_get_current_tabpage()
        minifugit.status()
        local buf_b = vim.api.nvim_get_current_buf()
        minifugit.status()

        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage())
        assert.are_not.equal(buf_a, buf_b)
        assert.are.same(
            { vim.api.nvim_get_current_win() },
            status_windows(tab_b)
        )
        assert.are.equal(buf_b, vim.api.nvim_get_current_buf())
        assert.are.equal(1, #status_windows(tab_a))
    end)

    it(
        'stages through the second tab keymap without changing the first',
        function()
            local status_a, status_b = open_two_status_tabs()
            vim.api.nvim_win_set_cursor(
                vim.api.nvim_get_current_win(),
                { helpers.row_containing(status_b.buffer, 'tracked.txt'), 0 }
            )

            mapped_normal_keys('s')

            assert.are.equal(
                'tracked.txt\n',
                helpers.run(
                    { 'git', 'diff', '--cached', '--name-only' },
                    other_repo
                )
            )
            assert.are.equal(
                '',
                helpers.run({ 'git', 'diff', '--cached', '--name-only' }, repo)
            )
            assert_has_line(buffer_lines(status_b.buffer), 'Staged (1)')
            assert_has_line(buffer_lines(status_b.buffer), 'M  tracked.txt')
            vim.api.nvim_set_current_tabpage(status_a.tabpage)
            minifugit.status()
            assert.are.equal(status_a.buffer, vim.api.nvim_get_current_buf())
            assert_has_line(buffer_lines(status_a.buffer), 'Unstaged (1)')
            assert_has_line(buffer_lines(status_a.buffer), ' M tracked.txt')
            assert_has_line(buffer_lines(status_a.buffer), '?? only-a.txt')
            assert.are.equal(1, #status_windows(status_b.tabpage))
        end
    )

    for _, action in ipairs({ 'close', 'reset' }) do
        it(
            action .. ' in one tab leaves the other status refreshable',
            function()
                local status_a, status_b = open_two_status_tabs()
                vim.api.nvim_set_current_tabpage(status_a.tabpage)
                minifugit.status()
                if action == 'close' then
                    mapped_normal_keys('q')
                else
                    minifugit.reset()
                    assert.is_false(vim.api.nvim_buf_is_valid(status_a.buffer))
                end
                assert.are.equal(0, #status_windows(status_a.tabpage))

                helpers.write_file(
                    vim.fs.joinpath(other_repo, 'new-in-b.txt'),
                    { 'new B' }
                )
                vim.api.nvim_set_current_tabpage(status_b.tabpage)
                minifugit.status()

                assert.are.equal(
                    status_b.buffer,
                    vim.api.nvim_get_current_buf()
                )
                assert.are.equal(1, #status_windows(status_b.tabpage))
                assert_has_line(
                    buffer_lines(status_b.buffer),
                    '?? new-in-b.txt'
                )
                assert_has_line(buffer_lines(status_b.buffer), '?? only-b.txt')
                vim.api.nvim_set_current_tabpage(status_a.tabpage)
                vim.cmd.cd(vim.fn.fnameescape(repo))
                minifugit.status()
                assert.are.equal(1, #status_windows(status_a.tabpage))
                assert_has_line(
                    buffer_lines(vim.api.nvim_get_current_buf()),
                    '?? only-a.txt'
                )
                if action == 'close' then
                    assert.are.equal(
                        status_a.buffer,
                        vim.api.nvim_get_current_buf()
                    )
                else
                    assert.are_not.equal(
                        status_a.buffer,
                        vim.api.nvim_get_current_buf()
                    )
                end
            end
        )
    end

    it('keeps a moved status alive after its source tab closes', function()
        minifugit.status()
        local source_tab = vim.api.nvim_get_current_tabpage()
        local status_buf = vim.api.nvim_get_current_buf()
        normal_keys('<C-W>T')
        local moved_tab = vim.api.nvim_get_current_tabpage()
        assert.are_not.equal(source_tab, moved_tab)

        vim.api.nvim_set_current_tabpage(source_tab)
        vim.cmd.tabclose()
        local settled = false
        vim.schedule(function()
            settled = true
        end)
        assert.is_true(vim.wait(1000, function()
            return settled
        end))

        assert.is_true(vim.api.nvim_buf_is_valid(status_buf))
        assert.are.equal(1, #status_windows(moved_tab))
        minifugit.status()
        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        minifugit.reset()
        assert.is_false(vim.api.nvim_buf_is_valid(status_buf))
    end)

    it('reuses moved status only in its destination tab', function()
        minifugit.status()
        local source_tab = vim.api.nvim_get_current_tabpage()
        local moved_buf = vim.api.nvim_get_current_buf()
        normal_keys('<C-W>T')
        local moved_tab = vim.api.nvim_get_current_tabpage()

        minifugit.status()
        assert.are.equal(moved_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(1, #status_windows(moved_tab))

        vim.api.nvim_set_current_tabpage(source_tab)
        minifugit.status()
        local source_buf = vim.api.nvim_get_current_buf()
        assert.are.equal(source_tab, vim.api.nvim_get_current_tabpage())
        assert.are_not.equal(moved_buf, source_buf)
        assert.are.equal(1, #status_windows(source_tab))

        vim.api.nvim_set_current_tabpage(moved_tab)
        vim.cmd.bdelete({ tostring(moved_buf), bang = true })
        local settled = false
        vim.schedule(function()
            settled = true
        end)
        assert.is_true(vim.wait(1000, function()
            return settled
        end))
        assert.is_false(vim.api.nvim_buf_is_valid(moved_buf))
        vim.api.nvim_set_current_tabpage(source_tab)
        minifugit.status()
        assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
    end)

    it('finds a moved owned status tab from its original caller', function()
        minifugit.setup({ status = { open_in_tab = true } })
        local caller_tab = vim.api.nvim_get_current_tabpage()
        minifugit.status()
        local source_tab = vim.api.nvim_get_current_tabpage()
        local status_buf = vim.api.nvim_get_current_buf()
        normal_keys('<C-W>T')
        local moved_tab = vim.api.nvim_get_current_tabpage()

        vim.api.nvim_set_current_tabpage(source_tab)
        vim.cmd.tabclose()
        vim.api.nvim_set_current_tabpage(caller_tab)
        local tabs_before = #vim.api.nvim_list_tabpages()
        minifugit.status()

        assert.are.equal(moved_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        minifugit.reset()
        assert.is_false(vim.api.nvim_buf_is_valid(status_buf))
        assert.is_false(tabpage_is_valid(moved_tab))
    end)

    it(
        'retires destination status without closing its foreign file tab',
        function()
            minifugit.setup({ status = { open_in_tab = true } })
            local status_a, status_b = open_two_status_tabs()
            activate_status_window(status_a.tabpage)
            local win_a = vim.api.nvim_get_current_win()
            local file_a_win
            for _, win in ipairs(normal_windows(status_a.tabpage)) do
                if win ~= win_a then
                    file_a_win = win
                    break
                end
            end
            vim.api.nvim_set_current_win(file_a_win)
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_a_buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_win_close(win_a, true)

            local win_b = activate_status_window(status_b.tabpage)
            local file_b_win
            for _, win in ipairs(normal_windows(status_b.tabpage)) do
                if win ~= win_b then
                    file_b_win = win
                    break
                end
            end
            vim.api.nvim_set_current_win(file_b_win)
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(other_repo, 'tracked.txt'))
            )
            local file_b_buf = vim.api.nvim_get_current_buf()
            local tabs_before = #vim.api.nvim_list_tabpages()

            vim.cmd.sbuffer({
                tostring(status_a.buffer),
                mods = { vertical = true },
            })

            assert.are.equal(
                status_b.tabpage,
                vim.api.nvim_get_current_tabpage()
            )
            assert.are.equal(status_a.buffer, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #status_windows(status_b.tabpage))
            assert.is_false(vim.api.nvim_buf_is_valid(status_b.buffer))
            assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
            assert.are.equal(file_a_buf, vim.api.nvim_win_get_buf(file_a_win))
            assert.are.equal(file_b_buf, vim.api.nvim_win_get_buf(file_b_win))

            minifugit.reset()

            assert.is_false(vim.api.nvim_buf_is_valid(status_a.buffer))
            assert.is_true(tabpage_is_valid(status_b.tabpage))
            assert.are.equal(file_b_buf, vim.api.nvim_win_get_buf(file_b_win))
            assert.are.equal(file_a_buf, vim.api.nvim_win_get_buf(file_a_win))
        end
    )

    it(
        'cleans up a closed tab without disturbing another status tab',
        function()
            local status_a, status_b = open_two_status_tabs()
            vim.api.nvim_set_current_tabpage(status_a.tabpage)

            vim.cmd.tabclose()

            assert.is_true(vim.wait(1000, function()
                return not vim.api.nvim_buf_is_valid(status_a.buffer)
            end))
            assert.is_false(tabpage_is_valid(status_a.tabpage))
            vim.api.nvim_set_current_tabpage(status_b.tabpage)
            minifugit.status()
            assert.are.equal(status_b.buffer, vim.api.nvim_get_current_buf())
            assert_has_line(buffer_lines(status_b.buffer), '?? only-b.txt')

            vim.cmd.tabnew()
            vim.cmd.cd(vim.fn.fnameescape(repo))
            local fresh_tab = vim.api.nvim_get_current_tabpage()
            minifugit.status()
            assert.are.equal(fresh_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(1, #status_windows(fresh_tab))
            assert_has_line(
                buffer_lines(vim.api.nvim_get_current_buf()),
                '?? only-a.txt'
            )
            assert.are.equal(1, #status_windows(status_b.tabpage))
        end
    )

    for _, command in ipairs({ 'bdelete', 'bunload', 'bwipeout' }) do
        it(
            command
                .. ' cleans only its own status entry, even after replacement',
            function()
                local status_a, status_b = open_two_status_tabs()
                vim.api.nvim_set_current_tabpage(status_a.tabpage)
                vim.cmd[command]({ tostring(status_a.buffer), bang = true })
                vim.cmd.cd(vim.fn.fnameescape(repo))
                minifugit.status()
                local replacement_buf = vim.api.nvim_get_current_buf()
                assert.are_not.equal(status_a.buffer, replacement_buf)

                vim.api.nvim_set_current_tabpage(status_b.tabpage)
                helpers.write_file(
                    vim.fs.joinpath(other_repo, 'new-in-b.txt'),
                    { 'B' }
                )
                minifugit.status()
                local settled = false
                vim.schedule(function()
                    settled = true
                end)
                assert.is_true(vim.wait(1000, function()
                    return settled
                end))

                assert.are.equal(
                    status_b.buffer,
                    vim.api.nvim_get_current_buf()
                )
                assert_has_line(
                    buffer_lines(status_b.buffer),
                    '?? new-in-b.txt'
                )
                assert.are.equal(1, #status_windows(status_b.tabpage))
                assert.is_true(vim.api.nvim_buf_is_valid(replacement_buf))
                assert.are.equal(1, #status_windows(status_a.tabpage))
                vim.api.nvim_set_current_tabpage(status_a.tabpage)
                minifugit.status()
                assert.are.equal(
                    replacement_buf,
                    vim.api.nvim_get_current_buf()
                )
                assert_has_line(buffer_lines(replacement_buf), '?? only-a.txt')
            end
        )
    end

    it(
        'reuses an owned tab for its root when status is called from any tab',
        function()
            minifugit.setup({ status = { open_in_tab = true } })
            local caller_tab = vim.api.nvim_get_current_tabpage()
            local initial_tabs = #vim.api.nvim_list_tabpages()
            minifugit.status()
            local owned_tab = vim.api.nvim_get_current_tabpage()
            local status_buf = vim.api.nvim_get_current_buf()
            minifugit.status()
            assert.are.equal(initial_tabs + 1, #vim.api.nvim_list_tabpages())
            assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #status_windows(owned_tab))

            vim.api.nvim_set_current_tabpage(caller_tab)
            helpers.write_file(
                vim.fs.joinpath(repo, 'new-entry.txt'),
                { 'new' }
            )
            minifugit.status()
            assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
            assert_has_line(buffer_lines(status_buf), '?? new-entry.txt')
            assert.are.equal(initial_tabs + 1, #vim.api.nvim_list_tabpages())

            vim.cmd.tabnew()
            local tabs_before = #vim.api.nvim_list_tabpages()
            minifugit.status()
            assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
            assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        end
    )

    for _, closed_side in ipairs({ 'left', 'right' }) do
        it(
            'repairs an owned split preview after closing ' .. closed_side,
            function()
                minifugit.setup({
                    status = { open_in_tab = true },
                    preview = { diff_layout = 'split' },
                })
                helpers.write_file(
                    vim.fs.joinpath(repo, 'tracked.txt'),
                    { 'changed A' }
                )
                vim.cmd.edit(
                    vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
                )
                local caller_tab = vim.api.nvim_get_current_tabpage()
                local caller_win = vim.api.nvim_get_current_win()
                local caller_buf = vim.api.nvim_get_current_buf()
                local caller_opts = capture_winopts(caller_win)
                minifugit.status()
                local owned_tab = vim.api.nvim_get_current_tabpage()
                local status_buf = vim.api.nvim_get_current_buf()
                vim.api.nvim_win_set_cursor(
                    vim.api.nvim_get_current_win(),
                    { helpers.row_containing(status_buf, 'tracked.txt'), 0 }
                )
                mapped_normal_keys('=')
                vim.api.nvim_win_close(
                    helpers.diff_win_named('Minifugit diff ' .. closed_side),
                    true
                )
                vim.api.nvim_set_current_tabpage(caller_tab)

                minifugit.status()

                assert.are.equal(
                    caller_buf,
                    vim.api.nvim_win_get_buf(caller_win)
                )
                assert_winopts(capture_winopts(caller_win), caller_opts)
                assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
                assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
                for _, side in ipairs({ 'left', 'right' }) do
                    local diff_win =
                        helpers.diff_win_named('Minifugit diff ' .. side)
                    assert.are.equal(
                        owned_tab,
                        vim.api.nvim_win_get_tabpage(diff_win)
                    )
                end
                assert.are.equal(1, #normal_windows(caller_tab))
            end
        )
    end

    it('reopens hidden owned status in its original workflow tab', function()
        minifugit.setup({
            status = { open_in_tab = true },
            preview = { diff_layout = 'stacked' },
        })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'changed A' }
        )
        local caller_tab = vim.api.nvim_get_current_tabpage()
        minifugit.status()
        local owned_tab = vim.api.nvim_get_current_tabpage()
        local status_buf = vim.api.nvim_get_current_buf()
        local status_win = vim.api.nvim_get_current_win()
        local tabs_before = #vim.api.nvim_list_tabpages()
        vim.api.nvim_win_set_cursor(
            status_win,
            { helpers.row_containing(status_buf, 'tracked.txt'), 0 }
        )
        mapped_normal_keys('=')
        local diff_win, diff_buf = helpers.diff_win_named('Minifugit diff')

        vim.api.nvim_win_close(status_win, true)
        assert.are.equal(0, #status_windows(owned_tab))
        assert.is_true(vim.api.nvim_win_is_valid(diff_win))
        vim.api.nvim_set_current_tabpage(caller_tab)

        minifugit.status()

        assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert.are.same(
            { vim.api.nvim_get_current_win() },
            status_windows(owned_tab)
        )
        assert.are.equal(diff_win, helpers.diff_win_named('Minifugit diff'))
        assert.are.equal(owned_tab, vim.api.nvim_win_get_tabpage(diff_win))
        helpers.assert_has_line_containing(buffer_lines(diff_buf), 'changed A')
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'updated A' }
        )
        vim.api.nvim_win_set_cursor(
            vim.api.nvim_get_current_win(),
            { helpers.row_containing(status_buf, 'tracked.txt'), 0 }
        )
        mapped_normal_keys('r')
        helpers.assert_has_line_containing(buffer_lines(diff_buf), 'updated A')

        mapped_normal_keys('<CR>')

        assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(diff_win, vim.api.nvim_get_current_win())
        assert.are.equal(
            vim.uv.fs_realpath(vim.fs.joinpath(repo, 'tracked.txt')),
            vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0))
        )
        assert.are.same(
            { 'updated A' },
            buffer_lines(vim.api.nvim_get_current_buf())
        )
        local file_buf = vim.api.nvim_get_current_buf()

        vim.api.nvim_win_close(status_windows(owned_tab)[1], true)
        vim.api.nvim_set_current_tabpage(caller_tab)
        minifugit.status()
        assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(diff_win))
        local settled = false
        vim.schedule(function()
            settled = true
        end)
        assert.is_true(vim.wait(1000, function()
            return settled
        end))

        vim.api.nvim_win_close(diff_win, true)
        minifugit.reset()

        assert.is_false(vim.api.nvim_buf_is_valid(status_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(diff_buf))
        assert.is_false(tabpage_is_valid(owned_tab))
        assert.is_true(vim.api.nvim_buf_is_valid(file_buf))
        assert.are.equal(tabs_before - 1, #vim.api.nvim_list_tabpages())
    end)

    for _, layout in ipairs({ 'stacked', 'split' }) do
        it('keeps independent ' .. layout .. ' previews in two tabs', function()
            minifugit.setup({ preview = { diff_layout = layout } })
            local status_a, status_b = open_two_status_tabs()
            vim.cmd.cd(vim.fn.fnameescape(repo))
            local diff_name = layout == 'split' and 'Minifugit diff right'
                or 'Minifugit diff'
            preview_tracked_entry(status_a)
            local diff_win_a, diff_buf_a = helpers.diff_win_named(diff_name)
            helpers.assert_has_line_containing(
                buffer_lines(diff_buf_a),
                'changed A'
            )

            preview_tracked_entry(status_b)
            local diff_win_b, diff_buf_b = helpers.diff_win_named(diff_name)
            assert.are_not.equal(diff_buf_a, diff_buf_b)
            helpers.assert_has_line_containing(
                buffer_lines(diff_buf_b),
                'changed in B'
            )
            helpers.assert_has_line_containing(
                buffer_lines(diff_buf_a),
                'changed A'
            )
            vim.api.nvim_set_current_win(diff_win_b)
            mapped_normal_keys('aw')
            assert.is_true(vim.wo[diff_win_b].wrap)
            assert.is_false(vim.wo[diff_win_a].wrap)

            vim.api.nvim_set_current_tabpage(status_a.tabpage)
            minifugit.reset()
            assert.is_false(vim.api.nvim_buf_is_valid(diff_buf_a))
            vim.api.nvim_set_current_tabpage(status_b.tabpage)
            minifugit.status()
            assert.are.equal(status_b.buffer, vim.api.nvim_get_current_buf())
            assert.is_true(vim.api.nvim_buf_is_valid(diff_buf_b))
            helpers.assert_has_line_containing(
                buffer_lines(diff_buf_b),
                'changed in B'
            )
        end)
    end

    it('keeps help buffers independent in two tabs', function()
        local status_a, status_b = open_two_status_tabs()
        vim.cmd.cd(vim.fn.fnameescape(repo))
        activate_status_window(status_a.tabpage)
        mapped_normal_keys('?')
        local help_win_a = vim.api.nvim_get_current_win()
        local help_buf_a = vim.api.nvim_get_current_buf()
        assert.are_not.equal(
            '',
            vim.api.nvim_win_get_config(help_win_a).relative
        )

        activate_status_window(status_b.tabpage)
        mapped_normal_keys('?')
        local help_win_b = vim.api.nvim_get_current_win()
        local help_buf_b = vim.api.nvim_get_current_buf()
        assert.are_not.equal(
            '',
            vim.api.nvim_win_get_config(help_win_b).relative
        )
        assert.are_not.equal(help_buf_a, help_buf_b)
        assert.are.same(buffer_lines(help_buf_a), buffer_lines(help_buf_b))

        mapped_normal_keys('q')
        assert.is_false(vim.api.nvim_win_is_valid(help_win_b))
        assert.is_true(vim.api.nvim_win_is_valid(help_win_a))
        assert.is_true(vim.api.nvim_buf_is_valid(help_buf_a))
        assert.are.equal(1, #status_windows(status_a.tabpage))
        assert.are.equal(1, #status_windows(status_b.tabpage))
    end)

    it(
        're-pins only the hidden window when reopening in another root',
        function()
            local status_a, status_b = open_two_status_tabs()
            vim.api.nvim_set_current_tabpage(status_a.tabpage)
            minifugit.status()
            mapped_normal_keys('q')
            vim.cmd.cd(vim.fn.fnameescape(other_repo))

            minifugit.status()

            local replacement_buf = vim.api.nvim_get_current_buf()
            assert.are_not.equal(status_a.buffer, replacement_buf)
            assert.is_false(vim.api.nvim_buf_is_valid(status_a.buffer))
            assert.are.equal(1, #status_windows(status_a.tabpage))
            assert_has_line(buffer_lines(replacement_buf), '?? only-b.txt')
            assert_has_line(
                buffer_lines(replacement_buf),
                'Root: ' .. vim.fn.resolve(other_repo)
            )
            vim.api.nvim_set_current_tabpage(status_b.tabpage)
            minifugit.status()
            assert.are.equal(status_b.buffer, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #status_windows(status_b.tabpage))
            assert_has_line(buffer_lines(status_b.buffer), '?? only-b.txt')
        end
    )

    it(
        'reuses a surviving foreign file tab when hidden status re-pins',
        function()
            minifugit.setup({ status = { open_in_tab = true } })
            minifugit.status()
            local owned_tab = vim.api.nvim_get_current_tabpage()
            local old_buf = vim.api.nvim_get_current_buf()
            local status_win = vim.api.nvim_get_current_win()
            local foreign_win
            for _, win in ipairs(normal_windows(owned_tab)) do
                if win ~= status_win then
                    foreign_win = win
                    break
                end
            end
            vim.api.nvim_set_current_win(foreign_win)
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local foreign_buf = vim.api.nvim_get_current_buf()
            local settled = false
            vim.schedule(function()
                settled = true
            end)
            assert.is_true(vim.wait(1000, function()
                return settled
            end))
            vim.api.nvim_win_close(status_win, true)
            other_repo = helpers.change_to_other_repo(repo)
            local tabs_before = #vim.api.nvim_list_tabpages()

            minifugit.status()

            local replacement_buf = vim.api.nvim_get_current_buf()
            assert.are.equal(owned_tab, vim.api.nvim_get_current_tabpage())
            assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
            assert.are_not.equal(old_buf, replacement_buf)
            assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
            assert.are.equal(1, #status_windows(owned_tab))
            assert_has_line(
                buffer_lines(replacement_buf),
                'Root: ' .. vim.fn.resolve(other_repo)
            )
            assert_has_line(buffer_lines(replacement_buf), ' M tracked.txt')
            assert.are.equal(foreign_buf, vim.api.nvim_win_get_buf(foreign_win))

            minifugit.reset()

            assert.is_false(vim.api.nvim_buf_is_valid(replacement_buf))
            assert.is_true(tabpage_is_valid(owned_tab))
            assert.are.equal(foreign_buf, vim.api.nvim_win_get_buf(foreign_win))
            assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        end
    )

    it('reuses owned B when hidden owned A re-pins to B', function()
        minifugit.setup({ status = { open_in_tab = true } })
        local caller_tab = vim.api.nvim_get_current_tabpage()
        minifugit.status()
        local tab_a = vim.api.nvim_get_current_tabpage()
        local buf_a = vim.api.nvim_get_current_buf()
        local win_a = vim.api.nvim_get_current_win()
        local foreign_path = vim.fs.joinpath(repo, 'foreign.txt')
        helpers.write_file(foreign_path, { 'foreign' })
        for _, win in ipairs(normal_windows(tab_a)) do
            if win ~= win_a then
                vim.api.nvim_set_current_win(win)
                vim.cmd.edit(vim.fn.fnameescape(foreign_path))
                break
            end
        end
        local settled = false
        vim.schedule(function()
            settled = true
        end)
        assert.is_true(vim.wait(1000, function()
            return settled
        end))
        vim.api.nvim_set_current_win(win_a)
        mapped_normal_keys('q')
        assert.is_true(tabpage_is_valid(tab_a))
        assert.are.equal(0, #vim.fn.win_findbuf(buf_a))

        vim.api.nvim_set_current_tabpage(caller_tab)
        other_repo = helpers.change_to_other_repo(repo)
        minifugit.status()
        local tab_b = vim.api.nvim_get_current_tabpage()
        local buf_b = vim.api.nvim_get_current_buf()
        local tabs_before = #vim.api.nvim_list_tabpages()
        vim.api.nvim_set_current_tabpage(tab_a)
        vim.cmd.cd(vim.fn.fnameescape(other_repo))

        minifugit.status()

        local visible_b = 0
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            for _, win in ipairs(status_windows(tab)) do
                local lines = buffer_lines(vim.api.nvim_win_get_buf(win))
                if
                    vim.tbl_contains(
                        lines,
                        'Root: ' .. vim.fn.resolve(other_repo)
                    )
                then
                    visible_b = visible_b + 1
                end
            end
        end
        assert.are.equal(1, visible_b)
        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage())
        assert.are.equal(buf_b, vim.api.nvim_get_current_buf())
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.is_false(vim.api.nvim_buf_is_valid(buf_a))
        assert_has_line(buffer_lines(buf_b), ' M tracked.txt')
    end)

    it(
        'keeps separate owned tabs pinned and cleans up only the closed root',
        function()
            minifugit.setup({ status = { open_in_tab = true } })
            local caller_tab = vim.api.nvim_get_current_tabpage()
            local initial_tabs = #vim.api.nvim_list_tabpages()
            local status_a, status_b = open_two_status_tabs()
            assert.are.equal(initial_tabs + 3, #vim.api.nvim_list_tabpages())
            vim.api.nvim_set_current_tabpage(caller_tab)
            vim.cmd.cd(vim.fn.fnameescape(repo))
            minifugit.status()
            assert.are.equal(
                status_a.tabpage,
                vim.api.nvim_get_current_tabpage()
            )
            assert.are.equal(status_a.buffer, vim.api.nvim_get_current_buf())
            assert.are.equal(initial_tabs + 3, #vim.api.nvim_list_tabpages())

            vim.cmd.tabclose()
            assert.is_true(vim.wait(1000, function()
                return not vim.api.nvim_buf_is_valid(status_a.buffer)
            end))
            vim.api.nvim_set_current_tabpage(status_b.tabpage)
            minifugit.status()
            assert.are.equal(status_b.buffer, vim.api.nvim_get_current_buf())
            assert_has_line(buffer_lines(status_b.buffer), '?? only-b.txt')
            assert_has_line(
                buffer_lines(status_b.buffer),
                'Root: ' .. vim.fn.resolve(other_repo)
            )

            vim.api.nvim_set_current_tabpage(caller_tab)
            minifugit.status()
            local replacement_tab = vim.api.nvim_get_current_tabpage()
            assert.are_not.equal(status_a.tabpage, replacement_tab)
            assert.are_not.equal(caller_tab, replacement_tab)
            assert.are.equal(initial_tabs + 3, #vim.api.nvim_list_tabpages())
            assert_has_line(
                buffer_lines(vim.api.nvim_get_current_buf()),
                '?? only-a.txt'
            )
            assert.are.equal(1, #status_windows(status_b.tabpage))
        end
    )

    it('rejects commits from a status window opened outside git', function()
        other_repo = vim.fn.tempname()
        vim.fn.mkdir(other_repo, 'p')
        vim.cmd.cd(vim.fn.fnameescape(other_repo))
        minifugit.status()
        local gsw = status_window()
        local status_buf = gsw.buf.id
        assert.are.equal('', gsw.root)
        assert_has_line(buffer_lines(status_buf), 'Not inside a git repository')

        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'staged in B' }
        )
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        local log_before = helpers.run({ 'git', 'log', '--format=%H' }, repo)
        local index_before = helpers.run({ 'git', 'ls-files', '--stage' }, repo)
        vim.cmd.cd(vim.fn.fnameescape(repo))

        mapped_normal_keys('c')

        assert.are.equal(
            log_before,
            helpers.run({ 'git', 'log', '--format=%H' }, repo)
        )
        assert.are.equal(
            index_before,
            helpers.run({ 'git', 'ls-files', '--stage' }, repo)
        )
        assert.is_true(
            vim.api.nvim_get_current_buf() == status_buf,
            'Commit keymap must not open a commit buffer for an empty pin'
        )
        assert.are.equal(status_buf, vim.api.nvim_win_get_buf(gsw.win))
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            assert.are_not.equal('gitcommit', vim.bo[buf].filetype)
        end
    end)

    it('stages in the displayed repository after cwd changes', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'changed in A' }
        )
        minifugit.status()
        local gsw = status_window()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        other_repo = helpers.change_to_other_repo(repo)

        mapped_normal_keys('s')

        assert.are.equal(
            'M  tracked.txt\n',
            helpers.run({ 'git', 'status', '--short' }, repo)
        )
        assert.are.equal(
            ' M tracked.txt\n',
            helpers.run({ 'git', 'status', '--short' }, other_repo)
        )
    end)

    it('stages and unstages every visible entry with S and U', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'new' })
        minifugit.status()
        local gsw = status_window()
        assert_has_line(buffer_lines(gsw.buf.id), ' M tracked.txt')
        assert_has_line(buffer_lines(gsw.buf.id), '?? only-a.txt')

        mapped_normal_keys('S')

        assert.are.equal(
            'A  only-a.txt\nM  tracked.txt\n',
            helpers.run({ 'git', 'status', '--short' }, repo)
        )

        mapped_normal_keys('U')

        assert.are.equal(
            ' M tracked.txt\n?? only-a.txt\n',
            helpers.run({ 'git', 'status', '--short' }, repo)
        )
    end)

    it(
        'moves the tracked cursor to the first entry when the current status view rests on a header',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a' })
            helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
            minifugit.status()
            local gsw = status_window()
            local tracked = gsw.win
            local other = vim.api.nvim_open_win(gsw.buf.id, false, {
                split = 'right',
                win = tracked,
            })
            vim.api.nvim_win_set_cursor(
                tracked,
                { helpers.row_containing(gsw.buf.id, 'b.txt'), 0 }
            )
            vim.api.nvim_win_set_cursor(other, { 1, 0 })
            vim.api.nvim_set_current_win(other)

            gsw:refresh()

            local first_entry = helpers.row_containing(gsw.buf.id, 'a.txt')
            assert.are.equal(
                other,
                vim.api.nvim_get_current_win(),
                'The untracked status view must stay current'
            )
            assert.are.equal(1, vim.api.nvim_win_get_cursor(other)[1])
            assert.are.equal(
                first_entry,
                vim.api.nvim_win_get_cursor(tracked)[1],
                'The tracked status view must fall back to the first entry'
            )
            assert.are.equal('?? a.txt', buffer_lines(gsw.buf.id)[first_entry])
        end
    )

    it(
        're-pins a closed status session when reopened in another repository',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
            minifugit.status()
            mapped_normal_keys('q')
            other_repo = helpers.change_to_other_repo(repo)
            helpers.write_file(
                vim.fs.joinpath(other_repo, 'only-b.txt'),
                { 'B' }
            )

            minifugit.status()

            local gsw = status_window()
            assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
            assert.are.equal(gsw.buf.id, vim.api.nvim_win_get_buf(gsw.win))
            local lines = buffer_lines(gsw.buf.id)
            assert_has_line(lines, '?? only-b.txt')
            assert_has_line(lines, 'Root: ' .. vim.fn.resolve(other_repo))
            for _, line in ipairs(lines) do
                assert.is_nil(line:find('only-a.txt', 1, true))
            end
        end
    )

    it(
        'ignores push UI updates after the status window is re-pinned',
        function()
            local git = require('minifugit.git')
            local original_push_async = git.push_async
            local original_notify = vim.notify
            local push_callback
            local push_root
            local notifications = {}

            git.push_async = function(callback, root)
                push_callback = callback
                push_root = root
            end
            vim.notify = function(message, level)
                table.insert(
                    notifications,
                    { message = message, level = level }
                )
            end

            local test_ok, test_err = pcall(function()
                other_repo = helpers.change_to_other_repo(repo)

                for _, push_ok in ipairs({ true, false }) do
                    minifugit.reset()
                    vim.cmd.cd(vim.fn.fnameescape(repo))
                    minifugit.status()
                    local old_status_buf = status_window().buf.id
                    push_callback = nil
                    mapped_normal_keys('p')
                    assert.is_function(push_callback)
                    assert.are.equal(vim.fn.resolve(repo), push_root)
                    mapped_normal_keys('q')
                    vim.cmd.cd(vim.fn.fnameescape(other_repo))
                    minifugit.status()

                    local gsw = status_window()
                    local status_buf = gsw.buf.id
                    local lines_before = buffer_lines(status_buf)
                    assert.is_false(vim.api.nvim_buf_is_valid(old_status_buf))
                    assert_has_line(
                        lines_before,
                        'Root: ' .. vim.fn.resolve(other_repo)
                    )
                    local output = push_ok and 'Pushed commits from A'
                        or 'Push failed in A'
                    helpers.write_file(
                        vim.fs.joinpath(other_repo, output .. '.txt'),
                        { 'Created after the B snapshot' }
                    )

                    local callback_ok, callback_err =
                        pcall(push_callback, push_ok, output)

                    assert(callback_ok, callback_err)
                    assert.are.same(lines_before, buffer_lines(status_buf))
                    assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
                    assert.are.equal(
                        status_buf,
                        vim.api.nvim_win_get_buf(gsw.win)
                    )
                    assert.are.same({
                        message = '[minifugit] ' .. output,
                        level = push_ok and vim.log.levels.INFO
                            or vim.log.levels.ERROR,
                    }, notifications[#notifications])
                end
            end)
            git.push_async = original_push_async
            vim.notify = original_notify
            assert(test_ok, test_err)
        end
    )

    for _, case in ipairs({
        { name = 'normal', opts = {} },
        { name = 'base', opts = { base = 'HEAD' } },
    }) do
        it(
            'paints cached loading frames without reading Git in '
                .. case.name
                .. ' status',
            function()
                local git = require('minifugit.git')
                local original_status_snapshot = git.status_snapshot
                local original_base_entries = git.base_entries
                local status_snapshot_calls = 0
                local base_entries_calls = 0

                helpers.write_file(
                    vim.fs.joinpath(repo, 'tracked.txt'),
                    { 'changed in A' }
                )
                minifugit.open(case.opts)
                local gsw = assert(status_window())
                local buf = gsw.buf.id
                local root_line = 'Root: ' .. vim.fn.resolve(repo)

                assert_has_line(buffer_lines(buf), root_line)
                helpers.row_containing(buf, 'tracked.txt')

                git.status_snapshot = function(...)
                    status_snapshot_calls = status_snapshot_calls + 1
                    return original_status_snapshot(...)
                end
                git.base_entries = function(...)
                    base_entries_calls = base_entries_calls + 1
                    return original_base_entries(...)
                end

                local function loading_line()
                    local lines = buffer_lines(buf)
                    return lines[helpers.row_containing(buf, 'Pushing commits')]
                end

                local function assert_loading_paint()
                    local frame = loading_line():sub(1, 1)
                    assert.is_true(
                        vim.tbl_contains({ '-', '\\', '|', '/' }, frame)
                    )
                    assert.are.equal(' Pushing commits', loading_line():sub(2))
                    assert_has_line(buffer_lines(buf), root_line)
                    helpers.row_containing(buf, 'tracked.txt')
                end

                local test_ok, test_err = pcall(function()
                    gsw:start_loading('Pushing commits')
                    assert_loading_paint()

                    -- The failed-push paint reuses the cached snapshot.
                    gsw:render_cached()
                    assert_loading_paint()

                    -- The spinner timer keeps repainting cached frames.
                    local first_frame = loading_line():sub(1, 1)
                    assert.is_true(vim.wait(2000, function()
                        return loading_line():sub(1, 1) ~= first_frame
                    end))
                    assert_loading_paint()
                end)

                gsw:stop_loading()
                git.status_snapshot = original_status_snapshot
                git.base_entries = original_base_entries

                assert(test_ok, test_err)
                assert.are.equal(0, status_snapshot_calls)
                assert.are.equal(0, base_entries_calls)
            end
        )
    end

    it(
        'keeps a visible status session pinned when status is called from another cwd',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
            minifugit.status()
            local status_buf = status_window().buf.id
            local status_win = status_window().win
            other_repo = helpers.change_to_other_repo(repo)
            helpers.write_file(
                vim.fs.joinpath(other_repo, 'only-b.txt'),
                { 'B' }
            )

            minifugit.status()

            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
            local lines = buffer_lines(status_buf)
            assert_has_line(lines, '?? only-a.txt')
            assert_has_line(lines, 'Root: ' .. vim.fn.resolve(repo))
            for _, line in ipairs(lines) do
                assert.is_nil(line:find('only-b.txt', 1, true))
            end
        end
    )

    it('refreshes the displayed repository after cwd changes', function()
        helpers.write_file(vim.fs.joinpath(repo, 'only-a.txt'), { 'A' })
        minifugit.status()
        local gsw = status_window()
        other_repo = helpers.change_to_other_repo(repo)
        helpers.write_file(vim.fs.joinpath(other_repo, 'only-b.txt'), { 'B' })
        helpers.write_file(vim.fs.joinpath(repo, 'added-in-a.txt'), { 'new A' })

        mapped_normal_keys('r')

        local lines = buffer_lines(gsw.buf.id)
        assert_has_line(lines, '?? only-a.txt')
        assert_has_line(lines, '?? added-in-a.txt')
        for _, line in ipairs(lines) do
            assert.is_nil(line:find('only-b.txt', 1, true))
        end
    end)

    it('opens the displayed file by absolute path after cwd changes', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'changed in A' }
        )
        minifugit.status()
        local gsw = status_window()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        other_repo = helpers.change_to_other_repo(repo)

        mapped_normal_keys('<CR>')

        assert.are.equal(
            vim.fn.resolve(vim.fs.joinpath(repo, 'tracked.txt')),
            vim.fn.resolve(vim.api.nvim_buf_get_name(0))
        )
        assert.are.same(
            { 'changed in A' },
            buffer_lines(vim.api.nvim_get_current_buf())
        )
    end)

    it('shows the pinned repository root in the header', function()
        minifugit.status()
        other_repo = helpers.change_to_other_repo(repo)
        mapped_normal_keys('r')

        local lines = buffer_lines(status_window().buf.id)
        assert_has_line(lines, 'HEAD: main')
        assert_has_line(lines, 'Root: ' .. vim.fn.resolve(repo))
    end)

    -- Windows does not allow control characters in directory names.
    local unix_it = vim.fn.has('win32') == 1 and pending or it
    unix_it(
        'escapes root control characters without changing the pin',
        function()
            local root_header = 'Root: '
                .. vim.fn.resolve(repo)
                .. '^@root^I^M^A^?'
            vim.api.nvim_set_current_dir(original_cwd)
            local renamed_repo = repo .. '\nroot\t\r\1\127'
            assert.are.equal(0, vim.fn.rename(repo, renamed_repo))
            repo = renamed_repo
            vim.api.nvim_set_current_dir(repo)

            minifugit.status()

            local status_buf = vim.api.nvim_get_current_buf()
            local status_win = vim.api.nvim_get_current_win()
            assert.are.equal('minifugit', vim.bo[status_buf].filetype)
            assert.are.equal(status_buf, vim.api.nvim_win_get_buf(status_win))
            assert_has_line(buffer_lines(status_buf), root_header)
            assert.are.equal(
                '',
                helpers.run({ 'git', 'status', '--short' }, repo)
            )

            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'new A' }
            )
            other_repo = helpers.change_to_other_repo(repo)
            mapped_normal_keys('r')

            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
            assert_has_line(buffer_lines(status_buf), root_header)
            vim.api.nvim_win_set_cursor(
                status_win,
                { helpers.row_containing(status_buf, 'tracked.txt'), 0 }
            )
            mapped_normal_keys('s')

            assert.are.equal(
                'M  tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, repo)
            )
            assert.are.equal(
                ' M tracked.txt\n',
                helpers.run({ 'git', 'status', '--short' }, other_repo)
            )
        end
    )

    unix_it('escapes control characters in untracked file names', function()
        helpers.write_file(repo .. '/line\nbreak\t\r\1\127.txt', { 'new' })

        assert.is_true(minifugit.open())

        local buf = vim.api.nvim_get_current_buf()
        assert.are.equal('minifugit', vim.bo[buf].filetype)
        assert.are.equal(buf, vim.api.nvim_win_get_buf(0))
        assert_has_line(buffer_lines(buf), '?? line^@break^I^M^A^?.txt')
    end)

    unix_it(
        'stages the raw newline path from its escaped status row',
        function()
            local path = 'line\nbreak.txt'
            helpers.write_file(repo .. '/' .. path, { 'new' })
            minifugit.open()
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_win_set_cursor(
                0,
                { helpers.row_containing(buf, 'line^@break.txt'), 0 }
            )

            mapped_normal_keys('s')

            assert.are.equal(
                path .. '\0',
                helpers.run(
                    { 'git', 'diff', '--cached', '--name-only', '-z' },
                    repo
                )
            )
            assert_has_line(buffer_lines(buf), 'A  line^@break.txt')
        end
    )

    unix_it('stages the raw CRLF path from its escaped status row', function()
        local path = 'line\r\nbreak.txt'
        helpers.write_file(repo .. '/' .. path, { 'new' })
        assert.is_true(minifugit.open())
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        assert.are.equal('minifugit', vim.bo[buf].filetype)
        assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
        vim.api.nvim_win_set_cursor(
            win,
            { helpers.row_containing(buf, 'break.txt'), 0 }
        )

        mapped_normal_keys('s')

        -- Read raw bytes so the assertion cannot normalize the staged name.
        local staged = vim.system({
            'git',
            'diff',
            '--cached',
            '--name-only',
            '-z',
        }, { cwd = repo, text = false }):wait()
        assert.are.equal(0, staged.code, staged.stderr)
        assert.are.equal(path .. '\0', staged.stdout)
        assert.are.equal(win, vim.api.nvim_get_current_win())
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        assert_has_line(buffer_lines(buf), 'A  line^M^@break.txt')
    end)

    unix_it('escapes newline paths in untracked discard prompts', function()
        local path = repo .. '/line\nbreak.txt'
        helpers.write_file(path, { 'new' })
        assert.is_true(minifugit.open())
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(
            win,
            { helpers.row_containing(buf, 'line^@break.txt'), 0 }
        )
        local unchanged = helpers.snapshot_editor_state()
        local original_confirm = vim.fn.confirm
        local prompt
        vim.fn.confirm = function(message)
            prompt = message
            return 2
        end
        local ok, discarded = pcall(function()
            return status_window():discard_entry(false)
        end)
        vim.fn.confirm = original_confirm
        assert.is_true(ok, discarded)
        assert.is_false(discarded)

        unchanged()
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        assert.are.equal(win, vim.api.nvim_get_current_win())
        assert.are.equal(1, vim.fn.filereadable(path))
        assert.are.same({ 'new' }, vim.fn.readfile(path))
        assert.are.equal('Delete untracked path line^@break.txt?', prompt)
        assert.is_nil(prompt:find('\n', 1, true))
    end)

    unix_it('escapes newline paths in tracked discard prompts', function()
        local path = repo .. '/line\nbreak.txt'
        helpers.write_file(path, { 'original' })
        helpers.run({ 'git', 'add', '.' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'add newline file' }, repo)
        helpers.write_file(path, { 'changed' })
        assert.is_true(minifugit.open())
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(
            win,
            { helpers.row_containing(buf, 'line^@break.txt'), 0 }
        )
        local unchanged = helpers.snapshot_editor_state()
        local original_confirm = vim.fn.confirm
        local prompt
        vim.fn.confirm = function(message)
            prompt = message
            return 2
        end
        local ok, discarded = pcall(function()
            return status_window():discard_entry(false)
        end)
        vim.fn.confirm = original_confirm
        assert.is_true(ok, discarded)
        assert.is_false(discarded)

        unchanged()
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        assert.are.equal(win, vim.api.nvim_get_current_win())
        assert.are.equal(1, vim.fn.filereadable(path))
        assert.are.same({ 'changed' }, vim.fn.readfile(path))
        assert.are.equal('Discard changes in line^@break.txt?', prompt)
        assert.is_nil(prompt:find('\n', 1, true))
    end)

    unix_it('filters the escaped current and original file names', function()
        helpers.write_file(repo .. '/old\nname.txt', { 'rename' })
        helpers.run({ 'git', 'add', '.' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'add newline file' }, repo)
        helpers.run({ 'git', 'mv', 'old\nname.txt', 'renamed.txt' }, repo)
        helpers.write_file(repo .. '/line\nbreak.txt', { 'new' })
        helpers.write_file(repo .. '/ordinary.txt', { 'ordinary' })
        minifugit.open()
        local buf = vim.api.nvim_get_current_buf()
        local function filter(query)
            local original_input = vim.ui.input
            vim.ui.input = function(_, callback)
                callback(query)
            end
            mapped_normal_keys('/')
            vim.ui.input = original_input
        end

        filter('LINE^@')
        assert.is_true(
            vim.tbl_contains(buffer_lines(buf), '?? line^@break.txt')
        )
        assert.is_false(vim.tbl_contains(buffer_lines(buf), 'Staged (1)'))
        assert.is_false(vim.tbl_contains(buffer_lines(buf), '?? ordinary.txt'))

        filter('OLD^@')
        assert.is_true(
            vim.tbl_contains(
                buffer_lines(buf),
                'R  old^@name.txt -> renamed.txt'
            )
        )
        assert.is_false(vim.tbl_contains(buffer_lines(buf), 'Untracked (1)'))

        filter('ordinary.txt')
        assert.is_true(vim.tbl_contains(buffer_lines(buf), '?? ordinary.txt'))
        assert.is_false(vim.tbl_contains(buffer_lines(buf), 'Staged (1)'))
    end)

    unix_it(
        'escapes newline file names when a stacked diff becomes empty',
        function()
            local path = repo .. '/empty\nfile\t\r\1\127%.txt'
            helpers.write_file(path, { 'original' })
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add newline file' }, repo)
            helpers.write_file(path, { 'changed' })
            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.open()
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_win_set_cursor(
                0,
                { helpers.row_containing(buf, 'empty^@file^I^M^A^?%.txt'), 0 }
            )
            -- The file can change after status collection but before previewing.
            helpers.write_file(path, { 'original' })

            assert.is_true(status_window():diff_entry())

            local win, preview = helpers.diff_win_named('Minifugit diff')
            assert.are.same(
                { 'No diff for empty^@file^I^M^A^?%.txt' },
                buffer_lines(preview)
            )
            assert.are.equal(
                'unstaged: empty^@file^I^M^A^?%%.txt',
                vim.wo[win].winbar
            )
            assert.are.equal(buf, vim.api.nvim_get_current_buf())
        end
    )

    unix_it('escapes newline paths in split fallback warnings', function()
        local path = repo .. '/missing\nfile.txt'
        helpers.write_file(path, { 'original' })
        helpers.run({ 'git', 'add', '.' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'add newline file' }, repo)
        helpers.write_file(path, { 'changed' })
        minifugit.options.preview.diff_layout = 'split'
        local target = vim.api.nvim_get_current_win()
        local original_buf = vim.api.nvim_get_current_buf()
        assert.is_true(minifugit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_cursor(
            0,
            { helpers.row_containing(buf, 'missing^@file.txt'), 0 }
        )
        -- The file can disappear after status collection but before previewing.
        assert.are.equal(0, vim.fn.delete(path))

        local warning, warning_level = capture_notification(function()
            assert.is_true(status_window():diff_entry())
        end)

        local win, preview = helpers.diff_win_named('Minifugit diff')
        assert.are.equal(target, win)
        assert.are.equal(buf, vim.api.nvim_get_current_buf())
        helpers.assert_has_line_containing(buffer_lines(preview), 'original')
        vim.api.nvim_set_current_win(win)
        mapped_normal_keys('q')
        assert.are.equal(original_buf, vim.api.nvim_win_get_buf(target))
        assert.are.equal(2, #normal_windows(0))
        assert.are.equal(
            '[minifugit] Cannot stat file: '
                .. vim.fn.resolve(repo)
                .. '/missing^@file.txt; showing stacked diff',
            warning
        )
        assert.are.equal(vim.log.levels.WARN, warning_level)
        assert.is_nil(warning:find('\n', 1, true))
    end)

    unix_it(
        'escapes split rename titles and refuses to open newline paths',
        function()
            local old_path = 'old\nfile%.txt'
            local new_path = 'new\nfile\t.txt'
            helpers.write_file(repo .. '/' .. old_path, {
                'same first',
                'same second',
                'same third',
                'original fourth',
            })
            helpers.run({ 'git', 'add', '.' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'add newline file' }, repo)
            helpers.run({ 'git', 'mv', old_path, new_path }, repo)
            helpers.write_file(repo .. '/' .. new_path, {
                'same first',
                'same second',
                'same third',
                'changed fourth',
            })
            helpers.run({ 'git', 'add', '--', new_path }, repo)
            minifugit.options.preview.diff_layout = 'split'
            minifugit.open()
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_win_set_cursor(0, {
                helpers.row_containing(
                    buf,
                    'old^@file%.txt -> new^@file^I.txt'
                ),
                0,
            })

            assert.is_true(status_window():diff_entry())

            local left_win, left = helpers.diff_win_named('Minifugit diff left')
            local right_win, right =
                helpers.diff_win_named('Minifugit diff right')
            local title = 'staged: old^@file%%.txt -> new^@file^I.txt'
            assert.are.equal(
                title .. ' [1/2] HEAD:old^@file%%.txt',
                vim.wo[left_win].winbar
            )
            assert.are.equal(
                title .. ' [2/2] index:new^@file^I.txt',
                vim.wo[right_win].winbar
            )
            assert_has_line(buffer_lines(left), 'original fourth')
            assert_has_line(buffer_lines(right), 'changed fourth')
            vim.api.nvim_set_current_win(right_win)
            vim.api.nvim_win_set_cursor(
                right_win,
                { helpers.row_containing(right, 'changed fourth'), 0 }
            )
            local unchanged = helpers.snapshot_editor_state()
            local warning, warning_level = capture_notification(function()
                mapped_normal_keys('<CR>')
            end)

            unchanged()
            assert.are.equal(right, vim.api.nvim_get_current_buf())
            assert.are.equal(right_win, vim.api.nvim_get_current_win())
            assert.are.equal(
                '[minifugit] Cannot open a file name that contains a newline: '
                    .. vim.fn.resolve(repo)
                    .. '/new^@file^I.txt',
                warning
            )
            assert.are.equal(vim.log.levels.WARN, warning_level)
        end
    )

    unix_it(
        'refuses newline paths but opens tab paths in normal and base status',
        function()
            helpers.write_file(repo .. '/line\nbreak.txt', { 'new' })
            helpers.write_file(repo .. '/tab\tname.txt', { 'tab content' })
            for _, opts in ipairs({ {}, { base = 'HEAD' } }) do
                minifugit.open(opts)
                local buf = vim.api.nvim_get_current_buf()
                local win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_cursor(
                    win,
                    { helpers.row_containing(buf, 'line^@break.txt'), 0 }
                )
                local unchanged = helpers.snapshot_editor_state()
                local warning, warning_level = capture_notification(function()
                    mapped_normal_keys('<CR>')
                end)

                unchanged()
                assert.are.equal(buf, vim.api.nvim_get_current_buf())
                assert.are.equal(win, vim.api.nvim_get_current_win())
                assert.are.equal(
                    '[minifugit] Cannot open a file name that contains a newline: '
                        .. vim.fn.resolve(repo)
                        .. '/line^@break.txt',
                    warning
                )
                assert.are.equal(vim.log.levels.WARN, warning_level)

                vim.api.nvim_win_set_cursor(
                    win,
                    { helpers.row_containing(buf, 'tab^Iname.txt'), 0 }
                )
                mapped_normal_keys('<CR>')
                assert.are.equal(
                    vim.fn.resolve(repo) .. '/tab\tname.txt',
                    vim.api.nvim_buf_get_name(0)
                )
                assert.are.same({ 'tab content' }, buffer_lines(0))
            end
        end
    )

    for _, name in ipairs({ 'tracked.txt', 'untracked.txt' }) do
        it('discards only ' .. name .. ' after cwd changes', function()
            helpers.write_file(vim.fs.joinpath(repo, name), { 'changed in A' })
            minifugit.status()
            local gsw = status_window()
            vim.api.nvim_win_set_cursor(
                gsw.win,
                { helpers.row_containing(gsw.buf.id, name), 0 }
            )
            other_repo = helpers.change_to_other_repo(repo)
            helpers.write_file(
                vim.fs.joinpath(other_repo, name),
                { 'changed in B' }
            )
            local other_status =
                helpers.run({ 'git', 'status', '--short' }, other_repo)

            mapped_normal_keys('D')

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
            local gsw = status_window()
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
        local gsw = status_window()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'new-dir/file.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        local _, diff_buf = helpers.diff_win_named('Minifugit diff')
        helpers.assert_has_line_containing(
            buffer_lines(diff_buf),
            'new content'
        )
    end)

    it('updates the stacked preview after moving to another file', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), {
            'tracked-unique-aaa',
        })
        helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), {
            'other-unique-bbb',
        })
        helpers.run({ 'git', 'add', 'other.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'add other' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), {
            'other-unique-bbb',
            'other-changed',
        })

        minifugit.options.preview.diff_layout = 'stacked'
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        assert.is_true(gsw:diff_entry())
        local _, diff_buf = helpers.diff_win_named('Minifugit diff')
        helpers.assert_has_line_containing(
            buffer_lines(diff_buf),
            'tracked-unique-aaa'
        )

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'other.txt'), 0 }
        )
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = gsw.buf.id })

        local updated = vim.wait(1000, function()
            for _, line in ipairs(buffer_lines(diff_buf)) do
                if line:find('other-changed', 1, true) ~= nil then
                    return true
                end
            end

            return false
        end)

        if not updated then
            assert.fail(
                'preview did not follow cursor:\n'
                    .. table.concat(buffer_lines(diff_buf), '\n')
            )
        end
    end)

    it(
        'overlays source syntax on the stacked preview asynchronously',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'script.lua'), {
                'local function answer()',
                '    return 42',
                'end',
            })
            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()

            ---@type GitStatusWindow
            local gsw = status_window()
            vim.api.nvim_set_current_win(gsw.win)
            vim.api.nvim_win_set_cursor(
                gsw.win,
                { helpers.row_containing(gsw.buf.id, 'script.lua'), 0 }
            )

            assert.is_true(gsw:diff_entry())
            local _, diff_buf = helpers.diff_win_named('Minifugit diff')
            helpers.assert_has_line_containing(
                buffer_lines(diff_buf),
                'return 42'
            )

            -- First paint shows the unified patch immediately; source syntax is
            -- overlaid a moment later, so it must not be there right away.
            assert.is_false(has_source_syntax_extmarks(diff_buf))

            local highlighted = vim.wait(2000, function()
                return has_source_syntax_extmarks(diff_buf)
            end)

            if not highlighted then
                assert.fail('source syntax was not overlaid on stacked preview')
            end
        end
    )

    it('opens the stacked preview without blocking on source syntax', function()
        local lines = { 'local M = {}' }
        for index = 1, 300 do
            table.insert(
                lines,
                string.format(
                    'local function fn_%d() return %d end',
                    index,
                    index
                )
            )
        end
        table.insert(lines, 'return M')
        helpers.write_file(vim.fs.joinpath(repo, 'big.lua'), lines)
        minifugit.options.preview.diff_layout = 'stacked'
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'big.lua'), 0 }
        )

        local start = vim.uv.hrtime()
        assert.is_true(gsw:diff_entry())
        local elapsed_ms = (vim.uv.hrtime() - start) / 1e6

        local _, diff_buf = helpers.diff_win_named('Minifugit diff')
        helpers.assert_has_line_containing(buffer_lines(diff_buf), 'fn_300')

        -- Syntax highlighting arrives later; the first paint must stay fast.
        assert.is_false(has_source_syntax_extmarks(diff_buf))
        assert(
            elapsed_ms < 150,
            string.format(
                'stacked preview open took %.1fms (source syntax blocking?)',
                elapsed_ms
            )
        )
    end)

    it(
        'keeps the status window focused when opening a preview with =',
        function()
            helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), {
                'one',
                'two',
            })
            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()

            ---@type GitStatusWindow
            local gsw = status_window()
            local status_win = assert(gsw.win)
            vim.api.nvim_set_current_win(status_win)
            vim.api.nvim_win_set_cursor(
                status_win,
                { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
            )

            mapped_normal_keys('=')

            assert.is_true(gsw.preview:has_open())
            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            helpers.diff_win_named('Minifugit diff')
        end
    )

    it('uses the target window for stacked previews', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), {
            'one',
            'two',
        })
        local target_win = vim.api.nvim_get_current_win()
        local target_buf = vim.api.nvim_get_current_buf()
        minifugit.options.preview.diff_layout = 'stacked'

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())

        assert.are.equal(2, #normal_windows(vim.api.nvim_get_current_tabpage()))
        local diff_win, diff_buf = helpers.diff_win_named('Minifugit diff')
        assert.are.equal(target_win, diff_win)
        assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(target_win))

        gsw.preview:close()

        assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
    end)

    it(
        'refreshes and reuses the existing status buffer on repeated calls',
        function()
            minifugit.status()

            ---@type GitStatusWindow
            local first = status_window()
            local first_buf = first.buf.id
            local first_win = assert(first.win)

            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            minifugit.status()

            assert.are.equal(first, status_window())
            assert.are.equal(first_buf, status_window().buf.id)
            assert.are.equal(first_win, status_window().win)
            assert.are.equal(first_buf, vim.api.nvim_win_get_buf(first_win))
            assert_has_line(buffer_lines(first_buf), '?? untracked.txt')
        end
    )

    it('closes the status window through its normal mode mapping', function()
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
        local win = assert(gsw.win)
        local buf = gsw.buf.id

        vim.api.nvim_set_current_win(win)
        vim.cmd.normal('q')

        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_nil(gsw.win)
    end)

    it(
        'replaces the status buffer instead of closing Neovim when it is the last window',
        function()
            minifugit.status()

            ---@type GitStatusWindow
            local gsw = status_window()
            local win = assert(gsw.win)
            local buf = gsw.buf.id

            for _, other_win in ipairs(normal_windows(0)) do
                if other_win ~= win then
                    vim.api.nvim_win_close(other_win, true)
                end
            end

            vim.api.nvim_set_current_win(win)
            vim.bo[buf].modifiable = true
            vim.bo[buf].modified = true
            vim.cmd.normal('q')

            assert.is_true(vim.api.nvim_win_is_valid(win))
            assert.are_not.equal(buf, vim.api.nvim_win_get_buf(win))
            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.is_nil(gsw.win)
        end
    )

    it(
        'replaces the last status buffer when closed from another tab',
        function()
            minifugit.status()

            ---@type GitStatusWindow
            local gsw = status_window()
            local win = assert(gsw.win)
            local buf = gsw.buf.id
            local original_tab = vim.api.nvim_get_current_tabpage()

            for _, other_win in ipairs(normal_windows(original_tab)) do
                if other_win ~= win then
                    vim.api.nvim_win_close(other_win, true)
                end
            end

            vim.cmd('tabnew')
            local current_tab = vim.api.nvim_get_current_tabpage()

            assert.is_true(gsw:close())
            assert.are.equal(current_tab, vim.api.nvim_get_current_tabpage())
            assert.is_true(vim.api.nvim_win_is_valid(win))
            assert.are_not.equal(buf, vim.api.nvim_win_get_buf(win))
            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.is_nil(gsw.win)
        end
    )

    it('opens the status workflow in a new tab when configured', function()
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20, open_in_tab = true },
        })
        local original_tab = vim.api.nvim_get_current_tabpage()
        local tab_count = #vim.api.nvim_list_tabpages()

        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
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
        local gsw = status_window()
        local status_win = assert(gsw.win)
        local expected_status_width =
            math.max(math.floor(vim.o.columns * 0.4), 20)
        vim.api.nvim_win_set_cursor(
            status_win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        assert.are.equal(
            expected_status_width,
            vim.api.nvim_win_get_width(status_win)
        )

        local diff_win = helpers.diff_win_named('Minifugit diff')
        gsw.preview:close()

        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        assert.is_true(vim.api.nvim_win_is_valid(status_win))
        assert.is_true(vim.api.nvim_win_is_valid(diff_win))

        vim.api.nvim_set_current_win(status_win)
        assert.is_true(gsw:diff_entry())

        local reopened_diff_win = helpers.diff_win_named('Minifugit diff')
        assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(diff_win, reopened_diff_win)
        assert.are.equal(
            expected_status_width,
            vim.api.nvim_win_get_width(status_win)
        )
        assert.is_true(vim.api.nvim_win_is_valid(reopened_diff_win))
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
        local gsw = status_window()
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
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())

        local diff_win = helpers.diff_win_named('Minifugit diff')
        assert.are.equal(2, #normal_windows(vim.api.nvim_get_current_tabpage()))
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
            local gsw = status_window()
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
        local gsw = status_window()
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
        local gsw = status_window()
        local tabpage = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
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
        local gsw = status_window()
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
        local gsw = status_window()
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
                local gsw = status_window()
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
        local gsw = status_window()
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
            local gsw = status_window()
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
        local gsw = status_window()

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

        local lines = buffer_lines(status_window().buf.id)
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
            vim.api.nvim_set_current_win(status_window().win)
            vim.api.nvim_win_set_cursor(status_window().win, {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })

            assert.is_true(status_window():enter_entry())

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
            vim.api.nvim_set_current_win(status_window().win)
            vim.cmd.normal('q')

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'uses the target file window for stacked diff and restores it',
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
            vim.api.nvim_win_set_cursor(assert(status_window().win), {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })
            status_window():diff_entry()

            local diff_win, diff_buf = helpers.diff_win_named('Minifugit diff')
            assert.are.equal(file_win, diff_win)
            assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(file_win))

            status_window():close()

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'keeps the status window focused when showing the same entry diff',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_set_current_win(status_window().win)
            vim.api.nvim_win_set_cursor(status_window().win, {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })

            assert.is_true(status_window():diff_entry())
            vim.api.nvim_set_current_win(status_window().win)
            assert.is_true(status_window():diff_entry())

            helpers.diff_win_named('Minifugit diff')
            assert.are.equal(
                status_window().win,
                vim.api.nvim_get_current_win()
            )
        end
    )

    it(
        'keeps status focused when status mappings toggle diff preview',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            local status_win = assert(status_window().win)
            vim.api.nvim_set_current_win(status_win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })
            assert.is_true(status_window():diff_entry())

            vim.api.nvim_set_current_win(status_win)
            local diff_win, diff_buf = helpers.diff_win_named('Minifugit diff')
            local wrap = vim.wo[diff_win].wrap
            mapped_normal_keys('aw')
            assert.are.equal(not wrap, vim.wo[diff_win].wrap)
            assert.are.equal(status_win, vim.api.nvim_get_current_win())

            local lines = buffer_lines(diff_buf)
            mapped_normal_keys('an')
            assert.are_not.same(lines, buffer_lines(diff_buf))
            assert.are.equal(status_win, vim.api.nvim_get_current_win())

            lines = buffer_lines(diff_buf)
            mapped_normal_keys('am')
            assert.are_not.same(lines, buffer_lines(diff_buf))
            assert.are.equal(status_win, vim.api.nvim_get_current_win())

            mapped_normal_keys('al')
            helpers.diff_win_named('Minifugit diff left')
            helpers.diff_win_named('Minifugit diff right')
            assert.are.equal(status_win, vim.api.nvim_get_current_win())
        end
    )

    it(
        'round-trips the target window through stacked and split previews',
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
            vim.wo.winbar = 'real file transition'
            vim.wo.statuscolumn = 'transition-statuscolumn'
            vim.wo.scrollbind = false
            vim.wo.cursorbind = false

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            local status_win = assert(status_window().win)
            local file_win = assert(win_showing_buf(file_buf))
            local before = capture_winopts(file_win)

            vim.api.nvim_set_current_win(status_win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })
            assert.is_true(
                status_window().preview:preview_current_entry({ force = true })
            )

            local stacked_win = helpers.diff_win_named('Minifugit diff')
            assert.are.equal(file_win, stacked_win)
            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(
                2,
                #normal_windows(vim.api.nvim_get_current_tabpage())
            )

            assert.is_true(status_window().preview:toggle_layout())
            local left_win = helpers.diff_win_named('Minifugit diff left')
            local right_win = helpers.diff_win_named('Minifugit diff right')
            assert.are.equal(file_win, left_win)
            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(
                3,
                #normal_windows(vim.api.nvim_get_current_tabpage())
            )
            assert.is_true(vim.wo[left_win].scrollbind)
            assert.is_true(vim.wo[left_win].cursorbind)
            assert.is_true(vim.wo[right_win].scrollbind)
            assert.is_true(vim.wo[right_win].cursorbind)

            assert.is_true(status_window().preview:toggle_layout())
            local reopened_win = helpers.diff_win_named('Minifugit diff')
            assert.are.equal(file_win, reopened_win)
            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(
                2,
                #normal_windows(vim.api.nvim_get_current_tabpage())
            )
            assert.is_false(vim.wo[reopened_win].scrollbind)
            assert.is_false(vim.wo[reopened_win].cursorbind)

            status_window().preview:close()

            assert.are.equal(status_win, vim.api.nvim_get_current_win())
            assert.are.equal(
                2,
                #normal_windows(vim.api.nvim_get_current_tabpage())
            )
            assert.has_error(function()
                helpers.diff_win_named('Minifugit diff')
            end)
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it('uses the target file window for split diff and restores it', function()
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
        file_win = assert(win_showing_buf(file_buf))
        before = capture_winopts(file_win)
        vim.api.nvim_win_set_cursor(
            status_window().win,
            { helpers.row_containing(status_window().buf.id, 'tracked.txt'), 0 }
        )
        status_window():diff_entry()

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win = helpers.diff_win_named('Minifugit diff right')
        assert.are.equal(file_win, left_win)
        assert.are.equal(left_buf, vim.api.nvim_win_get_buf(file_win))
        assert.are_not.equal(file_win, right_win)

        status_window():close()

        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), before)
    end)

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
            status_window().win,
            { helpers.row_containing(status_window().buf.id, 'tracked.txt'), 0 }
        )
        status_window():diff_entry()

        local left_win, left_buf = helpers.diff_win_named('Minifugit diff left')
        local right_win = helpers.diff_win_named('Minifugit diff right')
        assert.are.equal(file_win, left_win)
        assert.are.equal(left_buf, vim.api.nvim_win_get_buf(file_win))
        assert.are_not.equal(file_win, right_win)

        status_window():close()

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
        local status_win = assert(status_window().win)
        local status_buf = status_window().buf.id
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

    it('keeps file options when leaving a stacked diff buffer', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo.number = true
        vim.wo.relativenumber = true
        vim.wo.signcolumn = 'yes:2'
        vim.wo.foldcolumn = '2'
        vim.wo.wrap = true
        vim.wo.cursorline = true
        vim.wo.winbar = 'real file diff jump'
        vim.wo.statuscolumn = 'diff-jump-statuscolumn'
        local file_opts = capture_winopts(file_win)

        minifugit.options.preview.diff_layout = 'stacked'
        minifugit.status()
        vim.api.nvim_win_set_cursor(
            assert(status_window().win),
            { helpers.row_containing(status_window().buf.id, 'tracked.txt'), 0 }
        )
        status_window():diff_entry()

        local diff_win = helpers.diff_win_named('Minifugit diff')
        vim.api.nvim_set_current_win(diff_win)
        normal_keys('<C-O>')

        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), file_opts)
    end)

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
            vim.api.nvim_win_set_cursor(assert(status_window().win), {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })
            status_window():diff_entry()

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
            vim.api.nvim_win_set_cursor(assert(status_window().win), {
                helpers.row_containing(status_window().buf.id, 'tracked.txt'),
                0,
            })
            status_window():diff_entry()

            vim.api.nvim_set_current_win(file_win)
            vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'other.txt')))
            assert.is_true(vim.wait(1000, function()
                return winopts_match(capture_winopts(file_win), file_opts)
            end))
            assert_winopts(capture_winopts(file_win), file_opts)
        end
    )

    it('keeps file options when leaving a split diff buffer', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo.number = false
        vim.wo.relativenumber = true
        vim.wo.signcolumn = 'auto:2'
        vim.wo.foldcolumn = '1'
        vim.wo.wrap = true
        vim.wo.cursorline = true
        vim.wo.winbar = 'real file split jump'
        vim.wo.statuscolumn = 'split-jump-statuscolumn'
        local file_opts = capture_winopts(file_win)

        minifugit.options.preview.diff_layout = 'split'
        minifugit.status()
        vim.api.nvim_win_set_cursor(
            assert(status_window().win),
            { helpers.row_containing(status_window().buf.id, 'tracked.txt'), 0 }
        )
        status_window():diff_entry()

        local diff_win = helpers.diff_win_named('Minifugit diff left')
        vim.api.nvim_set_current_win(diff_win)
        normal_keys('<C-O>')

        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), file_opts)
    end)
end)
