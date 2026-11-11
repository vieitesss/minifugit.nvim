---@diagnostic disable: undefined-field
-- The diff preview reuses its windows for every file. A file the preview has
-- not shown yet opens at its first row, a file shown before opens where it was
-- left, and showing the same file again keeps its view.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

---@param prefix string
---@return string[]
local function numbered_lines(prefix)
    local lines = {}

    for index = 1, 200 do
        lines[index] = prefix .. ' ' .. index
    end

    return lines
end

for _, layout in ipairs({ 'stacked', 'split' }) do
    describe('minifugit ' .. layout .. ' preview view per file', function()
        local original_cwd, repo, minifugit
        local status_window, restore_constructor

        before_each(function()
            original_cwd = vim.fn.getcwd()
            repo = helpers.create_repo({
                ['a.txt'] = numbered_lines('a'),
                ['b.txt'] = numbered_lines('b'),
            })
            helpers.write_file(
                vim.fs.joinpath(repo, 'a.txt'),
                numbered_lines('changed a')
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'b.txt'),
                numbered_lines('changed b')
            )

            vim.cmd.cd(vim.fn.fnameescape(repo))
            vim.cmd.enew()
            helpers.reload_minifugit()
            status_window, restore_constructor =
                helpers.capture_status_windows()
            minifugit = helpers.awaiting_reads(
                require('minifugit').setup({
                    status = { width = 0.4, min_width = 20 },
                    preview = { diff_layout = layout },
                }),
                status_window
            )
            minifugit.open()
        end)

        after_each(function()
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

        ---Preview a file from the status window and return the window that
        ---shows its diff (the left one in the split layout).
        ---@param path string
        ---@return integer
        local function preview(path)
            local gsw = status_window()
            vim.api.nvim_set_current_win(gsw.win)
            vim.api.nvim_win_set_cursor(
                gsw.win,
                { helpers.row_containing(gsw.buf.id, path), 0 }
            )
            assert.is_true(gsw:diff_entry())
            helpers.wait_idle(status_window)

            local win = gsw.preview.stacked.win or gsw.preview.left.win
            assert.is_true(vim.api.nvim_win_is_valid(win))
            return win
        end

        ---@param win integer
        ---@return { lnum: integer, topline: integer }
        local function view_of(win)
            local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
            return { lnum = view.lnum, topline = view.topline }
        end

        ---@param win integer
        local function scroll_down(win)
            vim.api.nvim_win_call(win, function()
                vim.api.nvim_win_set_cursor(win, { 150, 0 })
                vim.cmd('normal! zt')
            end)
        end

        it('opens a file not shown yet at its first row', function()
            local win = preview('a.txt')
            scroll_down(win)
            assert.are.same({ lnum = 150, topline = 150 }, view_of(win))

            win = preview('b.txt')

            assert.are.same({ lnum = 1, topline = 1 }, view_of(win))
            if layout == 'split' then
                local right = status_window().preview.right.win
                assert.are.same({ lnum = 1, topline = 1 }, view_of(right))
            end
        end)

        it('opens a file shown before where it was left', function()
            scroll_down(preview('a.txt'))
            preview('b.txt')

            local win = preview('a.txt')

            assert.are.same({ lnum = 150, topline = 150 }, view_of(win))
        end)

        it('keeps the view when the same file is shown again', function()
            local win = preview('a.txt')
            scroll_down(win)

            win = preview('a.txt')

            assert.are.same({ lnum = 150, topline = 150 }, view_of(win))
        end)

        it('forgets the views when the preview closes', function()
            scroll_down(preview('a.txt'))
            preview('b.txt')
            status_window().preview:close()

            local win = preview('a.txt')

            assert.are.same({ lnum = 1, topline = 1 }, view_of(win))
        end)
    end)
end
