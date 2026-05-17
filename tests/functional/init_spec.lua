---@diagnostic disable: undefined-field
describe('minifugit', function()
    before_each(function()
        package.loaded.minifugit = nil
    end)

    it('sets defaults and marks setup as done', function()
        ---@type Minifugit
        local minifugit = require('minifugit').setup()

        assert.is_true(minifugit.did_setup)
        assert.are.equal(false, minifugit.options.preview.wrap)
        assert.are.equal('stacked', minifugit.options.preview.diff_layout)
        assert.are.equal(0.4, minifugit.options.status.width)
    end)

    it('merges valid options without losing defaults', function()
        ---@type Minifugit
        local minifugit = require('minifugit').setup({
            preview = { show_metadata = false, diff_layout = 'split' },
            status = { min_width = 30 },
        })

        assert.are.equal(false, minifugit.options.preview.show_metadata)
        assert.are.equal('split', minifugit.options.preview.diff_layout)
        assert.are.equal(false, minifugit.options.preview.wrap)
        assert.are.equal(30, minifugit.options.status.min_width)
        assert.are.equal(0.4, minifugit.options.status.width)
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
