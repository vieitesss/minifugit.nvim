---@diagnostic disable: undefined-field
---@type MinifugitTestHelpers
local helpers = dofile(vim.fn.getcwd() .. '/tests/helpers.lua')

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
end)
