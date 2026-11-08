---@diagnostic disable: undefined-field
-- Conflicts are resolved in the file and marked resolved with `s`. Status
-- actions that would drop the merge stages refuse instead of touching them.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local project_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local REFUSAL =
    '[minifugit] Resolve the conflict in the file, then stage it with `s`'
local MARKERS = '[minifugit] a.txt still contains conflict markers'

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

---Sorted porcelain lines, so assertions do not depend on Git's listing order.
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

---@param repo string
---@return boolean
local function merging(repo)
    return vim.uv.fs_stat(vim.fs.joinpath(repo, '.git', 'MERGE_HEAD')) ~= nil
end

describe('minifugit conflicts', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Minifugit
    local minifugit
    ---@type fun(): GitStatusWindow?
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
        repo = helpers.create_repo({
            ['a.txt'] = { 'base' },
            ['b.txt'] = { 'b' },
        })
        helpers.run({ 'git', 'checkout', '-q', '-b', 'feature' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'theirs' })
        helpers.run({ 'git', 'commit', '-qam', 'theirs' }, repo)
        helpers.run({ 'git', 'checkout', '-q', 'main' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'ours' })
        helpers.run({ 'git', 'commit', '-qam', 'ours' }, repo)
        helpers.run({ 'sh', '-c', 'git merge -q feature || true' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b staged' })
        helpers.run({ 'git', 'add', 'b.txt' }, repo)
        assert.are.same({ 'M  b.txt', 'UU a.txt' }, porcelain(repo))
        assert.is_true(merging(repo))

        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit = helpers.awaiting_reads(
            require('minifugit').setup({
                status = { width = 0.5, min_width = 20 },
            }),
            status_window
        )
        assert.is_true(minifugit.open({ cwd = repo }))
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

    ---@param text string
    ---@return GitStatusWindow
    local function cursor_on(text)
        local win = assert(status_window())
        vim.api.nvim_win_set_cursor(
            win.win,
            { helpers.row_containing(win.buf.id, text), 0 }
        )
        return win
    end

    it('refuses u on a conflict and keeps the merge stages', function()
        local win = cursor_on('UU a.txt')

        local messages = capture_notifications(function()
            assert.is_false(win:unstage_entry())
        end)

        assert.are.same({ REFUSAL }, messages)
        assert.are.same({ 'M  b.txt', 'UU a.txt' }, porcelain(repo))
        assert.is_true(merging(repo))
    end)

    it('refuses U while a conflict is visible and touches no entry', function()
        local win = assert(status_window())

        local messages = capture_notifications(function()
            assert.is_false(win:unstage_all_entries())
        end)

        assert.are.same({ REFUSAL }, messages)
        assert.are.same({ 'M  b.txt', 'UU a.txt' }, porcelain(repo))
        assert.is_true(merging(repo))
    end)

    it('refuses a visual u over a conflict and a staged entry', function()
        local win = assert(status_window())
        local conflict_row = helpers.row_containing(win.buf.id, 'UU a.txt')
        local staged_row = helpers.row_containing(win.buf.id, 'M  b.txt')
        vim.fn.setpos(
            "'<",
            { win.buf.id, math.min(conflict_row, staged_row), 1, 0 }
        )
        vim.fn.setpos(
            "'>",
            { win.buf.id, math.max(conflict_row, staged_row), 1, 0 }
        )

        local messages = capture_notifications(function()
            assert.is_false(win:unstage_selected_entries())
        end)

        assert.are.same({ REFUSAL }, messages)
        assert.are.same({ 'M  b.txt', 'UU a.txt' }, porcelain(repo))
    end)

    it('refuses d and D on a conflict and keeps the file', function()
        local win = cursor_on('UU a.txt')
        local before = vim.fn.readfile(vim.fs.joinpath(repo, 'a.txt'))

        local messages = capture_notifications(function()
            assert.is_false(win:discard_entry(false))
            assert.is_false(win:discard_entry(true))
        end)

        assert.are.same({ REFUSAL, REFUSAL }, messages)
        assert.are.same(before, vim.fn.readfile(vim.fs.joinpath(repo, 'a.txt')))
        assert.are.same({ 'M  b.txt', 'UU a.txt' }, porcelain(repo))
    end)

    it(
        'stages a conflict that still has markers and warns about them',
        function()
            local win = cursor_on('UU a.txt')

            local messages = capture_notifications(function()
                assert.is_true(win:stage_entry())
                helpers.wait_idle(status_window)
            end)

            assert.are.same({ MARKERS }, messages)
            assert.are.same({ 'M  a.txt', 'M  b.txt' }, porcelain(repo))
        end
    )

    it('stages a resolved conflict without a warning', function()
        helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'resolved' })
        local win = cursor_on('UU a.txt')

        local messages = capture_notifications(function()
            assert.is_true(win:stage_entry())
            helpers.wait_idle(status_window)
        end)

        assert.are.same({}, messages)
        assert.are.same({ 'M  a.txt', 'M  b.txt' }, porcelain(repo))
    end)

    it('warns about markers when S stages every visible entry', function()
        local win = assert(status_window())

        local messages = capture_notifications(function()
            assert.is_true(win:stage_all_entries())
            helpers.wait_idle(status_window)
        end)

        assert.are.same({ MARKERS }, messages)
        assert.are.same({ 'M  a.txt', 'M  b.txt' }, porcelain(repo))
    end)
end)
