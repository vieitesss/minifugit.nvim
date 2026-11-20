---@diagnostic disable: undefined-field
-- `preview.position` says where the diff preview sits relative to the status
-- window. The status window anchors to the opposite editor edge and keeps its
-- configured size; the preview takes the rest.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local POSITIONS = { 'right', 'left', 'down', 'up' }

for _, position in ipairs(POSITIONS) do
    describe('minifugit preview position ' .. position, function()
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
            status_window, restore_constructor =
                helpers.capture_status_windows()
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

        ---@return integer
        local function expected_status_width()
            return math.max(math.floor(vim.o.columns * 0.5), 20)
        end

        ---@return integer
        local function expected_status_height()
            return math.max(math.floor(vim.o.lines * 0.3), 5)
        end

        ---Start the plugin with the position of the enclosing block.
        ---@param layout 'stacked'|'split'
        local function configure(layout)
            minifugit = helpers.awaiting_reads(
                require('minifugit').setup({
                    status = {
                        width = 0.5,
                        min_width = 20,
                        height = 0.3,
                        min_height = 5,
                    },
                    preview = { position = position, diff_layout = layout },
                }),
                status_window
            )
        end

        ---Open the status window in a tab where it is the only window, so the
        ---preview has no edit window to reuse and creates its own split.
        ---@return GitStatusWindow
        local function open_status_only()
            minifugit.status()
            vim.wait(1000, function()
                return status_window() ~= nil
            end)
            local gsw = assert(status_window())
            local status_win = assert(gsw.win)

            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if win ~= status_win then
                    vim.api.nvim_win_close(win, true)
                end
            end

            return gsw
        end

        ---Preview a file from the status window.
        ---@param gsw GitStatusWindow
        ---@param path string
        local function preview(gsw, path)
            local status_win = assert(gsw.win)
            vim.api.nvim_set_current_win(status_win)
            vim.api.nvim_win_set_cursor(status_win, {
                helpers.row_containing(gsw.buf.id, path),
                0,
            })
            assert.is_true(gsw:diff_entry())
            helpers.wait_idle(status_window)
        end

        ---@param win integer
        ---@return integer row, integer col
        local function position_of(win)
            local pos = vim.api.nvim_win_get_position(win)
            return pos[1], pos[2]
        end

        it('anchors the status window opposite the preview', function()
            configure('stacked')
            local gsw = open_status_only()
            local status_win = assert(gsw.win)
            preview(gsw, 'tracked.txt')
            local preview_win = assert(gsw.preview.stacked.win)
            assert.is_true(vim.api.nvim_win_is_valid(preview_win))
            local status_row, status_col = position_of(status_win)
            local preview_row, preview_col = position_of(preview_win)

            if position == 'right' or position == 'left' then
                assert.are.equal(
                    expected_status_width(),
                    vim.api.nvim_win_get_width(status_win)
                )
                -- Both windows take the full height of the editor.
                assert.are.equal(0, status_row)
                assert.are.equal(0, preview_row)
                assert.are.equal(
                    vim.api.nvim_win_get_height(preview_win),
                    vim.api.nvim_win_get_height(status_win)
                )

                if position == 'right' then
                    assert.are.equal(0, status_col)
                    assert.are.equal(expected_status_width() + 1, preview_col)
                else
                    assert.are.equal(0, preview_col)
                    assert.are.equal(
                        vim.api.nvim_win_get_width(preview_win) + 1,
                        status_col
                    )
                    assert.are.equal(
                        vim.o.columns,
                        status_col + expected_status_width()
                    )
                end
            else
                assert.are.equal(
                    expected_status_height(),
                    vim.api.nvim_win_get_height(status_win)
                )
                -- Both windows take the full width of the editor.
                assert.are.equal(0, status_col)
                assert.are.equal(0, preview_col)
                assert.are.equal(
                    vim.o.columns,
                    vim.api.nvim_win_get_width(status_win)
                )
                assert.are.equal(
                    vim.o.columns,
                    vim.api.nvim_win_get_width(preview_win)
                )

                if position == 'down' then
                    assert.are.equal(0, status_row)
                    -- The preview starts below the status window.
                    assert.are.equal(
                        status_row + expected_status_height() + 1,
                        preview_row
                    )
                else
                    assert.are.equal(0, preview_row)
                    -- The status window starts below the preview.
                    assert.are.equal(
                        preview_row
                            + vim.api.nvim_win_get_height(preview_win)
                            + 1,
                        status_row
                    )
                end
            end
        end)

        if position == 'down' then
            it(
                'keeps both split sides side by side below the status',
                function()
                    configure('split')
                    local gsw = open_status_only()
                    local status_win = assert(gsw.win)
                    preview(gsw, 'tracked.txt')

                    local left_win = assert(gsw.preview.left.win)
                    local right_win = assert(gsw.preview.right.win)
                    assert.is_true(vim.api.nvim_win_is_valid(left_win))
                    assert.is_true(vim.api.nvim_win_is_valid(right_win))

                    local status_row, status_col = position_of(status_win)
                    local left_row, left_col = position_of(left_win)
                    local right_row, right_col = position_of(right_win)
                    local left_width = vim.api.nvim_win_get_width(left_win)
                    local right_width = vim.api.nvim_win_get_width(right_win)

                    -- The status window keeps its full width and its height.
                    assert.are.equal(0, status_row)
                    assert.are.equal(0, status_col)
                    assert.are.equal(
                        vim.o.columns,
                        vim.api.nvim_win_get_width(status_win)
                    )
                    assert.are.equal(
                        expected_status_height(),
                        vim.api.nvim_win_get_height(status_win)
                    )

                    -- Both sides share the preview area below the status window.
                    local preview_row = status_row
                        + expected_status_height()
                        + 1
                    assert.are.equal(preview_row, left_row)
                    assert.are.equal(preview_row, right_row)
                    assert.are.equal(0, left_col)
                    assert.are.equal(left_width + 1, right_col)
                    assert.are.equal(
                        vim.o.columns,
                        left_width + right_width + 1
                    )
                end
            )
        end

        if position == 'left' then
            it(
                'opens the file left of the status with no edit window',
                function()
                    configure('stacked')
                    local gsw = open_status_only()
                    local status_win = assert(gsw.win)

                    vim.api.nvim_set_current_win(status_win)
                    vim.api.nvim_win_set_cursor(status_win, {
                        helpers.row_containing(gsw.buf.id, 'tracked.txt'),
                        0,
                    })
                    vim.api.nvim_feedkeys(
                        vim.api.nvim_replace_termcodes(
                            '<CR>',
                            true,
                            false,
                            true
                        ),
                        'mx',
                        false
                    )
                    helpers.wait_idle(status_window)

                    local file_win
                    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                        local name = vim.api.nvim_buf_get_name(
                            vim.api.nvim_win_get_buf(win)
                        )

                        if name:find('tracked.txt', 1, true) ~= nil then
                            file_win = win
                        end
                    end

                    assert.is_not_nil(file_win)
                    local file_row, file_col = position_of(file_win)
                    local status_row, status_col = position_of(status_win)

                    assert.are.equal(0, file_row)
                    assert.are.equal(0, file_col)
                    assert.are.equal(
                        vim.api.nvim_win_get_width(file_win) + 1,
                        status_col
                    )
                    assert.are.equal(0, status_row)
                    -- The two windows share the editor width, the file to the
                    -- left of the status window.
                    assert.are.equal(
                        vim.o.columns,
                        file_col
                            + vim.api.nvim_win_get_width(file_win)
                            + 1
                            + vim.api.nvim_win_get_width(status_win)
                    )
                end
            )
        end
    end)
end
