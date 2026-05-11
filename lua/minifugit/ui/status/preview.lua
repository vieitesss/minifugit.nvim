local Buffer = require('minifugit.ui.buffer')
local render = require('minifugit.ui.render')
local git = require('minifugit.git')
local common = require('minifugit.ui.status.common')
local window = require('minifugit.ui.status.window')
local selection = require('minifugit.ui.status.selection')

local M = {}

local SPLIT_DIFF_NAMESPACE = vim.api.nvim_create_namespace(
    'MiniFugitSplitDiff'
)

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
---@field raw_row integer
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

local DIFF_HEADER_EXACT = {
    '---',
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

---@param self GitStatusWindow
---@return 'stacked'|'split'
local function resolved_layout(self)
    local layout = self.diff_layout_override or self.diff_layout

    if layout == 'auto' then
        return vim.o.columns >= self.options.preview.diff_auto_threshold
                and 'split'
            or 'stacked'
    end

    return layout
end

---@param self GitStatusWindow
---@return boolean
local function has_open_split_diff(self)
    return self.diff_left_buf ~= nil
        and self.diff_left_buf:is_valid()
        and self.diff_right_buf ~= nil
        and self.diff_right_buf:is_valid()
        and common.is_valid_win(self.diff_left_win)
        and common.is_valid_win(self.diff_right_win)
        and vim.api.nvim_win_get_buf(self.diff_left_win) == self.diff_left_buf.id
        and vim.api.nvim_win_get_buf(self.diff_right_win)
            == self.diff_right_buf.id
end

---@param self GitStatusWindow
---@return boolean
local function has_any_split_diff(self)
    local has_left = self.diff_left_buf ~= nil
        and self.diff_left_buf:is_valid()
        and common.is_valid_win(self.diff_left_win)
        and vim.api.nvim_win_get_buf(self.diff_left_win) == self.diff_left_buf.id
    local has_right = self.diff_right_buf ~= nil
        and self.diff_right_buf:is_valid()
        and common.is_valid_win(self.diff_right_win)
        and vim.api.nvim_win_get_buf(self.diff_right_win)
            == self.diff_right_buf.id

    return has_left or has_right
end

---@param win number?
local function diffoff(win)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('diffoff')
        end)
    end
end

