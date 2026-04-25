---@class UIDiff
---@field _buf number
---@field update_window function

---@type UIDiff
local diff = {
    _buf = -1,
    update_window = function() end
}

function diff.update_window()

end

return diff
