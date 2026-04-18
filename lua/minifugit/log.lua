local M = {}

local log_dir = vim.fn.stdpath('state') .. '/minifugit'
local log_file = log_dir .. '/minifugit.log'

local function ensure_dir()
    vim.fn.mkdir(log_dir, 'p')
end

function M.path()
    return log_file
end

---@param level string
---@param msg any
local write = function(level, msg)
    ensure_dir()

    local line = string.format(
        '[%s] [%s] %s',
        os.date('%Y-%m-%d %H:%M:%S'),
        level,
        tostring(msg)
    )

    vim.fn.writefile({ line }, log_file, 'a')
end

---@alias log_func function(string)

---@type log_func
function M.info(msg) write('INFO', msg) end

---@type log_func
function M.error(msg) write('ERROR', msg) end

return M