---@param self GitStatusWindow
---@param buf_name string
---@param existing Buffer?
---@return Buffer
local function ensure_split_buf(self, buf_name, existing)
    if existing ~= nil and existing:is_valid() then
        return existing
    end

    local buf = Buffer.new({
        listed = false,
        scratch = true,
        name = buf_name,
    })

    vim.bo[buf.id].buftype = 'nofile'
    vim.bo[buf.id].bufhidden = 'hide'
    vim.bo[buf.id].swapfile = false

    vim.keymap.set('n', 'q', function()
        M.close_diff(self)
    end, {
        buffer = buf.id,
        desc = 'Close git diff preview',
        silent = true,
    })

    vim.keymap.set('n', 'w', function()
        M.toggle_wrap(self)
    end, {
        buffer = buf.id,
        desc = 'Toggle git diff preview wrap',
        silent = true,
    })

    vim.keymap.set('n', ']h', function()
        vim.cmd('normal! ]c')
    end, {
        buffer = buf.id,
        desc = 'Jump to next git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', '[h', function()
        vim.cmd('normal! [c')
    end, {
        buffer = buf.id,
        desc = 'Jump to previous git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'l', function()
        for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
            if common.is_valid_win(win) then
                vim.wo[win].number = not vim.wo[win].number
            end
        end
    end, {
        buffer = buf.id,
        desc = 'Toggle git diff preview line numbers',
        silent = true,
    })

    vim.keymap.set('n', 't', function()
        M.toggle_layout(self)
    end, {
        buffer = buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
        silent = true,
    })

    vim.keymap.set('n', '?', function()
        self:toggle_help()
    end, {
        buffer = buf.id,
        desc = 'Toggle git mappings help',
        silent = true,
    })

    return buf
end

---@param buf Buffer
---@param lines string[]
local function set_plain_lines(buf, lines)
    vim.bo[buf.id].modifiable = true
    vim.api.nvim_buf_set_lines(buf.id, 0, -1, false, lines)
    vim.bo[buf.id].modifiable = false
end

---@param win number?
---@param width integer
local function set_win_width(win, width)
    if common.is_valid_win(win) then
        pcall(vim.api.nvim_win_set_width, win, width)
    end
end

---@param self GitStatusWindow
local function resize_split_preview_windows(self)
    local width = math.max(1, math.floor(vim.o.columns / 3))

    set_win_width(self.win, width)
    set_win_width(self.diff_left_win, width)
    set_win_width(self.diff_right_win, width)
end

---@param text string
---@return boolean
local function is_diff_header(text)
    for _, prefix in ipairs(DIFF_HEADER_PREFIXES) do
        if vim.startswith(text, prefix) then
            return true
        end
    end

    for _, exact in ipairs(DIFF_HEADER_EXACT) do
        if text == exact then
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

    for raw_row, text in ipairs(lines) do
        if text == '' then
            goto continue
        end

        if vim.startswith(text, '@@') then
            old_number, new_number = parse_hunk_header(text)
            table.insert(
                parsed,
                { kind = 'hunk', raw_row = raw_row, text = text }
            )
        elseif is_diff_header(text) then
            table.insert(
                parsed,
                { kind = 'header', raw_row = raw_row, text = text }
            )
        elseif vim.startswith(text, '+') then
            table.insert(parsed, {
                kind = 'added',
                old_number = nil,
                new_number = new_number,
                raw_row = raw_row,
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
                raw_row = raw_row,
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
                raw_row = raw_row,
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
---@return integer[]
local function diff_render_lines(lines, groups, opts)
    opts = opts or {}

    local parsed = parse_diff_lines(lines)
    local width = diff_number_width(parsed)
    local diff_lines = {}
    local raw_rows = {}

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
        table.insert(raw_rows, diff_line.raw_row)

        ::continue::
    end

    if #diff_lines == 0 then
        table.insert(
            diff_lines,
            render.line('(No diff content — only headers)')
        )
    end

    return diff_lines, raw_rows
end

---@param buf Buffer
---@param row integer?
---@param group string
---@param marker string
local function mark_split_change(buf, row, group, marker)
    if row == nil or row < 1 then
        return
    end

    pcall(
        vim.api.nvim_buf_set_extmark,
        buf.id,
        SPLIT_DIFF_NAMESPACE,
        row - 1,
        0,
        {
            line_hl_group = group,
            sign_text = marker,
            sign_hl_group = group,
            priority = 200,
        }
    )
end

---@param left_buf Buffer
---@param right_buf Buffer
---@param diff_lines string[]
---@param groups table<string, string>
local function mark_split_changes(left_buf, right_buf, diff_lines, groups)
    vim.api.nvim_buf_clear_namespace(left_buf.id, SPLIT_DIFF_NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(right_buf.id, SPLIT_DIFF_NAMESPACE, 0, -1)

    for _, line in ipairs(parse_diff_lines(diff_lines)) do
        if line.kind == 'added' then
            mark_split_change(
                right_buf,
                line.new_number,
                groups.diff_added,
                '+'
            )
        elseif line.kind == 'removed' then
            mark_split_change(
                left_buf,
                line.old_number,
                groups.diff_removed,
                '-'
            )
        end
    end
end

---@param self GitStatusWindow
---@return string[]?
local function current_hunk_patch(self)
    if not M.has_open_diff(self) or self.diff_raw_lines == nil then
        common.notify_warn('Diff preview is not open')
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(self.diff_win)[1]
    local raw_row = self.diff_raw_rows and self.diff_raw_rows[cursor]

    if raw_row == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    local lines = self.diff_raw_lines
    local hunk_start

    for row = raw_row, 1, -1 do
        if vim.startswith(lines[row] or '', '@@') then
            hunk_start = row
            break
        end

        if vim.startswith(lines[row] or '', 'diff ') then
            break
        end
    end

    if hunk_start == nil then
        common.notify_warn('No hunk under cursor')
        return nil
    end

    local file_start = hunk_start

    while
        file_start > 1 and not vim.startswith(lines[file_start] or '', 'diff ')
    do
        file_start = file_start - 1
    end

    local header_stop = hunk_start - 1

    for row = file_start, hunk_start - 1 do
        if vim.startswith(lines[row] or '', '@@') then
            header_stop = row - 1
            break
        end
    end

    local hunk_stop = #lines

    for row = hunk_start + 1, #lines do
        local line = lines[row] or ''

        if vim.startswith(line, '@@') or vim.startswith(line, 'diff ') then
            hunk_stop = row - 1
            break
        end
    end

    local patch = {}

    for row = file_start, header_stop do
        table.insert(patch, lines[row])
    end

    for row = hunk_start, hunk_stop do
        table.insert(patch, lines[row])
    end

    return patch
end

---@param self GitStatusWindow
---@param kind 'stage'|'unstage'|'discard'
---@return boolean
local function apply_current_hunk(self, kind)
    local section = self.diff_section

    if kind == 'stage' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to stage')
        return false
    end

    if kind == 'unstage' and section ~= 'staged' then
        common.notify_warn('No staged hunk to unstage')
        return false
    end

    if kind == 'discard' and section ~= 'unstaged' then
        common.notify_warn('No unstaged hunk to discard')
        return false
    end

    local patch = current_hunk_patch(self)

    if patch == nil then
        return false
    end

    if
        kind == 'discard'
        and vim.fn.confirm('Discard current hunk?', '&Discard\n&Cancel', 2)
            ~= 1
    then
        return false
    end

    local cursor_state = selection.capture_cursor_state(self)
    local ok, err = git.apply_hunk(patch, kind)

    if not ok then
        common.notify_error(err, 'Git hunk action failed')
        return false
    end

    self:refresh(cursor_state)

    if M.has_open_diff(self) then
        vim.api.nvim_set_current_win(self.diff_win)
    end

    return true
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

    if common.is_valid_win(self.diff_win) then
        vim.wo[self.diff_win].wrap = self.diff_wrap
    end

    if common.is_valid_win(self.diff_left_win) then
        vim.wo[self.diff_left_win].wrap = self.diff_wrap
    end

    if common.is_valid_win(self.diff_right_win) then
        vim.wo[self.diff_right_win].wrap = self.diff_wrap
    end

    return true
end

---@param self GitStatusWindow
---@param layout 'stacked'|'split'
---@return boolean
function M.set_layout(self, layout)
    self.diff_layout_override = layout

    local ok = M.refresh_current_entry(self) == true

    if ok and self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return ok
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_layout(self)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local current = resolved_layout(self)
    return M.set_layout(self, current == 'split' and 'stacked' or 'split')
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

    if
        ok
        and self.diff_win ~= nil
        and vim.api.nvim_win_is_valid(self.diff_win)
    then
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
    return (
        self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and common.is_valid_win(self.diff_win)
        and vim.api.nvim_win_get_buf(self.diff_win) == self.diff_buf.id
    ) or has_any_split_diff(self)
end

---@param self GitStatusWindow
---@param diff_lines MiniFugitRenderLine[]
---@param preview_key string
---@param title string
---@return boolean
local function show_diff_lines(self, diff_lines, preview_key, title)
    if has_any_split_diff(self) then
        M.close_diff(self)
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
    vim.wo[target_win].winbar = title
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

---@param self GitStatusWindow
---@param split_diff GitSplitDiff
---@param diff_lines string[]
---@param preview_key string
---@param title string
---@return boolean
local function show_split_diff(self, split_diff, diff_lines, preview_key, title)
    if (M.has_open_diff(self) or has_any_split_diff(self))
        and not has_open_split_diff(self)
    then
        M.close_diff(self)
    end

    local left_buf = ensure_split_buf(
        self,
        'Minifugit diff left',
        self.diff_left_buf
    )
    local right_buf = ensure_split_buf(
        self,
        'Minifugit diff right',
        self.diff_right_buf
    )

    self.diff_left_buf = left_buf
    self.diff_right_buf = right_buf
    set_plain_lines(left_buf, split_diff.left.lines)
    set_plain_lines(right_buf, split_diff.right.lines)
    mark_split_changes(left_buf, right_buf, diff_lines, self.groups)

    if split_diff.filetype ~= '' then
        vim.bo[left_buf.id].filetype = split_diff.filetype
        vim.bo[right_buf.id].filetype = split_diff.filetype
    end

    local target_win = window.find_target_win(self)
    local left_created = false

    if target_win == nil then
        vim.cmd('leftabove vsplit')
        target_win = vim.api.nvim_get_current_win()
        self.target_win = target_win
        left_created = true
    else
        vim.api.nvim_set_current_win(target_win)
    end

    local was_left_preview = target_win == self.diff_left_win
        and vim.api.nvim_win_get_buf(target_win) == left_buf.id

    if not was_left_preview then
        self.diff_left_prev_buf = vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = window.capture_winopts(target_win)
        self.diff_left_created_win = left_created
    end

    vim.api.nvim_win_set_buf(target_win, left_buf.id)
    window.configure_split_diff_win(target_win)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = winbar_text(
        title .. ' [1/2] ' .. split_diff.left.title
    )
    self.diff_left_win = target_win

    local right_win = self.diff_right_win
    local right_created = false

    if not common.is_valid_win(right_win) then
        vim.cmd('rightbelow vsplit')
        right_win = vim.api.nvim_get_current_win()
        right_created = true
    else
        vim.api.nvim_set_current_win(right_win)
    end

    local was_right_preview = vim.api.nvim_win_get_buf(right_win) == right_buf.id

    if not was_right_preview then
        self.diff_right_prev_buf = vim.api.nvim_win_get_buf(right_win)
        self.diff_right_prev_winopts = window.capture_winopts(right_win)
        self.diff_right_created_win = right_created
    end

    vim.api.nvim_win_set_buf(right_win, right_buf.id)
    window.configure_split_diff_win(right_win)
    vim.wo[right_win].wrap = self.diff_wrap
    vim.wo[right_win].winbar = winbar_text(
        title .. ' [2/2] ' .. split_diff.right.title
    )
    self.diff_right_win = right_win
    resize_split_preview_windows(self)

    diffoff(self.diff_left_win)
    diffoff(self.diff_right_win)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_right_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffupdate')
        vim.cmd('syncbind')
    end)

    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
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

    self.diff_raw_lines = nil
    self.diff_raw_rows = nil
    self.diff_section = nil

    return show_diff_lines(
        self,
        diff_lines,
        preview_key,
        commit_diff_title(commit)
    )
end

---@param self GitStatusWindow
function M.close_diff(self)
    local closed = false

    if has_any_split_diff(self) then
        diffoff(self.diff_left_win)
        diffoff(self.diff_right_win)

        local wins = {
            {
                win = self.diff_right_win,
                created = self.diff_right_created_win,
                prev_buf = self.diff_right_prev_buf,
                prev_winopts = self.diff_right_prev_winopts,
            },
            {
                win = self.diff_left_win,
                created = self.diff_left_created_win,
                prev_buf = self.diff_left_prev_buf,
                prev_winopts = self.diff_left_prev_winopts,
            },
        }

        for _, item in ipairs(wins) do
            if common.is_valid_win(item.win) then
                if item.created and #vim.api.nvim_tabpage_list_wins(0) > 1 then
                    vim.api.nvim_win_close(item.win, true)
                elseif item.prev_buf and vim.api.nvim_buf_is_valid(item.prev_buf) then
                    vim.api.nvim_win_set_buf(item.win, item.prev_buf)
                    window.restore_winopts(item.win, item.prev_winopts)
                elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
                    vim.api.nvim_win_close(item.win, true)
                end
            end
        end

        self.diff_left_win = nil
        self.diff_right_win = nil
        self.diff_left_prev_buf = nil
        self.diff_right_prev_buf = nil
        self.diff_left_prev_winopts = nil
        self.diff_right_prev_winopts = nil
        self.diff_left_created_win = false
        self.diff_right_created_win = false
        closed = true
    end

    if
        self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and common.is_valid_win(self.diff_win)
        and vim.api.nvim_win_get_buf(self.diff_win) == self.diff_buf.id
    then
        local diff_win = self.diff_win

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

        closed = true
    end

    if not closed then
        return
    end

    self.diff_win = nil
    self.diff_prev_buf = nil
    self.diff_prev_winopts = nil
    self.diff_created_win = false
    self.diff_preview_key = nil
    self.diff_raw_lines = nil
    self.diff_raw_rows = nil
    self.diff_section = nil

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

    vim.keymap.set('n', 's', function()
        M.stage_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Stage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'u', function()
        M.unstage_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Unstage current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 'd', function()
        M.discard_current_hunk(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Discard current git diff hunk',
        silent = true,
    })

    vim.keymap.set('n', 't', function()
        M.toggle_layout(self)
    end, {
        buffer = self.diff_buf.id,
        desc = 'Toggle stacked/split git diff preview layout',
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

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    if resolved_layout(self) == 'split' then
        local split_diff, split_err = git.split_diff(entry, section)

        if split_diff ~= nil then
            return show_split_diff(
                self,
                split_diff,
                lines,
                preview_key,
                diff_title(entry, section)
            )
        end

        if split_err ~= nil then
            common.notify_warn(split_err .. '; showing stacked diff')
        end
    end

    local diff_lines
    local raw_rows

    if #lines == 0 then
        diff_lines = { render.line('No diff for ' .. entry.path) }
    else
        diff_lines, raw_rows = diff_render_lines(lines, self.groups, {
            show_headers = self.diff_show_headers,
            show_numbers = self.diff_show_numbers,
        })
    end

    self.diff_raw_lines = lines
    self.diff_raw_rows = raw_rows
    self.diff_section = section

    return show_diff_lines(
        self,
        diff_lines,
        preview_key,
        diff_title(entry, section)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.stage_current_hunk(self)
    return apply_current_hunk(self, 'stage')
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_current_hunk(self)
    return apply_current_hunk(self, 'unstage')
end

---@param self GitStatusWindow
---@return boolean
function M.discard_current_hunk(self)
    return apply_current_hunk(self, 'discard')
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
---@return boolean?
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

        return M.open_commit_diff(self, item.commit, {
            force = true,
        })
    end

    local item = refresh_entry_item(self, state)

    if item == nil then
        return
    end

    return M.open_diff(self, item.entry, item.section, {
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
