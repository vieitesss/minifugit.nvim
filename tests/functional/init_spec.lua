---@diagnostic disable: undefined-field
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

    it('rejects invalid setup options', function()
        assert.has_error(function()
            require('minifugit').setup({ preview = { diff_layout = 'wide' } })
        end, "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'")

        assert.has_error(function()
            require('minifugit').setup({ status = { width = 2 } })
        end, 'opts.status.width must be a number between 0 and 1')
    end)
end)
