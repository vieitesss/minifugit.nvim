---@diagnostic disable: undefined-field
local helpers = dofile('tests/helpers.lua')

describe('minifugit status after a session restore', function()
    local original_cwd
    local repo
    local session_file
    local minifugit
    local find_status
    local restore_capture

    ---@return integer[]
    local function restored_buffers()
        return vim.tbl_filter(function(bufnr)
            local name =
                vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':t')
            return name:match('^Minifugit %[%d+%]$') ~= nil
                and vim.bo[bufnr].buftype == ''
        end, vim.api.nvim_list_bufs())
    end

    ---Save the session with status open, then reset the editor and load it,
    ---as `:restart` does.
    local function restart()
        minifugit.status()
        assert.is_not_nil(find_status())
        vim.cmd.mksession({ vim.fn.fnameescape(session_file), bang = true })

        minifugit.reset()
        vim.cmd('silent! tabonly!')
        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('silent! %bwipeout!')

        vim.cmd.source(vim.fn.fnameescape(session_file))
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({ ['tracked.txt'] = { 'one' } })
        session_file = vim.fn.tempname() .. '.vim'
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        vim.g.loaded_minifugit = nil
        vim.cmd.runtime('plugin/minifugit.lua')
        package.loaded.minifugit = nil
        find_status, restore_capture = helpers.capture_status_windows()
        minifugit =
            helpers.awaiting_reads(require('minifugit').setup({}), find_status)
    end)

    after_each(function()
        restore_capture()
        minifugit.reset()
        vim.cmd('silent! tabonly!')
        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('silent! %bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        vim.fn.delete(repo, 'rf')
        vim.fn.delete(session_file)
    end)

    it('drops the status window the session restored', function()
        restart()

        assert.are.same({}, restored_buffers())
        assert.are.equal(1, #vim.api.nvim_list_wins())
    end)

    it('opens status when a leftover holds its buffer name', function()
        -- Without SessionLoadPost (a lazily loaded plugin), leftovers survive
        -- the restore. Name one after each id the next status buffer may get.
        vim.api.nvim_clear_autocmds({ group = 'minifugit_session' })
        restart()
        local next_id = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_delete(next_id, { force = true })
        for id = next_id + 1, next_id + 10 do
            local leftover = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(leftover, ('Minifugit [%d]'):format(id))
        end
        assert.is_true(#restored_buffers() > 0)

        minifugit.status()

        local status = find_status()
        assert.is_not_nil(status)
        assert.are.equal('minifugit', vim.bo[status.buf.id].filetype)
        assert.are.same({}, restored_buffers())
    end)

    it('keeps a modified buffer that carries a status name', function()
        vim.cmd.edit('Minifugit [1]')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'user text' })
        local bufnr = vim.api.nvim_get_current_buf()

        vim.api.nvim_exec_autocmds('SessionLoadPost', {})

        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    end)
end)
