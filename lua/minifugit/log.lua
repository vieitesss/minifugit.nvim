local M = {}

local log_dir = vim.fn.stdpath('state') .. '/minifugit'
local log_file = log_dir .. '/minifugit.log'

local ensure_dir = function()
    vim.fn.mkdir(log_dir, 'p')
end

function M.open()
    vim.fn.execute('vsplit ' .. log_file)
end

function M.path()
    return log_file
end

---@param level string
---@param msg any
local write = function(level, msg)
    ensure_dir()

    local text = tostring(msg)
    text = text:gsub('\0', '\\0')

    local line = string.format(
        '[%s] [%s] %s',
        os.date('%Y-%m-%d %H:%M:%S'),
        level,
        text
    )

    local file = io.open(log_file, 'a')

    if file == nil then
        return
    end

    file:write(line .. '\n')
    file:close()
end

---@alias log_func function(string)

---@type log_func
function M.info(msg)
    write('INFO', msg)
end

---@type log_func
function M.debug(msg)
    write('DEBUG', msg)
end

---@type log_func
function M.error(msg)
    write('ERROR', msg)
end

return M
