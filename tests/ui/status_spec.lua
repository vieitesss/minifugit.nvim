---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@param expected string
local function assert_has_line(lines, expected)
    for _, line in ipairs(lines) do
        if line == expected then
            return
        end
    end

    assert.fail('Expected line not found: ' .. expected)
end

---@param lines string[]
---@param expected string
local function assert_has_line_containing(lines, expected)
    for _, line in ipairs(lines) do
        if line:find(expected, 1, true) ~= nil then
            return
        end
    end

    assert.fail('Expected line containing not found: ' .. expected)
end

---@param buf integer
---@param text string
---@return integer
local function row_containing(buf, text)
    for row, line in ipairs(buffer_lines(buf)) do
        if line:find(text, 1, true) ~= nil then
            return row
        end
    end

    error('Expected row containing not found: ' .. text)
end

---@param win integer
---@return table<string, any>
local function capture_winopts(win)
    return {
        number = vim.wo[win].number,
        relativenumber = vim.wo[win].relativenumber,
        signcolumn = vim.wo[win].signcolumn,
        foldcolumn = vim.wo[win].foldcolumn,
        wrap = vim.wo[win].wrap,
        cursorline = vim.wo[win].cursorline,
        winfixwidth = vim.wo[win].winfixwidth,
        winbar = vim.wo[win].winbar,
        diff = vim.wo[win].diff,
        fillchars = vim.wo[win].fillchars,
        statuscolumn = vim.wo[win].statuscolumn,
    }
end

---@param actual table<string, any>
---@param expected table<string, any>
local function assert_winopts(actual, expected)
    for key, value in pairs(expected) do
        assert.are.equal(value, actual[key], key)
    end
end

---@param keys string
local function normal_keys(keys)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        'nx',
        false
    )
end

---@param actual table<string, any>
---@param expected table<string, any>
---@return boolean
local function winopts_match(actual, expected)
    for key, value in pairs(expected) do
        if actual[key] ~= value then
            return false
        end
    end

    return true
end

---@param buf integer
---@param expected_opts? table<string, any>
local function wait_for_current_buf(buf, expected_opts)
    assert.is_true(vim.wait(1000, function()
        if vim.api.nvim_get_current_buf() ~= buf then
            return false
        end

        return expected_opts == nil
            or winopts_match(
                capture_winopts(vim.api.nvim_get_current_win()),
                expected_opts
            )
    end))
end

