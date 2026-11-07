---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type MinifugitTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

describe('minifugit', function()
    before_each(function()
        package.loaded.minifugit = nil
        vim.g.minifugit = nil
    end)

    it('sets defaults and marks setup as done', function()
        ---@type Minifugit
        local minifugit = require('minifugit').setup()

        assert.is_true(minifugit.did_setup)
        assert.are.equal(false, minifugit.options.preview.wrap)
        assert.are.equal('stacked', minifugit.options.preview.diff_layout)
        assert.are.equal(0.4, minifugit.options.status.width)
        assert.are.equal(false, minifugit.options.status.open_in_tab)
    end)

    it('merges valid options without losing defaults', function()
        ---@type Minifugit
        local minifugit = require('minifugit').setup({
            preview = { show_metadata = false, diff_layout = 'split' },
            status = { min_width = 30, open_in_tab = true },
        })

        assert.are.equal(false, minifugit.options.preview.show_metadata)
        assert.are.equal('split', minifugit.options.preview.diff_layout)
        assert.are.equal(false, minifugit.options.preview.wrap)
        assert.are.equal(30, minifugit.options.status.min_width)
        assert.are.equal(0.4, minifugit.options.status.width)
        assert.are.equal(true, minifugit.options.status.open_in_tab)
    end)

    it('reads global configuration without setup', function()
        vim.g.minifugit = {
            preview = { diff_layout = 'auto' },
            status = { open_in_tab = true },
        }

        ---@type Minifugit
        local minifugit = require('minifugit')

        assert.are.equal('auto', minifugit.options.preview.diff_layout)
        assert.are.equal(true, minifugit.options.status.open_in_tab)
        assert.are.equal(false, minifugit.options.preview.wrap)
    end)

    it('lets setup options override global configuration', function()
        vim.g.minifugit = {
            preview = { diff_layout = 'auto', show_metadata = false },
        }

        ---@type Minifugit
        local minifugit = require('minifugit').setup({
            preview = { diff_layout = 'split' },
        })

        assert.are.equal('split', minifugit.options.preview.diff_layout)
        assert.are.equal(false, minifugit.options.preview.show_metadata)
    end)

    describe('open', function()
        local original_cwd
        local repo
        local minifugit

        before_each(function()
            original_cwd = vim.fn.getcwd()
            repo = vim.fn.tempname()
            vim.fn.mkdir(repo, 'p')
            helpers.run({ 'git', 'init', '-b', 'main' }, repo)
            vim.cmd.cd(vim.fn.fnameescape(repo))
            vim.cmd.enew()
            minifugit = require('minifugit').setup()
        end)

        after_each(function()
            minifugit.reset()
            vim.cmd('silent! tabonly!')
            vim.cmd.only({ mods = { emsg_silent = true } })
            vim.cmd('%bwipeout!')
            vim.cmd.cd(vim.fn.fnameescape(original_cwd))
            vim.fn.delete(repo, 'rf')
        end)

        for _, target in ipairs({ 'missing', 'non-git', 'file' }) do
            it(
                'rejects a ' .. target .. ' cwd without editor changes',
                function()
                    local cwd = vim.fs.joinpath(repo, 'missing')
                    if target == 'non-git' then
                        helpers.run({ 'git', 'init', '-b', 'main' }, repo)
                        vim.fn.delete(vim.fs.joinpath(repo, '.git'), 'rf')
                        cwd = repo
                    elseif target == 'file' then
                        cwd = vim.fs.joinpath(repo, 'file.txt')
                        helpers.write_file(cwd, { 'not a directory' })
                    end
                    local wins = vim.api.nvim_list_wins()
                    local bufs = vim.api.nvim_list_bufs()
                    local tabs = vim.api.nvim_list_tabpages()

                    local ok, err =
                        minifugit.open({ cwd = cwd, open_in_tab = true })

                    assert.is_nil(ok)
                    assert.are.equal('string', type(err))
                    assert.is_true(#err > 0)
                    assert.are.same(wins, vim.api.nvim_list_wins())
                    assert.are.same(bufs, vim.api.nvim_list_bufs())
                    assert.are.same(tabs, vim.api.nvim_list_tabpages())
                end
            )
        end

        it('validates open option types before creating UI', function()
            local wins = vim.api.nvim_list_wins()
            local bufs = vim.api.nvim_list_bufs()
            local tabs = vim.api.nvim_list_tabpages()
            for _, opts in ipairs({
                'not a table',
                { cwd = false },
                { open_in_tab = 'yes' },
                { on_close = true },
            }) do
                assert.has_error(function()
                    minifugit.open(opts)
                end)
            end
            assert.are.same(wins, vim.api.nvim_list_wins())
            assert.are.same(bufs, vim.api.nvim_list_bufs())
            assert.are.same(tabs, vim.api.nvim_list_tabpages())
        end)

        it('keeps status working and ignores the open return value', function()
            assert.is_nil(minifugit.status())
            assert.are.equal('minifugit', vim.bo.filetype)
        end)

        it('keeps the status UI for an omitted non-git cwd', function()
            vim.fn.delete(vim.fs.joinpath(repo, '.git'), 'rf')
            assert.is_nil(minifugit.status())
            assert.are.equal('minifugit', vim.bo.filetype)
            helpers.assert_has_line_containing(
                vim.api.nvim_buf_get_lines(0, 0, -1, false),
                'Not inside a git repository'
            )
        end)

        it(
            'opens an explicit relative subdirectory without changing cwd',
            function()
                vim.fn.mkdir(vim.fs.joinpath(repo, 'nested'), 'p')
                local cwd = vim.fn.getcwd()
                assert.is_true(minifugit.open({ cwd = './nested/../nested' }))
                assert.are.equal(cwd, vim.fn.getcwd())
                helpers.assert_has_line_containing(
                    vim.api.nvim_buf_get_lines(0, 0, -1, false),
                    'Root: ' .. vim.fn.resolve(repo)
                )
            end
        )

        it('returns true when opening a valid repository', function()
            assert.is_true(minifugit.open({}))
            assert.are.equal('minifugit', vim.bo.filetype)
            helpers.assert_has_line_containing(
                vim.api.nvim_buf_get_lines(0, 0, -1, false),
                'Root: ' .. vim.fn.resolve(repo)
            )
        end)
    end)

    it('rejects invalid setup options', function()
        assert.has_error(function()
            require('minifugit').setup({ preview = { diff_layout = 'wide' } })
        end, "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'")

        assert.has_error(function()
            require('minifugit').setup({ status = { width = 2 } })
        end, 'opts.status.width must be a number between 0 and 1')
    end)
end)
