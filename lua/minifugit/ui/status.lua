---@class UIStatus
---@field _win number The window id
---@field _buf number The buffer id
---@field _lines MiniFugitLine[] The lines written on the buffer
---@field open_win function
---@field create_win function
---@field get_win function
---@field get_buf function
---@field get_line function
---@field set_lines function

local ui = require('minifugit.ui.utils')
local log = require('minifugit.log')
local highlight = require('minifugit.highlight')

---@type UIStatus
local ui_status = {
    _buf = -1,
    _win = -1,
    _lines = {},
    open_win = function() end,
    create_win = function() end,
    get_win = function() end,
    get_buf = function() end,
    get_line = function() end,
    set_lines = function() end,
}

---@return UIBufWin
local function create_win()
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd('botright ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()
    local buf = ui_status._buf

    if buf == -1 then
        buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(buf, 'Minifugit')
    end

    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)

    log.info(string.format('created status window win=%d buf=%d', win, buf))

    return {
        win = win,
        buf = buf,
    }
end

---@param lines (string|MiniFugitLine)[]
---@return MiniFugitLine[]
local function normalize_lines(lines)
    local normalized = {}

    for _, line in ipairs(lines) do
        if type(line) == 'string' then
            if line == '' then
                table.insert(normalized, highlight.plain_line(line))
            else
                for _, value in ipairs(vim.split(line, '\n', { plain = true })) do
                    table.insert(normalized, highlight.plain_line(value))
                end
            end
        else
            table.insert(
                normalized,
                highlight.line(line.text, line.highlights, line.data)
            )
        end
    end

    return normalized
end

---@param row integer
---@return MiniFugitLine?
function ui_status.get_line(row)
    return ui_status._lines[row]
end

---@return integer
function ui_status.get_win()
    return ui_status._win
end

---@return integer
function ui_status.get_buf()
    return ui_status._buf
end

---@return UIBufWin
function ui_status.open_win()
    if
        not vim.api.nvim_buf_is_valid(ui_status._buf)
        or not vim.api.nvim_win_is_valid(ui_status._win)
    then
        if ui_status._buf ~= -1 then
            ui.close_win()
        end

        local bufwin = create_win()

        ui_status._buf = bufwin.buf
        ui_status._win = bufwin.win
        ui_status._lines = {}

        return {
            buf = ui_status._buf,
            win = ui_status._win,
        }
    end

    log.info(
        string.format(
            'reusing status window win=%d buf=%d',
            ui_status._win,
            ui_status._buf
        )
    )
    vim.api.nvim_set_current_win(ui_status._win)

    return {
        buf = ui_status._buf,
        win = ui_status._win,
    }
end

---@param lines (string|MiniFugitLine)[] Array of lines to replace in the window
function ui_status.set_lines(lines)
    local b = ui_status._buf
    local normalized_lines = normalize_lines(lines)

    ui.set_lines(normalized_lines, b)
    highlight.apply(ui_status._buf, normalized_lines)
    ui_status._lines = normalized_lines
end

return ui_status
