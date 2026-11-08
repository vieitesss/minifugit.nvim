---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local LINE_NAMESPACE = 'minifugit.ui.split_line'
local INTRALINE_NAMESPACE = 'minifugit.ui.split_intra'

---@param buf integer
---@param name string
---@return integer[][]
local function extmarks(buf, name)
    local namespace = vim.api.nvim_create_namespace(name)

    return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {
        details = true,
    })
end

describe('minifugit split render extmarks', function()
    local original_cwd, repo, minifugit
    local status_window, restore_constructor

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({ ['tracked.txt'] = { 'a', 'b', 'c' } })
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        helpers.reload_minifugit()
        status_window, restore_constructor = helpers.capture_status_windows()
        -- Reads are async: settle them before the test asserts the render.
        minifugit = helpers.awaiting_reads(
            require('minifugit').setup({
                preview = { diff_layout = 'split' },
            }),
            status_window
        )
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
        if repo then
            vim.fn.delete(repo, 'rf')
        end
    end)

    ---@return integer left_buf, integer right_buf
    local function show_tracked_diff()
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = status_window()
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { helpers.row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        assert.is_true(gsw:diff_entry())
        helpers.wait_idle(status_window)

        local _, left_buf = helpers.diff_win_named('Minifugit diff left')
        local _, right_buf = helpers.diff_win_named('Minifugit diff right')

        return left_buf, right_buf
    end

    it('applies split extmarks with their groups and priorities', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'a', 'B', 'c' }
        )
        local left_buf, right_buf = show_tracked_diff()

        local left_line = assert(extmarks(left_buf, LINE_NAMESPACE)[1])
        assert.are.same({ 1, 0 }, { left_line[2], left_line[3] })
        assert.are.equal(200, left_line[4].priority)
        assert.is_true(left_line[4].hl_eol)
        assert.are.equal('MiniFugitDiffRemoved', left_line[4].hl_group)

        local right_line = assert(extmarks(right_buf, LINE_NAMESPACE)[1])
        assert.are.same({ 1, 0 }, { right_line[2], right_line[3] })
        assert.are.equal(200, right_line[4].priority)
        assert.is_true(right_line[4].hl_eol)
        assert.are.equal('MiniFugitDiffAdded', right_line[4].hl_group)

        local left_intraline =
            assert(extmarks(left_buf, INTRALINE_NAMESPACE)[1])
        assert.are.same({ 1, 0 }, { left_intraline[2], left_intraline[3] })
        assert.are.equal(201, left_intraline[4].priority)
        assert.are.equal(
            'MiniFugitDiffRemovedIntraline',
            left_intraline[4].hl_group
        )

        local right_intraline =
            assert(extmarks(right_buf, INTRALINE_NAMESPACE)[1])
        assert.are.same({ 1, 0 }, { right_intraline[2], right_intraline[3] })
        assert.are.equal(201, right_intraline[4].priority)
        assert.are.equal(
            'MiniFugitDiffAddedIntraline',
            right_intraline[4].hl_group
        )
    end)

    it('clears stale split extmarks when the preview refreshes', function()
        local path = vim.fs.joinpath(repo, 'tracked.txt')
        helpers.write_file(path, { 'a', 'X', 'b', 'Y', 'c' })
        local left_buf, right_buf = show_tracked_diff()

        assert.are.equal(0, #extmarks(left_buf, LINE_NAMESPACE))
        local before = extmarks(right_buf, LINE_NAMESPACE)
        assert.are.equal(2, #before)
        assert.are.same({ 1, 3 }, { before[1][2], before[2][2] })

        helpers.write_file(path, { 'a', 'X', 'b', 'c' })
        minifugit.status()

        local after = extmarks(right_buf, LINE_NAMESPACE)
        assert.are.equal(1, #after)
        assert.are.equal(1, after[1][2])
        assert.are.equal(0, #extmarks(left_buf, LINE_NAMESPACE))
    end)
end)
