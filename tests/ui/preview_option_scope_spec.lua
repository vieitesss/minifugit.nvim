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
        'keeps the winfixwidth default when the preview borrows a focused edit window',
        function()
            local gsw = assert(status_window())
            local status_win = assert(gsw.win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(gsw.buf.id, 'tracked.txt'),
                0,
            })

            -- The borrowed window keeps its own value, so the preview reuses it and
            -- releases the width fix there.
            local target = edit_win(status_win)
            vim.api.nvim_set_current_win(target)
            vim.go.winfixwidth = true
            assert.is_true(gsw:diff_entry())
            helpers.wait_idle(status_window)

            assert.are.equal(target, gsw.preview.stacked.win)
            assert.is_false(vim.wo[target].winfixwidth)
            assert.is_true(vim.go.winfixwidth)

            -- Closing gives the borrowed window its options back. Neovim syncs the
            -- global default on the window switch that follows, so only the window
            -- and its option are asserted here.
            gsw.preview:close()
            helpers.wait_idle(status_window)

            assert.is_false(vim.wo[target].winfixwidth)
        end
    )
end)
