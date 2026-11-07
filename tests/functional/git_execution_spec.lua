---@diagnostic disable: undefined-field
local git = require('minifugit.git')
local helpers = dofile('tests/helpers.lua')
local log = require('minifugit.log')

describe('git command execution', function()
    ---@type string
    local repo
    ---@type string
    local original_cwd
    ---@type log_func
    local original_error
    ---@type log_func
    local original_info
    ---@type string[]
    local errors
    ---@type string[]
    local infos

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = select(1, helpers.create_repo({ ['tracked.txt'] = { 'one' } }))
        original_error = log.error
        original_info = log.info
        errors = {}
        infos = {}
        log.error = function(message)
            table.insert(errors, message)
        end
        log.info = function(message)
            table.insert(infos, message)
        end
    end)

    after_each(function()
        log.error = original_error
        log.info = original_info
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))

        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

    it('reads the same result synchronously and asynchronously', function()
        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'two' })
        helpers.write_file(vim.fs.joinpath(repo, 'new.txt'), { 'new' })

        local sync = git.run({ 'status', '--porcelain' }, { cwd = repo })
        local async_ok
        local async_output
        git.run_async(
            { 'status', '--porcelain' },
            { cwd = repo },
            function(ok, output)
                async_ok, async_output = ok, output
            end
        )

        assert.is_true(vim.wait(5000, function()
            return async_ok ~= nil
        end))
        assert.are.equal(0, sync.exit_code, sync.stderr)
        assert.are.equal('', sync.stderr)
        assert.are.equal(' M tracked.txt\n?? new.txt\n', sync.output)
        assert.is_true(async_ok)
        assert.are.equal(' M tracked.txt\n?? new.txt', async_output)
    end)

    it(
        'reports stderr to the asynchronous callback when the command fails',
        function()
            local args = { 'rev-parse', '--verify', 'missing-ref' }
            local sync = git.run(args, { cwd = repo })
            local async_ok
            local async_output
            git.run_async(args, { cwd = repo }, function(ok, output)
                async_ok, async_output = ok, output
            end)

            assert.is_true(vim.wait(5000, function()
                return async_ok ~= nil
            end))
            assert.are.equal(128, sync.exit_code)
            assert.are.equal('', sync.output)
            assert.is_true(#sync.stderr > 0)
            assert.is_false(async_ok)
            assert.are.equal(vim.trim(sync.stderr), async_output)
        end
    )

    it(
        'logs one info line per command and suppresses ignored errors',
        function()
            git.run({ 'status', '--porcelain' }, { cwd = repo })

            assert.are.same({}, errors)
            assert.are.same({ 'output=, exit_code=0, stderr=' }, infos)

            errors = {}
            infos = {}
            local failed = git.run(
                { 'rev-parse', '--verify', 'missing-ref' },
                { cwd = repo, ignore_error = true }
            )

            assert.are.same({}, errors)
            assert.are.equal(1, #infos)
            assert.are.equal(
                'output=, exit_code='
                    .. failed.exit_code
                    .. ', stderr='
                    .. failed.stderr,
                infos[1]
            )

            errors = {}
            infos = {}
            local async_ok
            git.run_async(
                { 'rev-parse', '--verify', 'missing-ref' },
                { cwd = repo },
                function(ok)
                    async_ok = ok
                end
            )

            assert.is_true(vim.wait(5000, function()
                return async_ok ~= nil
            end))
            assert.is_false(async_ok)
            assert.are.equal(1, #errors)
            assert.are.equal(
                'git command failed (128): '
                    .. vim.fn.exepath('git')
                    .. ' rev-parse --verify missing-ref\n'
                    .. failed.stderr,
                errors[1]
            )
            assert.are.equal(1, #infos)
            assert.is_truthy(infos[1]:find('exit_code=128', 1, true))
            assert.is_truthy(infos[1]:find(failed.stderr, 1, true))
        end
    )

    it(
        'fails push preflight immediately but finishes a push asynchronously',
        function()
            local remote = vim.fs.joinpath(repo, '.git', 'test-remote.git')
            helpers.run({ 'git', 'init', '--bare', remote }, repo)
            helpers.run({ 'git', 'remote', 'add', 'origin', remote }, repo)
            helpers.run({ 'git', 'push', '-u', 'origin', 'main' }, repo)

            local order = {}
            local preflight_ok
            local preflight_message
            git.push_async(function(ok, message)
                table.insert(order, 'callback')
                preflight_ok, preflight_message = ok, message
            end, repo)
            table.insert(order, 'returned')

            assert.are.same({ 'callback', 'returned' }, order)
            assert.is_false(preflight_ok)
            assert.are.equal('No unpushed commits to push', preflight_message)

            helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'two' })
            helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
            helpers.run({ 'git', 'commit', '-m', 'second commit' }, repo)

            order = {}
            local push_ok
            local push_message
            git.push_async(function(ok, message)
                table.insert(order, 'callback')
                push_ok, push_message = ok, message
            end, repo)
            table.insert(order, 'returned')

            assert.are.same({ 'returned' }, order)
            assert.is_true(vim.wait(10000, function()
                return push_ok ~= nil
            end))
            assert.are.same({ 'returned', 'callback' }, order)
            assert.is_true(push_ok, push_message)
            assert.are.equal(
                'second commit',
                vim.trim(helpers.run({
                    'git',
                    '--git-dir=' .. remote,
                    'log',
                    'main',
                    '-1',
                    '--pretty=%s',
                }, repo))
            )
        end
    )

    -- Windows does not allow control characters in file names.
    local unix_it = vim.fn.has('win32') == 1 and pending or it
    unix_it('keeps raw NUL and CRLF filename bytes when text is off', function()
        helpers.run({ 'git', 'config', 'core.autocrlf', 'false' }, repo)
        helpers.write_file(repo .. '/line\r\nbreak.txt', { 'new' })
        helpers.run({ 'git', 'add', '--', 'line\r\nbreak.txt' }, repo)

        local raw = git.run({ 'ls-files', '-z' }, { cwd = repo, text = false })
        local text = git.run({ 'ls-files', '-z' }, { cwd = repo })

        assert.are.equal(0, raw.exit_code, raw.stderr)
        assert.are.equal('line\r\nbreak.txt\0tracked.txt\0', raw.output)
        assert.are.equal('\0', raw.output:sub(-1))
        assert.are.equal(0, text.exit_code, text.stderr)
        assert.are.equal('line\nbreak.txt\0tracked.txt\0', text.output)
    end)
end)
