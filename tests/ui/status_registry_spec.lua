---@diagnostic disable: undefined-field
local helpers = dofile('tests/helpers.lua')

local StatusRegistry = require('minifugit.ui.status.registry')

describe('minifugit status registry', function()
    local original_cwd
    local repo
    local root
    local minifugit
    ---@type table<GitStatusWindow, boolean>
    local instances

    ---@param open_in_tab boolean
    ---@return MinifugitOptions
    local function status_options(open_in_tab)
        local options = vim.deepcopy(minifugit.options)
        options.status.open_in_tab = open_in_tab

        return options
    end

    ---@param open_in_tab boolean
    ---@param on_close fun()?
    ---@return MinifugitStatusRequest
    local function request(open_in_tab, on_close)
        return {
            root = root,
            options = status_options(open_in_tab),
            on_close = on_close,
        }
    end

    ---@param registry MinifugitStatusRegistry
    ---@param open_in_tab boolean
    ---@param on_close fun()?
    ---@return GitStatusWindow
    local function open(registry, open_in_tab, on_close)
        local instance = registry:open(request(open_in_tab, on_close))
        instances[instance] = true

        return instance
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = helpers.create_repo({ ['tracked.txt'] = { 'one' } })
        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        package.loaded.minifugit = nil
        minifugit = require('minifugit').setup({ status = { width = 0.5 } })
        root = require('minifugit.git').root(repo)
        instances = {}
    end)

    after_each(function()
        for instance in pairs(instances) do
            pcall(function()
                instance:destroy()
            end)
        end

        vim.cmd('silent! tabonly!')
        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('%bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))
        vim.fn.delete(repo, 'rf')
    end)

    it('keeps one instance map per registry object', function()
        local first = StatusRegistry.new()
        local second = StatusRegistry.new()

        local instance_a = open(first, false)
        local instance_b = open(second, false)

        assert.are_not.equal(instance_a, instance_b)
        assert.is_true(vim.api.nvim_buf_is_valid(instance_a.buf.id))
        assert.is_true(vim.api.nvim_buf_is_valid(instance_b.buf.id))
        local buf_a = instance_a.buf.id

        first:reset()

        assert.is_false(vim.api.nvim_buf_is_valid(buf_a))
        assert.is_true(vim.api.nvim_buf_is_valid(instance_b.buf.id))
    end)

    it('keeps another tab instance when the current tab resets', function()
        local registry = StatusRegistry.new()
        local first_tab = vim.api.nvim_get_current_tabpage()
        local instance_a = open(registry, false)
        local buf_a = instance_a.buf.id

        vim.cmd.tabnew()
        local instance_b = open(registry, false)
        local buf_b = instance_b.buf.id

        registry:reset()

        assert.is_false(vim.api.nvim_buf_is_valid(buf_b))
        assert.is_true(vim.api.nvim_buf_is_valid(buf_a))
        assert.is_true(#vim.fn.win_findbuf(buf_a) > 0)

        vim.api.nvim_set_current_tabpage(first_tab)
        assert.are.equal(instance_a, open(registry, false))
    end)

    it('runs a request on_close callback once', function()
        local registry = StatusRegistry.new()
        local calls = 0
        local instance = open(registry, false, function()
            calls = calls + 1
        end)
        local bufnr = instance.buf.id

        registry:reset()
        helpers.settle_callbacks()

        assert.are.equal(1, calls)
        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))

        registry:reset()
        helpers.settle_callbacks()

        assert.are.equal(1, calls)
    end)

    it('keeps an instance registered when destroy fails', function()
        local registry = StatusRegistry.new()
        local instance = open(registry, false)
        local bufnr = instance.buf.id
        local destroy = instance.destroy
        instance.destroy = function()
            return false
        end

        registry:reset()

        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.are.equal(instance, open(registry, false))

        instance.destroy = destroy
        registry:reset()

        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    end)
end)
