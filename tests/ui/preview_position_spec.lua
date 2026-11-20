---@diagnostic disable: undefined-field
-- `preview.position` says where the diff preview sits relative to the status
-- window. The status window anchors to the opposite editor edge and keeps its
-- configured size; the preview takes the rest.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

-- Status size fixture, configured by every spec and asserted against.
local STATUS_WIDTH = 0.5
local MIN_WIDTH = 20
local STATUS_HEIGHT = 0.3
local MIN_HEIGHT = 5

---@class PreviewPositionCase
---@field position MinifugitPreviewPosition
---@field axis 'column'|'row' Axis the status and preview windows share.
---@field status_first boolean Whether the status window comes first on it.

---@type PreviewPositionCase[]
local CASES = {
    { position = 'right', axis = 'column', status_first = true },
    { position = 'left', axis = 'column', status_first = false },
    { position = 'down', axis = 'row', status_first = true },
    { position = 'up', axis = 'row', status_first = false },
}

---@param case PreviewPositionCase
---@return string
local function case_title(case)
    return 'minifugit preview position ' .. case.position
end

---@param position MinifugitPreviewPosition
---@return PreviewPositionCase
local function position_case(position)
    for _, case in ipairs(CASES) do
        if case.position == position then
            return case
        end
    end

    error(string.format('unknown preview position: %s', position))
end

