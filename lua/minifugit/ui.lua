---@class UI
---@field _win number The window id
---@field _buf number The buffer id
---@field _lines MiniFugitLine[] The lines written on the buffer
---@field close_win function Closes the window and deletes the buffer
---@field get_win function Return the current window id
---@field get_line function Return line metadata by row
---@field open_win function Opens a new window or enters one already created
---@field set_lines function Replaces the window contents, if created
---@field ensure_open_window function Returns whether the buffer is valid or not
---@field focus_edit_target function Focus previous usable window or create one

---@alias UIBufWin {buf:integer, win:integer}

local log = require('minifugit.log')
local highlight = require('minifugit.highlight')

---@type UI
local ui = {
    _win = -1,
    _buf = -1,
    _lines = {},
    close_win = function() end,
    get_win = function() end,
    get_line = function() end,
    open_win = function() end,
    set_lines = function() end,
    ensure_open_window = function() end,
    focus_edit_target = function() end,
}

---@param win integer
---@param source_win integer
---@return boolean
local function is_usable_edit_target(win, source_win)
    if win == 0 or not vim.api.nvim_win_is_valid(win) or win == source_win then
        return false
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local config = vim.api.nvim_win_get_config(win)
    local buftype = vim.bo[buf].buftype
    local filetype = vim.bo[buf].filetype
    local ok, winfixbuf = pcall(function()
        return vim.wo[win].winfixbuf
    end)

    if config.relative ~= '' then
        return false
    end

    if vim.wo[win].previewwindow or vim.wo[win].winfixwidth or (ok and winfixbuf) then
        return false
    end

    if buf == vim.api.nvim_win_get_buf(source_win) then
        return false
    end

    if buftype == 'nofile' or buftype == 'help' or buftype == 'quickfix' or buftype == 'terminal' then
        return false
    end

    if filetype == 'gitcommit' or filetype == 'gitrebase' then
        return false
    end

    return true
end

---@param source_win integer
---@return integer?
local function pick_edit_target(source_win)
    local previous_win = vim.fn.win_getid(vim.fn.winnr('#'))

    if is_usable_edit_target(previous_win, source_win) then
        return previous_win
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
        if is_usable_edit_target(win, source_win) then
            return win
        end
    end
end

local create_win = function()
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd('botright ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, 'Minifugit')

    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)

    ui._win = win
    ui._buf = buf
    ui._lines = {}

    log.info(string.format('created status window win=%d buf=%d', win, buf))
end

---@return integer
function ui.get_win()
    return ui._win
end

---@param row integer
---@return MiniFugitLine?
function ui.get_line(row)
    return ui._lines[row]
end

function ui.close_win()
    if vim.api.nvim_win_is_valid(ui._win) then
        vim.api.nvim_win_close(ui._win, true)
    end
    if vim.api.nvim_buf_is_valid(ui._buf) then
        vim.api.nvim_buf_delete(ui._buf, { unload = true })
    end
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
            table.insert(normalized, highlight.line(line.text, line.highlights, line.data))
        end
    end

    return normalized
end

---@param buf? integer Optional buffer to check
---@param win? integer Optional window to check
---@return boolean
function ui.ensure_open_window(buf, win)
    local b = buf or ui._buf
    local w = win or ui._win
    if not vim.api.nvim_buf_is_valid(b) or not vim.api.nvim_win_is_valid(w) then
        log.error("imposible to append lines, there isn't a window opened")
        return false
    end

    return true
end

---@param source_win integer
function ui.focus_edit_target(source_win)
    local target_win = pick_edit_target(source_win)

    if target_win ~= nil then
        vim.api.nvim_set_current_win(target_win)
        return
    end

    vim.cmd('aboveleft vnew')
end

---@param lines (string|MiniFugitLine)[] Array of lines to replace in the window
function ui.set_lines(lines)
    if not ui.ensure_open_window() then
        return
    end

    local normalized_lines = normalize_lines(lines)

    vim.api.nvim_buf_set_lines(
        ui._buf,
        0,
        -1,
        false,
        vim.tbl_map(function(line)
            return line.text
        end, normalized_lines)
    )

    ui._lines = normalized_lines

    highlight.apply(ui._buf, normalized_lines)
end

---@return UIBufWin
function ui.open_win()
    if
        not vim.api.nvim_buf_is_valid(ui._buf)
        or not vim.api.nvim_win_is_valid(ui._win)
    then
        if ui._buf ~= -1 then
            ui.close_win()
        end

        create_win()

        return {
            buf = ui._buf,
            win = ui._win,
        }
    end

    log.info(
        string.format('reusing status window win=%d buf=%d', ui._win, ui._buf)
    )
    vim.api.nvim_set_current_win(ui._win)

    return {
        buf = ui._buf,
        win = ui._win,
    }
end

return ui
