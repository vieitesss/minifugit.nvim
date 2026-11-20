---@diagnostic disable: undefined-field
-- The diff preview borrows an edit window: it releases `winfixwidth` on that
-- window while it shows a diff and gives the old value back on close. Those
-- writes belong to that window only, so the editor default must stay put even
-- when the borrowed window has focus.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

describe('minifugit preview window options', function()
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
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({
            ['tracked.txt'] = { 'one', 'two' },
            ['other.txt'] = { 'other' },
        })
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'changed' }
        )

        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        helpers.reload_minifugit()
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit =
            helpers.awaiting_reads(require('minifugit').setup(), status_window)
        minifugit.open()
    end)

    after_each(function()
        vim.go.winfixwidth = false
        vim.go.wrap = true
        vim.go.scrollbind = false
        vim.go.cursorbind = false
        vim.go.cursorline = false
        vim.go.winbar = ''
        restore_constructor()
        if minifugit then
            minifugit.reset()
        end
        vim.cmd('silent! tabonly!')
        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('%bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        vim.fn.delete(repo, 'rf')
    end)

    ---The edit window the preview borrows: the only normal window besides the
    ---status window.
    ---@param status_win integer
    ---@return integer
    local function edit_win(status_win)
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if win ~= status_win then
                return win
            end
        end

        error('Expected an edit window beside the status window')
    end

    it(
        'keeps the winfixwidth default when the '
            .. 'preview borrows a focused edit window',
        function()
            local gsw = assert(status_window())
            local status_win = assert(gsw.win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(gsw.buf.id, 'tracked.txt'),
                0,
            })

            -- The borrowed window keeps its own value, so the preview reuses
            -- it and releases the width fix there.
            local target = edit_win(status_win)
            vim.api.nvim_set_current_win(target)
            local edit_buf = vim.api.nvim_win_get_buf(target)
            vim.go.winfixwidth = true
            assert.is_true(gsw:diff_entry())
            helpers.wait_idle(status_window)

            assert.are.equal(target, gsw.preview.stacked.win)
            assert.is_false(vim.wo[target].winfixwidth)
            assert.is_true(vim.go.winfixwidth)
            assert.are_not.equal(edit_buf, vim.api.nvim_win_get_buf(target))

            -- Closing gives the borrowed window its options back. Neovim
            -- syncs the global default from the window the focus lands on,
            -- so the global is read from the one-shot WinLeave the borrowed
            -- window leaves behind: that runs after the restore and before
            -- the resync.
            local aug = vim.api.nvim_create_augroup(
                'MinifugitPreviewOptionScopeSpec',
                { clear = true }
            )
            ---@type boolean?
            local global_on_leave
            vim.api.nvim_create_autocmd('WinLeave', {
                group = aug,
                once = true,
                callback = function()
                    global_on_leave = vim.go.winfixwidth
                end,
            })

            gsw.preview:close()
            helpers.wait_idle(status_window)
            vim.api.nvim_del_augroup_by_id(aug)

            assert.is_true(global_on_leave)
            assert.is_false(vim.wo[target].winfixwidth)
            assert.are.equal(edit_buf, vim.api.nvim_win_get_buf(target))
        end
    )

    it(
        'keeps wrap, bind and winbar defaults on a borrowed focused window',
        function()
            local gsw = assert(status_window())
            local status_win = assert(gsw.win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(gsw.buf.id, 'tracked.txt'),
                0,
            })

            local target = edit_win(status_win)
            vim.api.nvim_set_current_win(target)
            vim.go.wrap = true
            vim.go.scrollbind = true
            vim.go.cursorbind = true
            vim.go.winbar = 'global winbar'
            assert.is_true(gsw:diff_entry())
            helpers.wait_idle(status_window)

            assert.are.equal(target, gsw.preview.stacked.win)
            assert.are.equal('global winbar', vim.go.winbar)
            assert.is_true(vim.go.wrap)
            assert.is_true(vim.go.scrollbind)
            assert.is_true(vim.go.cursorbind)
            -- The preview still applies its own settings to that window only.
            assert.is_false(vim.wo[target].wrap)
            assert.is_false(vim.wo[target].scrollbind)
            assert.is_false(vim.wo[target].cursorbind)
            assert.is_truthy(vim.wo[target].winbar:find('tracked.txt', 1, true))
        end
    )

    it('keeps the bind and wrap defaults with a split preview', function()
        local gsw = assert(status_window())
        assert.is_true(gsw.preview:toggle_layout())
        local status_win = assert(gsw.win)
        vim.api.nvim_win_set_cursor(status_win, {
            helpers.row_containing(gsw.buf.id, 'tracked.txt'),
            0,
        })

        vim.api.nvim_set_current_win(status_win)
        vim.go.scrollbind = false
        vim.go.cursorbind = false
        vim.go.wrap = true
        assert.is_true(gsw:diff_entry())
        helpers.wait_idle(status_window)

        local left_win = assert(gsw.preview.left.win)
        local right_win = assert(gsw.preview.right.win)
        assert.is_false(vim.go.scrollbind)
        assert.is_false(vim.go.cursorbind)
        assert.is_true(vim.go.wrap)

        -- Both panes are bound and unwrapped, and nothing of that reaches the
        -- editor defaults no matter which pane held the focus.
        for _, win in ipairs({ left_win, right_win }) do
            assert.is_true(vim.wo[win].scrollbind)
            assert.is_true(vim.wo[win].cursorbind)
            assert.is_false(vim.wo[win].wrap)
        end

        -- Repainting and toggling from inside a pane writes that pane's
        -- options while it has the focus.
        vim.api.nvim_set_current_win(right_win)
        assert.is_true(gsw.preview:refresh())
        helpers.wait_idle(status_window)
        assert.is_true(gsw.preview:toggle_wrap())

        assert.is_false(vim.go.scrollbind)
        assert.is_false(vim.go.cursorbind)
        assert.is_true(vim.go.wrap)

        for _, win in ipairs({ left_win, right_win }) do
            assert.is_true(vim.wo[win].scrollbind)
            assert.is_true(vim.wo[win].cursorbind)
            assert.is_true(vim.wo[win].wrap)
        end
    end)

    it('keeps the wrap and cursorline defaults when the help opens', function()
        local gsw = assert(status_window())
        vim.go.wrap = true
        vim.go.cursorline = true

        gsw:toggle_help()

        local help_win = assert(gsw.help_win)
        assert.are.equal(help_win, vim.api.nvim_get_current_win())
        assert.is_false(vim.wo[help_win].wrap)
        assert.is_false(vim.wo[help_win].cursorline)
        assert.is_true(vim.go.wrap)
        assert.is_true(vim.go.cursorline)
    end)
end)
