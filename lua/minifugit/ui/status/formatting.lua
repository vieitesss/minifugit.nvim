local render = require('minifugit.ui.render')

local M = {}

---@param branch string
---@param groups table<string, string>
---@return MiniFugitRenderLine
function M.head_line(branch, groups)
    local prefix = 'HEAD: '
    local text = prefix .. branch
    local line = render.line(text)

    render.add_highlight(line, groups.head, 0, #prefix)
    render.add_highlight(line, 'Title', #prefix, #text)

    return line
end

---@param branch string
---@param groups table<string, string>
---@return MiniFugitRenderLine[]
function M.render(branch, groups)
    return { M.head_line(branch, groups) }
end

return M
