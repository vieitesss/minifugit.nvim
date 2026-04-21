local utils = {}

---@param line string
---@return boolean
function utils.is_change(line)
    return line:match('^.. ')
end

---@param line string
---@return string
function utils.change_path(line)
    local path = line:sub(4)
    local renamed_to = path:match('^.* %-%> (.+)$')

    return renamed_to or path
end


return utils
