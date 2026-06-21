local DiffPreview = require('minifugit.ui.status.preview.diff_preview')

---@return table
local function make_host(overrides)
    ---@type table
    local host = {
        options = {
            preview = {
                wrap = false,
                show_line_numbers = true,
                show_metadata = true,
                diff_layout = 'stacked',
                diff_auto_threshold = 120,
            },
            status = { width = 0.4, min_width = 20, open_in_tab = false },
        },
        groups = {},
        lines = {},
        refresh = function(_state) end,
        begin_related_buffer_open = function()
            return function() end
        end,
        toggle_help = function() end,
    }
    return vim.tbl_extend('force', host, overrides or {})
end

describe('DiffPreview', function()
    describe('DiffPreview.new', function()
        it('creates an instance with correct defaults from options', function()
            local dp = DiffPreview.new(make_host())

            assert.is_not_nil(dp)
            assert.is_false(dp.wrap)
            assert.is_true(dp.show_numbers)
            assert.is_true(dp.show_headers)
            assert.are.equal('stacked', dp.layout)
            assert.is_nil(dp.layout_override)
            assert.is_nil(dp.preview_key)
            assert.is_nil(dp.raw_lines)
            assert.is_nil(dp.raw_rows)
            assert.is_nil(dp.hunks)
            assert.is_nil(dp.section)
            assert.is_nil(dp.context_entry)
            assert.is_not_nil(dp.stacked)
            assert.is_not_nil(dp.left)
            assert.is_not_nil(dp.right)
        end)

        it('seeds wrap = true when options.preview.wrap is true', function()
            local host = make_host()
            host.options.preview.wrap = true
            local dp = DiffPreview.new(host)
            assert.is_true(dp.wrap)
        end)

        it('seeds layout from options', function()
            local host = make_host()
            host.options.preview.diff_layout = 'split'
            local dp = DiffPreview.new(host)
            assert.are.equal('split', dp.layout)
        end)

        it('seeds show_numbers = false when options say so', function()
            local host = make_host()
            host.options.preview.show_line_numbers = false
            local dp = DiffPreview.new(host)
            assert.is_false(dp.show_numbers)
        end)

        it('seeds show_headers = false when options say so', function()
            local host = make_host()
            host.options.preview.show_metadata = false
            local dp = DiffPreview.new(host)
            assert.is_false(dp.show_headers)
        end)

        it('validates host must be a table', function()
            assert.has_error(function()
                DiffPreview.new('not a table')
            end)
        end)

        it('validates host.options.preview must exist', function()
            assert.has_error(function()
                DiffPreview.new({ options = {}, groups = {} })
            end)
        end)
    end)

    describe('DiffPreview:has_open', function()
        it('returns false when no diff windows are open', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:has_open())
        end)
    end)

    describe('DiffPreview:focus', function()
        it('returns false when no diff windows are open', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:focus())
        end)
    end)

    describe('DiffPreview:toggle_wrap', function()
        it('returns false when no diff is open', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:toggle_wrap())
        end)
    end)

    describe('DiffPreview:set_layout', function()
        it(
            'sets layout_override regardless of whether a diff is open',
            function()
                local dp = DiffPreview.new(make_host())
                dp:set_layout('split')
                assert.are.equal('split', dp.layout_override)
            end
        )
    end)

    describe('DiffPreview:toggle_layout', function()
        it('sets layout_override without opening a diff', function()
            local dp = DiffPreview.new(make_host())
            dp:toggle_layout()
            -- default layout is stacked, so toggling with no open diff sets split
            assert.are.equal('split', dp.layout_override)
        end)

        it('toggles back to stacked from split', function()
            local dp = DiffPreview.new(make_host())
            dp.layout_override = 'split'
            dp:toggle_layout()
            assert.are.equal('stacked', dp.layout_override)
        end)
    end)

    describe('DiffPreview:jump_hunk', function()
        it('returns false when no diff is open', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:jump_hunk(1))
        end)
    end)

    describe('DiffPreview:preview_current_entry', function()
        it('returns false and notifies when no entry under cursor', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:preview_current_entry())
        end)

        it('returns false silently when notify = false', function()
            local dp = DiffPreview.new(make_host())
            -- just ensure no error is raised
            assert.is_false(dp:preview_current_entry({ notify = false }))
        end)
    end)

    describe('DiffPreview:preview_current_commit', function()
        it('returns false when no commit under cursor', function()
            local dp = DiffPreview.new(make_host())
            assert.is_false(dp:preview_current_commit())
        end)
    end)

    describe('DiffPreview:refresh', function()
        it('returns nil (no-op) when no diff is open', function()
            local dp = DiffPreview.new(make_host())
            assert.is_nil(dp:refresh())
        end)
    end)
end)
