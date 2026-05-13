---@class MiniFugitRenderSpan
---@field group string
---@field start_col integer
---@field end_col integer

---@class MiniFugitRenderLine
---@field text string
---@field highlights MiniFugitRenderSpan[]
---@field line_hl_group string?
---@field data any?

local M = {}

local namespace = vim.api.nvim_create_namespace('minifugit.ui.render')

---@param text string
---@param data any?
---@return MiniFugitRenderLine
function M.line(text, data)
    return {
        text = text,
        highlights = {},
        data = data,
    }
end

---@param line MiniFugitRenderLine
---@param group string?
---@param start_col integer
---@param end_col integer?
function M.add_highlight(line, group, start_col, end_col)
    if not group then
        return
    end

    table.insert(line.highlights, {
        group = group,
        start_col = start_col,
        end_col = end_col or (start_col + 1),
    })
end

---@param lines MiniFugitRenderLine[]
---@return string[]
function M.text_lines(lines)
    return vim.tbl_map(function(line)
        return line.text
    end, lines)
end

---@param buf integer
---@param lines MiniFugitRenderLine[]
function M.apply(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

    for index, line in ipairs(lines) do
        if line.line_hl_group then
            vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, {
                line_hl_group = line.line_hl_group,
                priority = 200,
            })
        end

        for _, range in ipairs(line.highlights) do
            vim.api.nvim_buf_set_extmark(
                buf,
                namespace,
                index - 1,
                range.start_col,
                {
                    end_col = range.end_col,
                    hl_group = range.group,
                    hl_mode = 'combine',
                    priority = 200,
                }
            )
        end
    end
end

return M