describe('minifugit status UI', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Minifugit
    local minifugit

    before_each(function()
        package.loaded.minifugit = nil
        original_cwd = vim.fn.getcwd()
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
        minifugit = require('minifugit').setup({
            status = { width = 0.5, min_width = 20 },
        })
    end)

    after_each(function()
        if minifugit ~= nil then
            minifugit.reset()
        end

        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('%bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))

        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

    it(
        'opens a status window with the expected buffer options and contents',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'staged.txt'),
                { 'staged' }
            )
            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            helpers.run({ 'git', 'add', 'staged.txt' }, repo)

            minifugit.status()

            ---@type GitStatusWindow
            local gsw = minifugit.gsw
            assert.is_not_nil(gsw)
            assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
            assert.is_true(vim.api.nvim_buf_is_valid(gsw.buf.id))
            assert.are.equal(gsw.buf.id, vim.api.nvim_win_get_buf(gsw.win))
            assert.are.equal('nofile', vim.bo[gsw.buf.id].buftype)
            assert.are.equal('hide', vim.bo[gsw.buf.id].bufhidden)
            assert.are.equal(false, vim.bo[gsw.buf.id].modifiable)
            assert.are.equal('minifugit', vim.bo[gsw.buf.id].filetype)
            assert.are.equal(false, vim.wo[gsw.win].number)
            assert.are.equal(false, vim.wo[gsw.win].relativenumber)
            assert.are.equal('no', vim.wo[gsw.win].signcolumn)
            assert.are.equal(true, vim.wo[gsw.win].cursorline)
            assert.are.equal(true, vim.wo[gsw.win].winfixwidth)

            local lines = buffer_lines(gsw.buf.id)
            assert_has_line(lines, 'HEAD: main')
            assert_has_line(lines, 'Unstaged (1)')
            assert_has_line(lines, ' M tracked.txt')
            assert_has_line(lines, 'Staged (1)')
            assert_has_line(lines, 'A  staged.txt')
            assert_has_line(lines, 'Untracked (1)')
            assert_has_line(lines, '?? untracked.txt')
        end
    )

    it(
        'refreshes and reuses the existing status buffer on repeated calls',
        function()
            minifugit.status()

            ---@type GitStatusWindow
            local first = minifugit.gsw
            local first_buf = first.buf.id
            local first_win = assert(first.win)

            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            minifugit.status()

            assert.are.equal(first, minifugit.gsw)
            assert.are.equal(first_buf, minifugit.gsw.buf.id)
            assert.are.equal(first_win, minifugit.gsw.win)
            assert.are.equal(first_buf, vim.api.nvim_win_get_buf(first_win))
            assert_has_line(buffer_lines(first_buf), '?? untracked.txt')
        end
    )

    it('closes the status window through its normal mode mapping', function()
        minifugit.status()

        ---@type GitStatusWindow
        local gsw = minifugit.gsw
        local win = assert(gsw.win)
        local buf = gsw.buf.id

        vim.api.nvim_set_current_win(win)
        vim.cmd.normal('q')

        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_nil(gsw.win)
    end)

    it('renders a helpful message outside a git repository', function()
        local not_repo = vim.fn.tempname()
        vim.fn.mkdir(not_repo, 'p')
        vim.cmd.cd(vim.fn.fnameescape(not_repo))

        minifugit.status()

        local lines = buffer_lines(minifugit.gsw.buf.id)
        assert_has_line(lines, 'HEAD: (none)')
        assert_has_line_containing(lines, 'Not inside a git repository')

        vim.fn.delete(not_repo, 'rf')
    end)

    it(
        'keeps a real file window options unchanged after focusing status',
        function()
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            vim.wo[file_win].cursorline = false
            vim.wo[file_win].winfixwidth = false
            vim.wo[file_win].winbar = 'real file'
            vim.wo[file_win].statuscolumn = 'user-statuscolumn'
            local before = capture_winopts(file_win)

            minifugit.status()
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            vim.cmd.normal('q')

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'restores a real file window options after closing stacked diff',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo[file_win].number = true
            vim.wo[file_win].relativenumber = true
            vim.wo[file_win].signcolumn = 'yes:2'
            vim.wo[file_win].foldcolumn = '2'
            vim.wo[file_win].wrap = true
            vim.wo[file_win].cursorline = true
            vim.wo[file_win].winfixwidth = false
            vim.wo[file_win].winbar = 'real file'
            vim.wo[file_win].statuscolumn = 'user-statuscolumn'
            local before = capture_winopts(file_win)

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            assert.are.equal(
                minifugit.gsw.diff_buf.id,
                vim.api.nvim_win_get_buf(file_win)
            )
            assert.are.equal(false, vim.wo[file_win].number)
            assert.are.equal(false, vim.wo[file_win].relativenumber)
            assert.are.equal('no', vim.wo[file_win].signcolumn)

            minifugit.gsw:close()

            assert.is_true(vim.api.nvim_win_is_valid(file_win))
            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
            assert_winopts(capture_winopts(file_win), before)
        end
    )

    it(
        'focuses an already open diff when showing the same entry diff',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            vim.api.nvim_win_set_cursor(
                minifugit.gsw.win,
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )

            assert.is_true(minifugit.gsw:diff_entry())
            vim.api.nvim_set_current_win(minifugit.gsw.win)
            assert.is_true(minifugit.gsw:diff_entry())

            assert.are.equal(
                minifugit.gsw.diff_win,
                vim.api.nvim_get_current_win()
            )
        end
    )

    it('restores real file window options after closing split diff', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo[file_win].number = false
        vim.wo[file_win].relativenumber = true
        vim.wo[file_win].signcolumn = 'auto:2'
        vim.wo[file_win].foldcolumn = '1'
        vim.wo[file_win].wrap = true
        vim.wo[file_win].cursorline = true
        vim.wo[file_win].winfixwidth = false
        vim.wo[file_win].winbar = 'real file split'
        vim.wo[file_win].statuscolumn = 'split-statuscolumn'
        local before = capture_winopts(file_win)

        minifugit.options.preview.diff_layout = 'split'
        minifugit.status()
        vim.api.nvim_win_set_cursor(
            minifugit.gsw.win,
            { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
        )
        minifugit.gsw:diff_entry()

        assert.are.equal(
            minifugit.gsw.diff_left_buf.id,
            vim.api.nvim_win_get_buf(file_win)
        )
        assert.are.equal(true, vim.wo[file_win].diff)
        assert.are.equal(false, vim.wo[file_win].relativenumber)
        assert.are.equal('yes:1', vim.wo[file_win].signcolumn)

        minifugit.gsw:close()

        assert.is_true(vim.api.nvim_win_is_valid(file_win))
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), before)
    end)

    it('restores file options when Ctrl-O leaves the status buffer', function()
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo.number = true
        vim.wo.relativenumber = true
        vim.wo.signcolumn = 'yes:2'
        vim.wo.foldcolumn = '2'
        vim.wo.wrap = true
        vim.wo.cursorline = false
        vim.wo.winbar = 'real file jump'
        vim.wo.statuscolumn = 'jump-statuscolumn'
        local file_opts = capture_winopts(vim.api.nvim_get_current_win())

        minifugit.status()
        local status_win = assert(minifugit.gsw.win)
        local status_buf = minifugit.gsw.buf.id
        local status_opts = capture_winopts(status_win)

        vim.api.nvim_set_current_win(status_win)
        normal_keys('<C-O>')
        wait_for_current_buf(file_buf, file_opts)

        local current_win = vim.api.nvim_get_current_win()
        assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
        assert_winopts(capture_winopts(current_win), file_opts)

        normal_keys('<C-I>')
        wait_for_current_buf(status_buf, status_opts)

        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert_winopts(
            capture_winopts(vim.api.nvim_get_current_win()),
            status_opts
        )
    end)

    it(
        'restores file options when Ctrl-O leaves a stacked diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo.number = true
            vim.wo.relativenumber = true
            vim.wo.signcolumn = 'yes:2'
            vim.wo.foldcolumn = '2'
            vim.wo.wrap = true
            vim.wo.cursorline = true
            vim.wo.winbar = 'real file diff jump'
            vim.wo.statuscolumn = 'diff-jump-statuscolumn'
            local file_opts = capture_winopts(vim.api.nvim_get_current_win())

            minifugit.options.preview.diff_layout = 'stacked'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            local diff_win = assert(minifugit.gsw.diff_win)
            local diff_buf = minifugit.gsw.diff_buf.id
            local diff_opts = capture_winopts(diff_win)
            vim.api.nvim_set_current_win(diff_win)
            normal_keys('<C-O>')
            wait_for_current_buf(file_buf, file_opts)

            assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                file_opts
            )

            normal_keys('<C-I>')
            wait_for_current_buf(diff_buf, diff_opts)

            assert.are.equal(diff_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                diff_opts
            )
        end
    )

    it(
        'restores file options when Ctrl-O leaves a split diff buffer',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )
            vim.cmd.edit(
                vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt'))
            )
            local file_buf = vim.api.nvim_get_current_buf()
            vim.wo.number = false
            vim.wo.relativenumber = true
            vim.wo.signcolumn = 'auto:2'
            vim.wo.foldcolumn = '1'
            vim.wo.wrap = true
            vim.wo.cursorline = true
            vim.wo.winbar = 'real file split jump'
            vim.wo.statuscolumn = 'split-jump-statuscolumn'
            local file_opts = capture_winopts(vim.api.nvim_get_current_win())

            minifugit.options.preview.diff_layout = 'split'
            minifugit.status()
            vim.api.nvim_win_set_cursor(
                assert(minifugit.gsw.win),
                { row_containing(minifugit.gsw.buf.id, 'tracked.txt'), 0 }
            )
            minifugit.gsw:diff_entry()

            local diff_win = assert(minifugit.gsw.diff_left_win)
            local diff_buf = minifugit.gsw.diff_left_buf.id
            local diff_opts = capture_winopts(diff_win)
            vim.api.nvim_set_current_win(diff_win)
            normal_keys('<C-O>')
            wait_for_current_buf(file_buf, file_opts)

            assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                file_opts
            )

            normal_keys('<C-I>')
            wait_for_current_buf(diff_buf, diff_opts)

            assert.are.equal(diff_buf, vim.api.nvim_get_current_buf())
            assert_winopts(
                capture_winopts(vim.api.nvim_get_current_win()),
                diff_opts
            )
        end
    )
end)
