local common = require('minifugit.ui.status.common')

local M = {}

---@class GitStatusEntryItem
---@field entry GitStatusEntry
---@field section GitStatusSectionName?

---@class GitStatusCursorState
---@field row integer?
---@field item_key string?
---@field entry_key string?
---@field follow_entry boolean?

---@param data any
---@return GitStatusEntry?
function M.entry_from_data(data)
    if type(data) ~= 'table' then
        return nil
    end

    if type(data.entry) == 'table' then
        return data.entry
    end

    if type(data.path) == 'string' then
        return data
    end

    return nil
end

---@param data any
---@return GitStatusEntryItem?
function M.entry_item_from_data(data)
    local entry = M.entry_from_data(data)

    if entry == nil then
        return nil
    end

    return {
        entry = entry,
        section = data.section,
    }
end

---@param self GitStatusWindow
---@return MiniFugitRenderLine?
function M.current_line(self)
    if not self.buf or not self.buf:is_valid() then
        return nil
    end

    local win = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_get_buf(win) ~= self.buf.id then
        if not common.is_valid_win(self.win) then
            return nil
        end

        win = self.win
    end

    local row = vim.api.nvim_win_get_cursor(win)[1]

    return self.lines[row]
end

---@param self GitStatusWindow
---@return GitStatusEntryItem?
function M.current_entry_item(self)
    local line = M.current_line(self)

    if line == nil then
        return nil
    end

    return M.entry_item_from_data(line.data)
end

---@param self GitStatusWindow
---@return GitStatusEntry?
function M.current_entry(self)
    local item = M.current_entry_item(self)

    if item == nil then
        return nil
    end

    return item.entry
end

---@param self GitStatusWindow
---@param start_row integer
---@param end_row integer
---@return GitStatusEntryItem[]
function M.entry_items_in_range(self, start_row, end_row)
    local items = {}
    local first = math.min(start_row, end_row)
    local last = math.max(start_row, end_row)

    for row = first, last do
        local line = self.lines[row]

        if line ~= nil then
            local item = M.entry_item_from_data(line.data)

            if item ~= nil then
                table.insert(items, item)
            end
        end
    end

    return items
end

---@param self GitStatusWindow
---@param start_row integer
---@param end_row integer
---@return GitStatusEntry[]
function M.entries_in_range(self, start_row, end_row)
    local entries = {}

    for _, item in ipairs(M.entry_items_in_range(self, start_row, end_row)) do
        table.insert(entries, item.entry)
    end

    return entries
end

---@param self GitStatusWindow
---@return GitStatusEntry[]
function M.all_entries(self)
    return M.entries_in_range(self, 1, #self.lines)
end

---@param self GitStatusWindow
---@return integer?
function M.first_entry_row(self)
    for row, line in ipairs(self.lines) do
        if M.entry_from_data(line.data) ~= nil then
            return row
        end
    end

    return nil
end

---@param self GitStatusWindow
---@return GitStatusEntryItem[]
function M.selected_entry_items(self)
    local mode = vim.fn.mode()
    local start_row
    local end_row

    if mode == 'v' or mode == 'V' or mode == '\22' then
        start_row = vim.fn.line('v')
        end_row = vim.fn.line('.')
    else
        start_row = vim.fn.getpos("'<")[2]
        end_row = vim.fn.getpos("'>")[2]
    end

    return M.entry_items_in_range(self, start_row, end_row)
end

---@param item GitStatusEntryItem?
---@return string?
function M.entry_item_key(item)
    if item == nil then
        return nil
    end

    local entry_key = table.concat({
        item.entry.orig_path or '',
        item.entry.path,
    }, '\0')

    return table.concat({
        item.section or '',
        entry_key,
    }, '\0')
end

---@param item GitStatusEntryItem?
---@return string?
function M.entry_identity_key(item)
    if item == nil then
        return nil
    end

    return table.concat({
        item.entry.orig_path or '',
        item.entry.path,
    }, '\0')
end

---@param self GitStatusWindow
---@return GitStatusCursorState
function M.capture_cursor_state(self)
    local state = {
        row = nil,
        item_key = nil,
        entry_key = nil,
        follow_entry = true,
    }
    local item = M.current_entry_item(self)

    if self.win ~= nil and common.is_valid_win(self.win) then
        state.row = vim.api.nvim_win_get_cursor(self.win)[1]
    end

    state.item_key = M.entry_item_key(item)
    state.entry_key = M.entry_identity_key(item)

    return state
end

---@param self GitStatusWindow
---@param item_key string
---@return integer?
function M.row_for_item_key(self, item_key)
    for row, line in ipairs(self.lines) do
        if M.entry_item_key(M.entry_item_from_data(line.data)) == item_key then
            return row
        end
    end

    return nil
end

---@param self GitStatusWindow
---@param entry_key string
---@return integer?
function M.row_for_entry_key(self, entry_key)
    for row, line in ipairs(self.lines) do
        if
            M.entry_identity_key(M.entry_item_from_data(line.data)) == entry_key
        then
            return row
        end
    end

    return nil
end

---@param self GitStatusWindow
function M.move_to_first_entry(self)
    local row = M.first_entry_row(self)

    if row ~= nil and self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_win_set_cursor(self.win, { row, 0 })
    end
end

---@param self GitStatusWindow
---@param row integer
function M.set_cursor_row(self, row)
    if self.win == nil or not common.is_valid_win(self.win) then
        return
    end

    vim.api.nvim_win_set_cursor(
        self.win,
        { math.max(1, math.min(row, #self.lines)), 0 }
    )
end

---@param self GitStatusWindow
---@param row integer
function M.restore_cursor(self, row)
    M.set_cursor_row(self, row)

    if M.current_entry_item(self) == nil then
        M.move_to_first_entry(self)
    end
end

---@param self GitStatusWindow
---@param row integer
function M.restore_nearest_entry(self, row)
    local clamped = math.max(1, math.min(row, #self.lines))

    for current = clamped, 1, -1 do
        local line = self.lines[current]

        if M.entry_item_from_data(line and line.data) ~= nil then
            M.restore_cursor(self, current)
            return
        end
    end

    for current = clamped + 1, #self.lines do
        local line = self.lines[current]

        if M.entry_item_from_data(line and line.data) ~= nil then
            M.restore_cursor(self, current)
            return
        end
    end

    M.move_to_first_entry(self)
end

---@param self GitStatusWindow
---@param state? GitStatusCursorState
function M.restore_cursor_state(self, state)
    state = state or M.capture_cursor_state(self)

    if state.follow_entry == false and state.row ~= nil then
        M.set_cursor_row(self, state.row)
        return
    end

    local target_row = state.item_key ~= nil
            and M.row_for_item_key(self, state.item_key)
        or nil

    if target_row == nil and state.entry_key ~= nil then
        if state.follow_entry == false then
            state.entry_key = nil
        end
    end

    if target_row == nil and state.entry_key ~= nil then
        target_row = M.row_for_entry_key(self, state.entry_key)
    end

    if target_row ~= nil then
        M.restore_cursor(self, target_row)
    elseif state.row ~= nil then
        M.restore_cursor(self, state.row)
    else
        M.move_to_first_entry(self)
    end
end

return M
