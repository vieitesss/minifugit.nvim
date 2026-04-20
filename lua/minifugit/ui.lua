---@class UI
---@field _win number The window id
---@field _buf number The buffer id
---@field _buf_lines string[] The lines written on the buffer
---@field open_win function Opens a new window or enters one already created
---@field set_lines function Replaces the window contents, if created
---@field append_lines function Appends the given lines into the window, if created

local log = require('minifugit.log')
local namespace = vim.api.nvim_create_namespace('minifugit.ui')

---@class UILineHighlight
---@field group string
---@field start_col integer
---@field end_col integer

---@class UILine
---@field text string
---@field highlights UILineHighlight[]

---@type UI
local ui = {
    _win = -1,
    _buf = -1,
    _buf_lines = {},
    open_win = function() end,
    set_lines = function() end,
    append_lines = function() end,
}

local create_win = function()
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd('botright ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, true)

    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)

    ui._win = win
    ui._buf = buf
    ui._buf_lines = {}

    log.info(string.format('created status window win=%d buf=%d', win, buf))

    return win
end

---@param lines (string|UILine)[]
---@return UILine[]
local function normalize_lines(lines)
    local normalized = {}

    for _, line in ipairs(lines) do
        if type(line) == 'string' then
            if line == '' then
                table.insert(normalized, { text = line, highlights = {} })
            else
                for _, value in ipairs(vim.split(line, '\n', { plain = true })) do
                    table.insert(normalized, { text = value, highlights = {} })
                end
            end
        else
            table.insert(normalized, {
                text = line.text,
                highlights = line.highlights or {},
            })
        end
    end

    return normalized
end

---@return boolean
local function ensure_open_buffer()
    if
        not vim.api.nvim_buf_is_valid(ui._buf)
        or not vim.api.nvim_win_is_valid(ui._win)
    then
        log.error("imposible to append lines, there isn't a window opened")
        return false
    end

    return true
end

---@param lines (string|UILine)[] Array of lines to replace in the window
function ui.set_lines(lines)
    if not ensure_open_buffer() then
        return
    end

    local normalized_lines = normalize_lines(lines)

    vim.api.nvim_buf_clear_namespace(ui._buf, namespace, 0, -1)
    vim.api.nvim_buf_set_lines(
        ui._buf,
        0,
        -1,
        false,
        vim.tbl_map(function(line)
            return line.text
        end, normalized_lines)
    )

    ui._buf_lines = {}

    for index, line in ipairs(normalized_lines) do
        local line_number = index - 1

        for _, highlight in ipairs(line.highlights) do
            vim.api.nvim_buf_set_extmark(
                ui._buf,
                namespace,
                line_number,
                highlight.start_col,
                {
                    end_col = highlight.end_col,
                    hl_group = highlight.group,
                }
            )
        end

        table.insert(ui._buf_lines, line.text)
    end
end

---@param lines (string|UILine)[] Array of lines to append to the window
function ui.append_lines(lines)
    if not ensure_open_buffer() then
        return
    end

    local existing_lines = vim.api.nvim_buf_get_lines(ui._buf, 0, -1, false)
    local content = {}

    vim.list_extend(content, existing_lines)
    vim.list_extend(content, lines)

    ui.set_lines(content)
end

---@return number The window id
function ui.open_win()
    if
        not vim.api.nvim_buf_is_valid(ui._buf)
        or not vim.api.nvim_win_is_valid(ui._win)
    then
        return create_win()
    end

    log.info(
        string.format('reusing status window win=%d buf=%d', ui._win, ui._buf)
    )
    vim.api.nvim_set_current_win(ui._win)

    return ui._win
end

return ui
