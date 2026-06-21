local DiffWindow = require('minifugit.ui.status.preview.diff_window')

describe('minifugit.ui.status.preview.diff_window', function()
    describe('DiffWindow.new', function()
        it('creates a stacked instance with correct defaults', function()
            local dw = DiffWindow.new(false)

            assert.is_not_nil(dw)
            assert.is_false(dw.is_split)
            assert.is_nil(dw.win)
            assert.is_nil(dw.buf)
            assert.is_nil(dw.prev_buf)
            assert.is_nil(dw.prev_winopts)
            assert.is_false(dw.created)
        end)

        it('creates a split instance with is_split = true', function()
            local dw = DiffWindow.new(true)

            assert.is_true(dw.is_split)
        end)

        it('validates is_split must be boolean', function()
            assert.has_error(function()
                DiffWindow.new('yes')
            end)
        end)
    end)

    describe('DiffWindow:has_open', function()
        it('returns false when buf is nil', function()
            local dw = DiffWindow.new(false)
            dw.win = vim.api.nvim_get_current_win()

            assert.is_false(dw:has_open())
        end)

        it('returns false when win is nil', function()
            local dw = DiffWindow.new(false)
            local buf = vim.api.nvim_create_buf(false, true)
            dw.buf = {
                id = buf,
                is_valid = function()
                    return true
                end,
            }

            assert.is_false(dw:has_open())
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it('returns false when win does not show the buf', function()
            local dw = DiffWindow.new(false)
            local buf = vim.api.nvim_create_buf(false, true)
            local other_buf = vim.api.nvim_create_buf(false, true)
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win, other_buf)
            dw.win = win
            dw.buf = {
                id = buf,
                is_valid = function()
                    return true
                end,
            }

            assert.is_false(dw:has_open())
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.api.nvim_buf_delete(other_buf, { force = true })
        end)

        it('returns true when win shows the buf', function()
            local dw = DiffWindow.new(false)
            local buf = vim.api.nvim_create_buf(false, true)
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win, buf)
            dw.win = win
            dw.buf = {
                id = buf,
                is_valid = function()
                    return true
                end,
            }

            assert.is_true(dw:has_open())
            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)

    describe('DiffWindow:clear', function()
        it(
            'resets win, prev_buf, prev_winopts and created to defaults',
            function()
                local dw = DiffWindow.new(false)
                dw.win = 42
                dw.prev_buf = 99
                dw.prev_winopts = { wrap = true }
                dw.created = true

                dw:clear()

                assert.is_nil(dw.win)
                assert.is_nil(dw.prev_buf)
                assert.is_nil(dw.prev_winopts)
                assert.is_false(dw.created)
            end
        )

        it('does not touch buf or is_split', function()
            local dw = DiffWindow.new(true)
            local fake_buf = { id = 1 }
            dw.buf = fake_buf
            dw.win = 10

            dw:clear()

            assert.are.equal(fake_buf, dw.buf)
            assert.is_true(dw.is_split)
        end)
    end)

    describe('DiffWindow:restore_or_close', function()
        it('returns false and clears when win is invalid', function()
            local dw = DiffWindow.new(false)
            dw.win = 999999 -- not a real window
            dw.created = true

            local result = dw:restore_or_close(false)

            assert.is_false(result)
            assert.is_nil(dw.win)
            assert.is_false(dw.created)
        end)

        it('restores winopts and clears when keep_win is true', function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.cmd('split')
            local win = vim.api.nvim_get_current_win()
            local original_opts = { wrap = vim.wo[win].wrap }

            local dw = DiffWindow.new(false)
            dw.win = win
            dw.prev_winopts = original_opts
            dw.created = false

            local result = dw:restore_or_close(true)

            assert.is_true(result)
            assert.is_nil(dw.win)

            -- close the split we opened
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)
end)
