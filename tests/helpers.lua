---@class MinifugitTestHelpers
---@field assert_has_line_containing fun(lines: string[], expected: string)
---@field run fun(args: string[], cwd: string): string
---@field write_file fun(path: string, lines: string[])
---@field create_repo fun(files: table<string, string[]>): string, string
---@field clone_repo_with_changed_file fun(repo: string, path: string, lines: string[]): string
---@field change_to_other_repo fun(repo: string): string
---@field capture_status_windows fun(): fun(): GitStatusWindow?, fun()
---@field snapshot_editor_state fun(): fun()
---@field settle_callbacks fun()
---@field row_containing fun(buf: integer, text: string): integer
---@field diff_win_named fun(name: string): integer, integer
---@field reload_minifugit fun()

local git_env = {
    GIT_CONFIG_GLOBAL = vim.uv.os_uname().sysname == 'Windows_NT' and 'NUL'
        or '/dev/null',
    GIT_CONFIG_NOSYSTEM = '1',
    GIT_TERMINAL_PROMPT = '0',
}

---@type MinifugitTestHelpers
local M = {
    ---@param lines string[]
    ---@param expected string
    assert_has_line_containing = function(lines, expected)
        for _, line in ipairs(lines) do
            if line:find(expected, 1, true) ~= nil then
                return
            end
        end

        assert.fail('Expected line containing not found: ' .. expected)
    end,

    ---@param args string[]
    ---@param cwd string
    ---@return string
    run = function(args, cwd)
        local result = vim.system(args, {
            text = true,
            cwd = cwd,
            env = git_env,
        }):wait()
        assert.are.equal(0, result.code, result.stderr)
        return result.stdout or ''
    end,

    ---@param path string
    ---@param lines string[]
    write_file = function(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        vim.fn.writefile(lines, path)
    end,
}

---Create a temporary repository with a base commit containing the given files.
---@param files table<string, string[]> Relative paths and their contents.
---@return string repo The caller owns cleanup and cwd changes.
---@return string base Full hash of the initial commit.
function M.create_repo(files)
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')
    M.run({ 'git', 'init', '-b', 'main' }, repo)
    M.run({ 'git', 'config', 'user.name', 'Minifugit Test' }, repo)
    M.run({ 'git', 'config', 'user.email', 'test@example.test' }, repo)
    for path, contents in pairs(files) do
        M.write_file(repo .. '/' .. path, contents)
    end
    M.run({ 'git', 'add', '.' }, repo)
    M.run({ 'git', 'commit', '-m', 'base' }, repo)
    return repo, vim.trim(M.run({ 'git', 'rev-parse', 'HEAD' }, repo))
end

---@param repo string
---@param path string Relative path in the cloned repository.
---@param lines string[]
---@return string Temporary clone; the caller owns cleanup and cwd changes.
function M.clone_repo_with_changed_file(repo, path, lines)
    local clone = vim.fn.tempname()
    M.run({ 'git', 'clone', '--local', repo, clone }, repo)
    M.write_file(vim.fs.joinpath(clone, path), lines)
    return clone
end

---Clone `repo` with a changed tracked file and switch the editor to the clone.
---@param repo string
---@return string Temporary clone; the caller owns cleanup and the cwd restore.
function M.change_to_other_repo(repo)
    local clone =
        M.clone_repo_with_changed_file(repo, 'tracked.txt', { 'changed in B' })
    vim.cmd.cd(vim.fn.fnameescape(clone))
    return clone
end

---Snapshot window, buffer, and tab identities.
---Return an assertion that none have changed.
---@return fun()
function M.snapshot_editor_state()
    local wins = vim.api.nvim_list_wins()
    local bufs = vim.api.nvim_list_bufs()
    local tabs = vim.api.nvim_list_tabpages()

    return function()
        assert.are.same(wins, vim.api.nvim_list_wins())
        assert.are.same(bufs, vim.api.nvim_list_bufs())
        assert.are.same(tabs, vim.api.nvim_list_tabpages())
    end
end

---Capture instances for existing UI specs that exercise window methods.
---The caller must restore the constructor after each test.
---@return fun(): GitStatusWindow?
---@return fun()
function M.capture_status_windows()
    local StatusWindow = require('minifugit.ui.status')
    local original_new = StatusWindow.new
    local instances = {}

    StatusWindow.new = function(...)
        local instance = original_new(...)
        instances[instance.buf.id] = instance
        return instance
    end

    return function()
        local current = instances[vim.api.nvim_get_current_buf()]
        if current ~= nil then
            return current
        end

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local instance = instances[vim.api.nvim_win_get_buf(win)]
            if instance ~= nil then
                return instance
            end
        end

        return nil
    end, function()
        StatusWindow.new = original_new
    end
end

---Wait until the callbacks scheduled before this call have run.
function M.settle_callbacks()
    local settled = false
    vim.schedule(function()
        settled = true
    end)
    assert.is_true(vim.wait(1000, function()
        return settled
    end))
end

---@param buf integer
---@param text string
---@return integer
function M.row_containing(buf, text)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(text, 1, true) ~= nil then
            return row
        end
    end

    error('Expected row containing not found: ' .. text)
end

---@param name string Diff buffer name without the `[n/m]` suffix.
---@return integer win
---@return integer buf
function M.diff_win_named(name)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(win).relative == '' then
            local buf = vim.api.nvim_win_get_buf(win)
            local buf_name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))

            if buf_name:match('^(.-) %[%d+%]$') == name then
                return win, buf
            end
        end
    end

    error('Expected visible diff buffer: ' .. name)
end

---Drop loaded minifugit modules so the next require reloads the plugin.
function M.reload_minifugit()
    local names = {}

    for name in pairs(package.loaded) do
        if name == 'minifugit' or name:match('^minifugit%.') then
            table.insert(names, name)
        end
    end

    for _, name in ipairs(names) do
        package.loaded[name] = nil
    end
end

return M
