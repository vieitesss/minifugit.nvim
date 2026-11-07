---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local LINE_NAMESPACE = 'minifugit.ui.split_line'
local INTRALINE_NAMESPACE = 'minifugit.ui.split_intra'

---@param buf integer
---@param text string
---@return integer
local function row_containing(buf, text)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(text, 1, true) ~= nil then
            return row
        end
    end

    error('Expected row containing not found: ' .. text)
end

---@param name string
---@return integer
local function diff_win_named(name)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        local buf_name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))

        if buf_name:match('^(.-) %[%d+%]$') == name then
            return win
        end
    end

    error('Expected visible diff buffer: ' .. name)
end

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
        for name in pairs(package.loaded) do
            if name == 'minifugit' or name:match('^minifugit%.') then
                package.loaded[name] = nil
            end
        end
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit = require('minifugit').setup({
            preview = { diff_layout = 'split' },
        })
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
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        assert.is_true(gsw:diff_entry())

        return vim.api.nvim_win_get_buf(diff_win_named('Minifugit diff left')),
            vim.api.nvim_win_get_buf(diff_win_named('Minifugit diff right'))
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
