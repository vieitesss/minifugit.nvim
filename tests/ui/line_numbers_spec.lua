---@diagnostic disable: undefined-field
-- Regression: opening a file from a diff preview must keep the user's line
-- numbers, and opening the status window must not clobber the GLOBAL number
-- option. Both broke because window-local options set via `vim.wo[curwin]`
-- also overwrite the global default, and freshly-created preview splits
-- inherit the status window's stripped options.
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

local function set_current_number_locals(number, relativenumber)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_option_value('number', number, {
        scope = 'local',
        win = win,
    })
    vim.api.nvim_set_option_value('relativenumber', relativenumber, {
        scope = 'local',
        win = win,
    })
end

---Turn a buffer into an Oil-like buffer: acwrite, non-file name, and explorer
---local line numbers disabled.
local function make_oil_like(buf)
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '-oil-like')
    set_current_number_locals(false, false)
end

---Turn a buffer into a Netrw-like early directory buffer: normal buftype,
---directory name, no filetype yet, and explorer-local line numbers disabled.
local function make_netrw_like(buf, path)
    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].buftype = ''
    vim.bo[buf].filetype = ''
    set_current_number_locals(false, false)
end

describe('minifugit line numbers when opening code from a diff', function()
    local original_cwd, repo, minifugit
    local status_window, restore_constructor

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, 'p')
        helpers.run({ 'git', 'init', '-b', 'main' }, repo)
        helpers.run({ 'git', 'config', 'user.name', 'T' }, repo)
        helpers.run({ 'git', 'config', 'user.email', 't@e.test' }, repo)
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'one' })
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'init' }, repo)
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        -- User's global default: line numbers on.
        vim.go.number = true
        vim.go.relativenumber = true
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        helpers.reload_minifugit()
        status_window, restore_constructor = helpers.capture_status_windows()
        minifugit = require('minifugit').setup({
            status = { width = 0.4, min_width = 20 },
            preview = { diff_layout = 'stacked' },
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

    local function select_tracked_entry()
        local gsw = status_window()
        local entry_row
        for row, line in
            ipairs(vim.api.nvim_buf_get_lines(gsw.buf.id, 0, -1, false))
        do
            if line:find('tracked.txt', 1, true) then
                entry_row = row
            end
        end
        assert.is_not_nil(entry_row)
        vim.api.nvim_win_set_cursor(gsw.win, { entry_row, 0 })
    end

    ---Preview the diff for tracked.txt, jump to source, return the opened
    ---window's number/relativenumber.
    local function preview_and_goto()
        local gsw = status_window()
        select_tracked_entry()
        assert.is_true(gsw:diff_entry())

        local pv = gsw.preview.stacked.win
            or gsw.preview.right.win
            or gsw.preview.left.win
        vim.api.nvim_set_current_win(pv)
        local dl = vim.api.nvim_buf_get_lines(
            vim.api.nvim_win_get_buf(pv),
            0,
            -1,
            false
        )
        for row, line in ipairs(dl) do
            if line:find('two', 1, true) then
                vim.api.nvim_win_set_cursor(pv, { row, 0 })
                break
            end
        end
        assert.is_true(gsw.preview:goto_code())
        local win = vim.api.nvim_get_current_win()
        return vim.wo[win].number, vim.wo[win].relativenumber
    end

    it('does not clobber the global number option on status open', function()
        make_oil_like(vim.api.nvim_get_current_buf())
        minifugit.status()
        assert.is_true(vim.go.number)
        assert.is_true(vim.go.relativenumber)
    end)

    it('allows a directory explorer as preview target', function()
        local explorer_win = vim.api.nvim_get_current_win()
        make_netrw_like(vim.api.nvim_get_current_buf(), repo)

        minifugit.status()
        select_tracked_entry()
        assert.is_true(status_window():diff_entry())

        local preview_win = status_window().preview.stacked.win
            or status_window().preview.left.win
        assert.are.equal(explorer_win, preview_win)
    end)

    it('keeps line numbers opening code from a preview over netrw', function()
        make_netrw_like(vim.api.nvim_get_current_buf(), repo)
        minifugit.status()
        local number, relativenumber = preview_and_goto()
        assert.is_true(number)
        assert.is_true(relativenumber)
    end)

    it('keeps line numbers opening code from a stacked preview', function()
        make_oil_like(vim.api.nvim_get_current_buf())
        minifugit.status()
        local number, relativenumber = preview_and_goto()
        assert.is_true(number)
        assert.is_true(relativenumber)
    end)

    it('keeps line numbers opening code from a split preview', function()
        minifugit.options.preview.diff_layout = 'split'
        make_oil_like(vim.api.nvim_get_current_buf())
        minifugit.status()
        local number, relativenumber = preview_and_goto()
        assert.is_true(number)
        assert.is_true(relativenumber)
    end)
end)
