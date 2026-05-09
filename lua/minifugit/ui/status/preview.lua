local Buffer = require('minifugit.ui.buffer')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local window = require('minifugit.ui.status.window')
local selection = require('minifugit.ui.status.selection')

local M = {}

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusEntryItem?
local function entry_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.entry_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusCommitItem?
local function commit_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.commit_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusEntryItem?
local function refresh_entry_item(self, state)
    local item = selection.current_entry_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.item_key ~= nil then
        item = entry_item_at_row(
            self,
            selection.row_for_item_key(self, state.item_key)
        )

        if item ~= nil then
            return item
        end
    end

    if state.entry_key ~= nil then
        return entry_item_at_row(
            self,
            selection.row_for_entry_key(self, state.entry_key)
        )
    end

    return nil
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusCommitItem?
local function refresh_commit_item(self, state)
    local item = selection.current_commit_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.commit_key ~= nil then
        return commit_item_at_row(
            self,
            selection.row_for_commit_key(self, state.commit_key)
        )
    end

    return nil
end

---@class MiniFugitDiffLine
---@field kind 'header'|'hunk'|'context'|'added'|'removed'
---@field old_number integer?
---@field new_number integer?
---@field text string

---@class MiniFugitDiffRenderOpts
---@field show_headers boolean?
---@field show_numbers boolean?

local DIFF_HEADER_PREFIXES = {
    'diff ',
    'index ',
    '--- ',
    '+++ ',
    'old mode ',
    'new mode ',
    'deleted file mode ',
    'new file mode ',
    'similarity index ',
    'dissimilarity index ',
    'rename from ',
    'rename to ',
    'copy from ',
    'copy to ',
    'Binary files ',
    'GIT binary patch',
}

---@param text string
---@return string
local function winbar_text(text)
    return text:gsub('%%', '%%%%')
end

---@param commit GitCommit
---@return string
local function commit_diff_title(commit)
    return winbar_text('commit: ' .. commit.hash .. ' ' .. commit.message)
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@return string
local function diff_title(entry, section)
    local prefix = section or 'diff'
    local path = entry.orig_path ~= nil
            and (entry.orig_path .. ' -> ' .. entry.path)
        or entry.path

    return winbar_text(prefix .. ': ' .. path)
end

---@param text string
---@return boolean
local function is_diff_header(text)
    for _, prefix in ipairs(DIFF_HEADER_PREFIXES) do
        if vim.startswith(text, prefix) then
            return true
        end
    end

    return false
end

---@param number integer?
---@param width integer
---@return string
local function format_number(number, width)
    if number == nil then
        return string.rep(' ', width)
    end

    return string.format('%' .. width .. 'd', number)
end

---@param line MiniFugitDiffLine
---@param width integer
---@param opts MiniFugitDiffRenderOpts
---@return string
local function format_diff_line(line, width, opts)
    if line.kind == 'header' or line.kind == 'hunk' then
        return line.text
    end

    if opts.show_numbers == false then
        return line.text
    end

    return string.format(
        '%s %s %s',
        format_number(line.old_number, width),
        format_number(line.new_number, width),
        line.text
    )
end

