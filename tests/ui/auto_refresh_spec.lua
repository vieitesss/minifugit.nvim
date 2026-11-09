---@diagnostic disable: undefined-field
-- Auto-refresh: returning focus to the editor refreshes the status window
-- through the normal refresh path, debounced so a burst of focus events
-- coalesces into one read. Spinners and the `status.auto_refresh = false`
-- option suppress it, and a manual refresh supersedes a pending debounce.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local project_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

-- Longer than the plugin's debounce plus the read that follows it, so
-- "nothing happened" assertions cover the whole window.
local QUIET_MS = 600

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param buf integer
---@param expected string
---@return boolean
local function has_line(buf, expected)
    for _, line in ipairs(buffer_lines(buf)) do
        if line == expected then
            return true
        end
    end

    return false
end

---@param condition fun(): boolean
local function wait_for(condition)
    assert.is_true(vim.wait(3000, condition, 10))
end

---Visible diff preview windows.
---@return integer[]
local function diff_windows()
    return vim.tbl_filter(function(win)
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))

        return vim.fs.basename(name):find('^Minifugit diff', 1) ~= nil
    end, vim.api.nvim_tabpage_list_wins(0))
end

---Fire the editor focus event the plugin listens to.
local function gain_focus()
    vim.api.nvim_exec_autocmds('FocusGained', {})
end

describe('minifugit auto-refresh', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Minifugit
    local minifugit
    ---@type fun(): GitStatusWindow?
    local status_window
    local restore_constructor
    ---@type { count: integer, restore: fun() }
    local reads

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
            ['tracked.txt'] = { 'one' },
            ['other.txt'] = { 'other' },
        })
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        status_window, restore_constructor = helpers.capture_status_windows()

        local git = require('minifugit.git')
        local real_read = git.status_snapshot_async
        reads = {
            count = 0,
            restore = function()
                git.status_snapshot_async = real_read
            end,
        }
        git.status_snapshot_async = function(...)
            reads.count = reads.count + 1
            return real_read(...)
        end

        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20 },
        })
    end)

    after_each(function()
        restore_constructor()
        reads.restore()
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

    it('refreshes the entries on focus without pressing r', function()
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)
        assert.is_false(has_line(win.buf.id, ' M tracked.txt'))

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        gain_focus()

        wait_for(function()
            return has_line(win.buf.id, ' M tracked.txt')
        end)
        assert.are.equal(1, reads.count)
    end)

    it('coalesces a burst of focus events into one read', function()
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'late.txt'), { 'late' })
        reads.count = 0

        for _ = 1, 5 do
            gain_focus()
        end

        wait_for(function()
            return has_line(win.buf.id, '?? late.txt')
        end)

        -- Wait out the full debounce window: no refresh follows the burst.
        vim.wait(QUIET_MS)
        assert.are.equal(1, reads.count)
    end)

    it('keeps the cursor entry and the filter on an auto-refresh', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'changed' })
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        local original_input = vim.ui.input
        vim.ui.input = function(_, callback)
            callback('tracked')
        end
        win:filter_entries()
        vim.ui.input = original_input
        helpers.wait_idle(status_window)
        assert.is_false(has_line(win.buf.id, ' M other.txt'))

        local entry_row = helpers.row_containing(win.buf.id, ' M tracked.txt')
        vim.api.nvim_win_set_cursor(win.win, { entry_row, 0 })

        reads.count = 0
        gain_focus()

        wait_for(function()
            return reads.count == 1 and not win.reading
        end)

        assert.are.equal(
            ' M tracked.txt',
            buffer_lines(win.buf.id)[vim.api.nvim_win_get_cursor(win.win)[1]]
        )
        assert.is_false(has_line(win.buf.id, ' M other.txt'))
    end)

    it('closes a preview whose entry the refresh no longer has', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)
        assert.is_true(has_line(win.buf.id, ' M tracked.txt'))

        vim.api.nvim_win_set_cursor(win.win, {
            helpers.row_containing(win.buf.id, ' M tracked.txt'),
            0,
        })
        assert.is_true(win:diff_entry())
        helpers.wait_idle(status_window)
        helpers.diff_win_named('Minifugit diff')

        -- Everything restored from the terminal: the entry is gone.
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'one' })
        gain_focus()

        wait_for(function()
            return not has_line(win.buf.id, ' M tracked.txt')
                and not win.reading
        end)

        assert.are.same({}, diff_windows())
        assert.is_false(win.preview:has_open())
    end)

    it('starts no read while a push spinner is active', function()
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        win:start_loading('Pushing to origin/main...')
        gain_focus()
        vim.wait(QUIET_MS)

        assert.are.equal(0, reads.count)
        assert.is_false(has_line(win.buf.id, ' M tracked.txt'))
        win:stop_loading()
    end)

    it('leaves the buffer stale on focus when auto_refresh is false', function()
        minifugit.setup({
            status = { width = 0.5, min_width = 20, auto_refresh = false },
        })
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        gain_focus()
        vim.wait(QUIET_MS)

        assert.are.equal(0, reads.count)
        assert.is_false(has_line(win.buf.id, ' M tracked.txt'))
    end)

    it('lets a manual refresh cancel a pending debounce', function()
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        gain_focus()
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes('r', true, false, true),
            'mx',
            false
        )

        wait_for(function()
            return has_line(win.buf.id, ' M tracked.txt')
        end)
        vim.wait(QUIET_MS)

        assert.are.equal(1, reads.count)
    end)

    it('does not refresh a status window in another tabpage', function()
        assert.is_true(minifugit.open({ cwd = repo, open_in_tab = true }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        vim.cmd.tabnew()
        gain_focus()
        vim.wait(QUIET_MS)
        assert.are.equal(0, reads.count)

        vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win.win))
        gain_focus()

        wait_for(function()
            return reads.count == 1 and not win.reading
        end)
        assert.is_true(has_line(win.buf.id, ' M tracked.txt'))
    end)

    it('makes no read on a debounce pending when the window closes', function()
        assert.is_true(minifugit.open({ cwd = repo }))
        local win = assert(status_window())
        helpers.wait_idle(status_window)

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'changed' })
        reads.count = 0
        gain_focus()
        assert.is_true(win:close())
        vim.wait(QUIET_MS)

        assert.are.equal(0, reads.count)
    end)
end)
