---@diagnostic disable: undefined-field
-- Async reads: the status snapshot and the diff preview are collected off the
-- main loop. These specs pin the observable behaviour: a loading placeholder
-- while a read is in flight, newest-read-wins for overlapping refreshes, a
-- closed window dropping its result, read errors through the error row, and a
-- stale diff preview result being discarded.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local project_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local LOADING_PLACEHOLDER = 'Loading git status...'

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param buf integer
---@param expected string
local function assert_has_line(buf, expected)
    for _, line in ipairs(buffer_lines(buf)) do
        if line == expected then
            return
        end
    end

    assert.fail('Expected line not found: ' .. expected)
end

---@param buf integer
---@param unexpected string
local function refute_has_line(buf, unexpected)
    for _, line in ipairs(buffer_lines(buf)) do
        if line == unexpected then
            assert.fail('Unexpected line found: ' .. unexpected)
        end
    end
end

---@param text string
---@return fun(line: string): boolean
local function line_has(text)
    return function(line)
        return line:find(text, 1, true) ~= nil
    end
end

---@param bufnr integer
---@param predicate fun(line: string): boolean
---@return boolean
local function wait_for_buf_line(bufnr, predicate)
    return vim.wait(2000, function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return false
        end

        for _, line in ipairs(buffer_lines(bufnr)) do
            if predicate(line) then
                return true
            end
        end

        return false
    end)
end

---Replace `git.<name>` for the duration of `body`.
---@param name string
---@param replacement function
---@param body fun(restore: fun())
local function with_git_stub(name, replacement, body)
    local git = require('minifugit.git')
    local original = git[name]
    git[name] = replacement

    local ok, err = pcall(body, function()
        git[name] = original
    end)

    git[name] = original

    if not ok then
        error(err, 0)
    end
end

describe('minifugit async reads', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type string?
    local original_git_dir
    ---@type string?
    local original_git_work_tree
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
        vim.env.GIT_DIR = original_git_dir
        vim.env.GIT_WORK_TREE = original_git_work_tree

        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

    it(
        'shows a loading placeholder and then the entries for an in-flight snapshot read',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'changed' }
            )
            local git = require('minifugit.git')
            local snapshot = git.status_snapshot(repo)
            local pending = {}

            with_git_stub('status_snapshot_async', function(_, callback)
                table.insert(pending, callback)
            end, function()
                assert.is_true(minifugit.open({ cwd = repo }))
                local buf = vim.api.nvim_get_current_buf()

                assert_has_line(buf, LOADING_PLACEHOLDER)
                refute_has_line(buf, ' M tracked.txt')
                assert.are.equal(1, #pending)

                pending[1](snapshot)

                assert_has_line(buf, ' M tracked.txt')
                refute_has_line(buf, LOADING_PLACEHOLDER)
            end)
        end
    )

    it(
        'resolves to the newest entries when a read is superseded mid-flight',
        function()
            local git = require('minifugit.git')
            local pending = {}

            with_git_stub('status_snapshot_async', function(_, callback)
                table.insert(pending, callback)
            end, function()
                assert.is_true(minifugit.open({ cwd = repo }))
                local win = assert(status_window())
                local buf = win.buf.id
                local before = git.status_snapshot(repo)

                helpers.write_file(vim.fs.joinpath(repo, 'later.txt'), {
                    'added after the first read started',
                })
                assert.is_true(win:refresh())
                local after = git.status_snapshot(repo)
                assert.are.equal(2, #pending)
                assert.is_true(#before.entries < #after.entries)

                -- The newer read lands first, then the superseded one.
                pending[2](after)
                assert_has_line(buf, '?? later.txt')

                pending[1](before)
                assert_has_line(buf, '?? later.txt')
                refute_has_line(buf, LOADING_PLACEHOLDER)
            end)
        end
    )

    it(
        'closes during an in-flight read without error or a dangling buffer',
        function()
            local git = require('minifugit.git')
            local snapshot = git.status_snapshot(repo)
            local pending = {}

            with_git_stub('status_snapshot_async', function(_, callback)
                table.insert(pending, callback)
            end, function()
                assert.is_true(minifugit.open({ cwd = repo }))
                local win = assert(status_window())
                local buf = win.buf.id

                assert.is_true(win:close())
                assert.are.same({}, vim.fn.win_findbuf(buf))
                local rendered = buffer_lines(buf)

                local ok, err = pcall(pending[1], snapshot)

                assert.is_true(ok, err)
                assert.are.same(rendered, buffer_lines(buf))
                assert.are.same({}, vim.fn.win_findbuf(buf))

                minifugit.reset()
                assert.is_false(vim.api.nvim_buf_is_valid(buf))
            end)
        end
    )

    it('shows the error row when the snapshot read fails', function()
        -- A corrupt index makes `git status` fail while the repository still
        -- resolves, so the read itself reports the failure.
        helpers.write_raw(vim.fs.joinpath(repo, '.git', 'index'), 'DIRC')
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })

        local git = require('minifugit.git')
        local real_read = git.status_snapshot_async
        local pending = {}

        with_git_stub('status_snapshot_async', function(root, callback)
            table.insert(pending, function()
                real_read(root, callback)
            end)
        end, function()
            assert.is_true(minifugit.open({ cwd = repo }))
            local win = assert(status_window())

            assert_has_line(win.buf.id, LOADING_PLACEHOLDER)
            assert.are.equal(1, #pending)

            pending[1]()

            assert.is_true(wait_for_buf_line(win.buf.id, function(line)
                return vim.startswith(line, 'fatal: ')
                    and line:find(
                            'index file smaller than expected',
                            1,
                            true
                        )
                        ~= nil
            end))
            refute_has_line(win.buf.id, LOADING_PLACEHOLDER)
        end)
    end)

    it('drops a diff preview result for an entry it moved away from', function()
        local git = require('minifugit.git')
        helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a' })
        helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
        local captured = {}

        with_git_stub('diff_async', function(entry, section, root, callback)
            table.insert(captured, {
                entry = entry,
                section = section,
                lines = select(1, git.diff(entry, section, root)),
                callback = callback,
            })
        end, function()
            assert.is_true(minifugit.open({ cwd = repo }))
            local win = assert(status_window())
            helpers.wait_idle(status_window)

            local function preview(path)
                vim.api.nvim_win_set_cursor(win.win, {
                    helpers.row_containing(win.buf.id, path),
                    0,
                })
                assert.is_true(win:diff_entry())
            end

            preview('a.txt')
            preview('b.txt')
            assert.are.equal(2, #captured)

            captured[2].callback(captured[2].lines)

            local _, diff_buf = helpers.diff_win_named('Minifugit diff')

            assert.is_true(wait_for_buf_line(diff_buf, line_has('b.txt')))
            local rendered = buffer_lines(diff_buf)

            captured[1].callback(captured[1].lines)

            assert.are.same(rendered, buffer_lines(diff_buf))
        end)
    end)
end)