describe('minifugit preview positions', function()
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
        vim.go.winfixwidth = false
        vim.go.winfixheight = false
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

    ---Global values of the options that pin a window's size. The plugin sets
    ---them on its own windows only, so a preview must never change the global
    ---defaults.
    ---@return table<string, boolean>
    local function editor_globals()
        return {
            winfixwidth = vim.go.winfixwidth,
            winfixheight = vim.go.winfixheight,
        }
    end

    ---@return integer[]
    local function normal_wins()
        local wins = {}

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(win).relative == '' then
                table.insert(wins, win)
            end
        end

        return wins
    end

    ---@param axis 'column'|'row'
    ---@return integer
    local function expected_status_size(axis)
        if axis == 'column' then
            return math.max(math.floor(vim.o.columns * STATUS_WIDTH), MIN_WIDTH)
        end

        return math.max(math.floor(vim.o.lines * STATUS_HEIGHT), MIN_HEIGHT)
    end

    ---Start the plugin with the given position and layout.
    ---@param position MinifugitPreviewPosition
    ---@param layout 'stacked'|'split'
    local function configure(position, layout)
        minifugit = helpers.awaiting_reads(
            require('minifugit').setup({
                status = {
                    width = STATUS_WIDTH,
                    min_width = MIN_WIDTH,
                    height = STATUS_HEIGHT,
                    min_height = MIN_HEIGHT,
                },
                preview = { position = position, diff_layout = layout },
            }),
            status_window
        )
    end

    ---The size of a window along one axis.
    ---@param win integer
    ---@param axis 'column'|'row'
    ---@return integer
    local function win_size(win, axis)
        if axis == 'column' then
            return vim.api.nvim_win_get_width(win)
        end

        return vim.api.nvim_win_get_height(win)
    end

    ---Open the status window and assert where it lands while the edit window
    ---still exists: the edge opposite the preview, at its configured size.
    ---Then close the edit window so the preview has nothing to reuse and
    ---creates its own split.
    ---@param case PreviewPositionCase
    ---@return GitStatusWindow
    local function open_status_only(case)
        local edit_win = vim.api.nvim_get_current_win()
        minifugit.status()
        local gsw = assert(status_window())
        local status_win = assert(gsw.win)

        -- `nvim_win_get_position` is { row, col }: rows on the 'row' axis,
        -- columns on the 'column' axis.
        local index = case.axis == 'row' and 1 or 2
        local status_pos = vim.api.nvim_win_get_position(status_win)
        local edit_pos = vim.api.nvim_win_get_position(edit_win)
        local status_size = win_size(status_win, case.axis)
        local edit_size = win_size(edit_win, case.axis)

        assert.are.equal(expected_status_size(case.axis), status_size)

        -- The status window holds the editor edge opposite the preview and
        -- the edit window keeps the rest of the axis.
        if case.status_first then
            assert.are.equal(0, status_pos[index])
            assert.are.equal(status_size + 1, edit_pos[index])
        else
            assert.are.equal(0, edit_pos[index])
            assert.are.equal(edit_size + 1, status_pos[index])
        end

        local wins = normal_wins()

        assert.are.equal(2, #wins)
        assert.is_true(vim.tbl_contains(wins, edit_win))
        assert.is_true(vim.tbl_contains(wins, status_win))

        for _, win in ipairs(wins) do
            if win ~= status_win then
                vim.api.nvim_win_close(win, true)
            end
        end

        -- Before any preview the status window is the only window and fills
        -- the editor from its top-left corner.
        assert.are.same({ status_win }, normal_wins())
        assert.are.same({ 0, 0 }, vim.api.nvim_win_get_position(status_win))

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

    for _, case in ipairs(CASES) do
        it(case_title(case) .. ' anchors the status window', function()
            configure(case.position, 'stacked')
            local globals = editor_globals()
            local gsw = open_status_only(case)
            local status_win = assert(gsw.win)
            local expected = expected_status_size(case.axis)

            preview(gsw, 'tracked.txt')

            local preview_win = assert(gsw.preview.stacked.win)
            assert.is_true(vim.api.nvim_win_is_valid(preview_win))
            -- Opening the preview must not touch the editor defaults.
            assert.are.same(globals, editor_globals())

            -- `nvim_win_get_position` is { row, col }: rows on the 'row' axis,
            -- columns on the 'column' axis.
            local index = case.axis == 'row' and 1 or 2
            local cross = case.axis == 'row' and 2 or 1
            local status_pos = vim.api.nvim_win_get_position(status_win)
            local preview_pos = vim.api.nvim_win_get_position(preview_win)
            local status_size = win_size(status_win, case.axis)
            local preview_size = win_size(preview_win, case.axis)

            assert.are.equal(expected, status_size)
            -- Both windows span the whole editor on the crossed axis.
            assert.are.equal(0, status_pos[cross])
            assert.are.equal(0, preview_pos[cross])

            if case.axis == 'row' then
                assert.are.equal(
                    vim.o.columns,
                    vim.api.nvim_win_get_width(status_win)
                )
                assert.are.equal(
                    vim.o.columns,
                    vim.api.nvim_win_get_width(preview_win)
                )
            else
                assert.are.equal(
                    vim.api.nvim_win_get_height(status_win),
                    vim.api.nvim_win_get_height(preview_win)
                )
            end

            if case.status_first then
                assert.are.equal(0, status_pos[index])
                assert.are.equal(status_size + 1, preview_pos[index])
            else
                assert.are.equal(0, preview_pos[index])
                assert.are.equal(preview_size + 1, status_pos[index])
            end

            -- Closing the preview removes the split it created and gives the
            -- status window its size back.
            gsw.preview:close()

            assert.is_false(vim.api.nvim_win_is_valid(preview_win))
            assert.are.same({ status_win }, normal_wins())
            assert.are.same(globals, editor_globals())
        end)
    end

    it('restores the height fix when Ctrl-O leaves a down status', function()
        configure('down', 'stacked')
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo.winfixheight = false

        minifugit.status()
        local status_win = assert(assert(status_window()).win)
        assert.is_true(vim.wo[status_win].winfixheight)

        vim.api.nvim_set_current_win(status_win)
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes('<C-O>', true, false, true),
            'mx',
            false
        )
        assert.is_true(vim.wait(5000, function()
            return vim.api.nvim_get_current_buf() == file_buf
        end))
        -- The release of the status window, and with it the option restore, is
        -- scheduled after the buffer switch.
        helpers.settle_callbacks()

        assert.is_false(vim.wo[vim.api.nvim_get_current_win()].winfixheight)
    end)

    it('restores the height fix when a down status window closes', function()
        configure('down', 'stacked')
        local gsw = open_status_only(position_case('down'))
        local status_win = assert(gsw.win)
        assert.is_true(vim.wo[status_win].winfixheight)

        gsw:close()

        assert.is_true(vim.api.nvim_win_is_valid(status_win))
        assert.is_false(vim.wo[status_win].winfixheight)
    end)

    it('keeps both split sides side by side below a down status', function()
        configure('down', 'split')
        local gsw = open_status_only(position_case('down'))
        local status_win = assert(gsw.win)
        local status_height = expected_status_size('row')

        preview(gsw, 'tracked.txt')

        local left_win = assert(gsw.preview.left.win)
        local right_win = assert(gsw.preview.right.win)
        assert.is_true(vim.api.nvim_win_is_valid(left_win))
        assert.is_true(vim.api.nvim_win_is_valid(right_win))

        local left_width = vim.api.nvim_win_get_width(left_win)
        local right_width = vim.api.nvim_win_get_width(right_win)

        -- The status window keeps its full width and its height.
        assert.are.same({ 0, 0 }, vim.api.nvim_win_get_position(status_win))
        assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(status_win))
        assert.are.equal(status_height, vim.api.nvim_win_get_height(status_win))

        -- Both sides share the preview area below the status window.
        local preview_row = status_height + 1
        assert.are.same(
            { preview_row, 0 },
            vim.api.nvim_win_get_position(left_win)
        )
        assert.are.same(
            { preview_row, left_width + 1 },
            vim.api.nvim_win_get_position(right_win)
        )
        assert.are.equal(vim.o.columns, left_width + right_width + 1)
    end)

    it('opens the file left of the status with no edit window', function()
        configure('left', 'stacked')
        local gsw = open_status_only(position_case('left'))
        local status_win = assert(gsw.win)

        vim.api.nvim_set_current_win(status_win)
        vim.api.nvim_win_set_cursor(status_win, {
            helpers.row_containing(gsw.buf.id, 'tracked.txt'),
            0,
        })
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes('<CR>', true, false, true),
            'mx',
            false
        )
        helpers.wait_idle(status_window)

        local file_win

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local name =
                vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))

            if name:find('tracked.txt', 1, true) ~= nil then
                file_win = win
            end
        end

        assert.is_not_nil(file_win)
        local file_width = vim.api.nvim_win_get_width(file_win)
        local status_width = vim.api.nvim_win_get_width(status_win)

        -- The file takes the preview area, left of the full-height status
        -- window, and the two share the editor width.
        assert.are.same({ 0, 0 }, vim.api.nvim_win_get_position(file_win))
        assert.are.same(
            { 0, file_width + 1 },
            vim.api.nvim_win_get_position(status_win)
        )
        assert.are.equal(vim.o.columns, file_width + 1 + status_width)
    end)
end)