---@param lines MiniFugitDiffLine[]
---@return integer
local function diff_number_width(lines)
    local max_number = 0

    for _, line in ipairs(lines) do
        if line.old_number ~= nil then
            max_number = math.max(max_number, line.old_number)
        end

        if line.new_number ~= nil then
            max_number = math.max(max_number, line.new_number)
        end
    end

    return math.max(#tostring(max_number), 1)
end

---@param hunk_header string
---@return integer?, integer?
local function parse_hunk_header(hunk_header)
    local old_start, new_start =
        hunk_header:match('^@@ %-(%d+)[^ ]* %+(%d+)[^ ]* @@')

    if old_start == nil or new_start == nil then
        return nil, nil
    end

    return tonumber(old_start), tonumber(new_start)
end

---@param lines string[]
---@return MiniFugitDiffLine[]
local function parse_diff_lines(lines)
    local parsed = {}
    local old_number
    local new_number

    for _, text in ipairs(lines) do
        if text == '' then
            goto continue
        end

        if vim.startswith(text, '@@') then
            old_number, new_number = parse_hunk_header(text)
            table.insert(parsed, { kind = 'hunk', text = text })
        elseif is_diff_header(text) then
            table.insert(parsed, { kind = 'header', text = text })
        elseif vim.startswith(text, '+') then
            table.insert(parsed, {
                kind = 'added',
                old_number = nil,
                new_number = new_number,
                text = text,
            })

            if new_number ~= nil then
                new_number = new_number + 1
            end
        elseif vim.startswith(text, '-') then
            table.insert(parsed, {
                kind = 'removed',
                old_number = old_number,
                new_number = nil,
                text = text,
            })

            if old_number ~= nil then
                old_number = old_number + 1
            end
        else
            table.insert(parsed, {
                kind = 'context',
                old_number = old_number,
                new_number = new_number,
                text = text,
            })

            if old_number ~= nil then
                old_number = old_number + 1
            end

            if new_number ~= nil then
                new_number = new_number + 1
            end
        end

        ::continue::
    end

    return parsed
end

---@param lines string[]
---@param groups table<string, string>
---@param opts MiniFugitDiffRenderOpts
---@return MiniFugitRenderLine[]
local function diff_render_lines(lines, groups, opts)
    opts = opts or {}

    local parsed = parse_diff_lines(lines)
    local width = diff_number_width(parsed)
    local diff_lines = {}

    for _, diff_line in ipairs(parsed) do
        if diff_line.kind == 'header' and opts.show_headers == false then
            goto continue
        end

        local text = format_diff_line(diff_line, width, opts)
        local line = render.line(text)

        if diff_line.kind == 'added' then
            render.add_highlight(line, groups.diff_added, 0, #text)
        elseif diff_line.kind == 'removed' then
            render.add_highlight(line, groups.diff_removed, 0, #text)
        elseif diff_line.kind == 'header' then
            render.add_highlight(line, groups.diff_header, 0, #text)
        elseif diff_line.kind == 'hunk' then
            render.add_highlight(line, groups.diff_hunk_header, 0, #text)
        end

        table.insert(diff_lines, line)

        ::continue::
    end

    if #diff_lines == 0 then
        table.insert(diff_lines, render.line('(No diff content — only headers)'))
    end

    return diff_lines
end

---@param self GitStatusWindow
---@param delta integer
---@return boolean
function M.jump_hunk(self, delta)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local win = self.diff_win
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    local lines = vim.api.nvim_buf_get_lines(self.diff_buf.id, 0, -1, false)
    local start = delta > 0 and cursor + 1 or cursor - 1
    local stop = delta > 0 and #lines or 1

    for row = start, stop, delta do
        if vim.startswith(lines[row] or '', '@@') then
            vim.api.nvim_win_set_cursor(win, { row, 0 })
            return true
        end
    end

    common.notify_warn('No more hunks')
    return false
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_wrap(self)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    self.diff_wrap = not self.diff_wrap
    vim.wo[self.diff_win].wrap = self.diff_wrap
    return true
end

---@param self GitStatusWindow
---@param option 'numbers'|'headers'
---@return boolean
local function toggle_diff_render_option(self, option)
    if option == 'numbers' then
        self.diff_show_numbers = not self.diff_show_numbers
    else
        self.diff_show_headers = not self.diff_show_headers
    end

    local ok = M.refresh_current_entry(self) == true

    if ok and self.diff_win ~= nil and vim.api.nvim_win_is_valid(self.diff_win) then
        vim.api.nvim_set_current_win(self.diff_win)
    end

    return ok
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_numbers(self)
    return toggle_diff_render_option(self, 'numbers')
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_headers(self)
    return toggle_diff_render_option(self, 'headers')
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and common.is_valid_win(self.diff_win)
        and vim.api.nvim_win_get_buf(self.diff_win) == self.diff_buf.id
end

---@param self GitStatusWindow
---@param commit GitCommit
---@param opts? { force: boolean? }
---@return boolean
function M.open_commit_diff(self, commit, opts)
    opts = opts or {}

    local preview_key = 'commit:' .. commit.hash

    if
        not opts.force
        and M.has_open_diff(self)
        and self.diff_preview_key == preview_key
    then
        return true
    end

    local lines, err = git.show_commit(commit)
    local diff_lines

    if err ~= nil then
        common.notify_error(err, 'Cannot show commit diff')
        return false
    end

    if #lines == 0 then
        diff_lines = { render.line('No diff for commit ' .. commit.hash) }
    else
        diff_lines = diff_render_lines(lines, self.groups, {
            show_headers = self.diff_show_headers,
            show_numbers = self.diff_show_numbers,
        })
    end

    local buf = M.ensure_diff_buf(self)

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local target_win = window.find_target_win(self)
    local created_win = false

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
        created_win = true
    else
        vim.api.nvim_set_current_win(target_win)
    end

    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id
        and self.diff_win == target_win

    if not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_prev_winopts = window.capture_winopts(target_win)
        self.diff_created_win = created_win
    end

    vim.api.nvim_win_set_buf(target_win, buf.id)
    window.configure_diff_win(target_win)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = commit_diff_title(commit)
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@param self GitStatusWindow
function M.close_diff(self)
    local current_win = vim.api.nvim_get_current_win()
    local diff_win = current_win

    if
        not self.diff_buf
        or not self.diff_buf:is_valid()
        or vim.api.nvim_win_get_buf(diff_win) ~= self.diff_buf.id
    then
        if not common.is_valid_win(self.diff_win) then
            return
        end

        diff_win = self.diff_win

        if vim.api.nvim_win_get_buf(diff_win) ~= self.diff_buf.id then
            return
        end
    end

    if self.diff_created_win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(diff_win, true)
    elseif
        self.diff_prev_buf and vim.api.nvim_buf_is_valid(self.diff_prev_buf)
    then
        vim.api.nvim_win_set_buf(diff_win, self.diff_prev_buf)
        window.restore_winopts(diff_win, self.diff_prev_winopts)
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(diff_win, true)
    end

    self.diff_win = nil
    self.diff_prev_buf = nil
    self.diff_prev_winopts = nil
    self.diff_created_win = false
    self.diff_preview_key = nil

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end
end

---@param self GitStatusWindow
---@return Buffer
function M.ensure_diff_buf(self)
    if self.diff_buf and self.diff_buf:is_valid() then
        return self.diff_buf
    end

    self.diff_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Minifugit diff',
    })

    vim.bo[self.diff_buf.id].buftype = 'nofile'
    vim.bo[self.diff_buf.id].bufhidden = 'hide'
    vim.bo[self.diff_buf.id].swapfile = false

    vim.keymap.set('n', 'q', function()
        M.close_diff(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        M.jump_hunk(self, 1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to next git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        M.jump_hunk(self, -1)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Jump to previous git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'w', function()
        M.toggle_wrap(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview wrap',
        silent = true,
    })

    vim.keymap.set('n', 'l', function()
        M.toggle_numbers(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 'm', function()
        M.toggle_headers(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git diff preview metadata',
        silent = true,
    })

    vim.keymap.set('n', '?', function()
        self:toggle_help()
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return self.diff_buf
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean? }
---@return boolean
function M.open_diff(self, entry, section, opts)
    opts = opts or {}

    local preview_key =
        table.concat({ section or '', entry.orig_path or '', entry.path }, '\0')

    if
        not opts.force
        and M.has_open_diff(self)
        and self.diff_preview_key == preview_key
    then
        return true
    end

    local lines, err = git.diff(entry, section)
    local diff_lines

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    if #lines == 0 then
        diff_lines = { render.line('No diff for ' .. entry.path) }
    else
        diff_lines = diff_render_lines(lines, self.groups, {
            show_headers = self.diff_show_headers,
            show_numbers = self.diff_show_numbers,
        })
    end

    local buf = M.ensure_diff_buf(self)

    vim.bo[buf.id].modifiable = true
    buf:set_lines(render.text_lines(diff_lines))
    vim.bo[buf.id].modifiable = false
    render.apply(buf.id, diff_lines)

    local target_win = window.find_target_win(self)
    local created_win = false

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
        created_win = true
    else
        vim.api.nvim_set_current_win(target_win)
    end

    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id
        and self.diff_win == target_win

    if not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_prev_winopts = window.capture_winopts(target_win)
        self.diff_created_win = created_win
    end

    vim.api.nvim_win_set_buf(target_win, buf.id)
    window.configure_diff_win(target_win)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = diff_title(entry, section)
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function M.preview_current_entry(self, opts)
    opts = opts or {}

    local item = selection.current_entry_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No git status entry under cursor')
        end

        return false
    end

    return M.open_diff(self, item.entry, item.section, {
        force = opts.force,
    })
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
function M.refresh_current_entry(self, state)
    if not M.has_open_diff(self) then
        return
    end

    local preview_key = self.diff_preview_key or ''

    if vim.startswith(preview_key, 'commit:') then
        local item = refresh_commit_item(self, state)

        if item == nil then
            return
        end

        M.open_commit_diff(self, item.commit, {
            force = true,
        })
        return
    end

    local item = refresh_entry_item(self, state)

    if item == nil then
        return
    end

    M.open_diff(self, item.entry, item.section, {
        force = true,
    })
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function M.preview_current_commit(self, opts)
    opts = opts or {}

    local item = selection.current_commit_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No unpushed commit under cursor')
        end

        return false
    end

    return M.open_commit_diff(self, item.commit, {
        force = opts.force,
    })
end

return M
