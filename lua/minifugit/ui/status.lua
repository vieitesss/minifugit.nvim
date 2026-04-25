local Buffer = require('minifugit.ui.buffer')
local Highlight = require('minifugit.ui.highlight')
local log = require('minifugit.log')

---@class GitStatusWindow
---@field buf Buffer
---@field win number
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

---@param buf Buffer
---@return number
local function create_win(buf)
    local parent_win = vim.api.nvim_get_current_win()
    local parent_width = vim.api.nvim_win_get_width(parent_win)

    local width = math.max(math.floor(parent_width * 0.3), 20)

    vim.cmd('botright ' .. width .. 'vsplit')

    local win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)

    log.info(string.format('created status window win=%d buf=%d', win, buf.id))

    return win
end

---@return table<string, Highlight>
function GitStatusWindow:highlights()
    local ns = 'GitStatusWindow'
    return {
        staged = Highlight.new({
            namespace = ns,
            name = 'MiniFugitStage',
            sources = { 'Added', 'String' },
            fallback_fg = 0x98C379,
        }),
        unstaged = Highlight.new({
            namespace = ns,
            name = 'MiniFugitUnstage',
            sources = { 'Removed', 'Error' },
            fallback_fg = 0xE06C75,
        }),
        untracked = Highlight.new({
            namespace = ns,
            name = 'MiniFugitUntracked',
            sources = { 'DiagnosticInfo', 'Directory', 'Identifier' },
            fallback_fg = 0x61AFEF,
        }),
        ignored = Highlight.new({
            namespace = ns,
            name = 'MiniFugitIgnored',
            sources = { 'Comment' },
            fallback_fg = 0x5C6370,
        }),
        conflict = Highlight.new({
            namespace = ns,
            name = 'MiniFugitConflict',
            sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
            fallback_fg = 0xE06C75,
        }),
        head = Highlight.new({
            namespace = ns,
            name = 'MiniFugitHead',
            sources = { 'Identifier', 'Keyword' },
            fallback_fg = 0x61AFEF,
        }),
    }
end

function GitStatusWindow:highlights_ensure()
    for _, h in pairs(self:highlights()) do
        h:ensure()
    end
end

function GitStatusWindow:ensure_keymaps()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    vim.api.nvim_buf_set_keymap(
        self.buf.id,
        'n',
        '<CR>',
        "<CMD>lua require('minifugit.git_status.actions').go_to_file()<CR>",
        {}
    )

    vim.api.nvim_buf_set_keymap(
        self.buf.id,
        'n',
        '=',
        "<CMD>lua require('minifugit.git_status.actions').diff_file()<CR>",
        {}
    )
end

---@return GitStatusWindow
function GitStatusWindow.new()
    local self = setmetatable({}, GitStatusWindow)

    self:highlights_ensure()

    ---@type BufferOpts
    local opts = { listed = true, scratch = true, name = 'Minifugit' }
    self.buf = Buffer.new(opts)

    self:ensure_keymaps()

    -- local content = {}
    --
    -- local head_line = gsf.head_line(git.branch())
    -- local status_lines = gsf.lines(git.status())
    --
    -- table.insert(content, head_line)
    -- if #status_lines > 0 then
    --     table.insert(content, '')
    --     vim.list_extend(content, status_lines)
    -- end
    --
    -- uis.set_lines(content)
    --
    self.win = create_win(self.buf)

    return self
end

return GitStatusWindow

-- ---@param lines (string|MiniFugitLine)[]
-- ---@return MiniFugitLine[]
-- local function normalize_lines(lines)
--     local normalized = {}
--
--     for _, line in ipairs(lines) do
--         if type(line) == 'string' then
--             if line == '' then
--                 table.insert(normalized, highlight.plain_line(line))
--             else
--                 for _, value in ipairs(vim.split(line, '\n', { plain = true })) do
--                     table.insert(normalized, highlight.plain_line(value))
--                 end
--             end
--         else
--             table.insert(
--                 normalized,
--                 highlight.line(line.text, line.highlights, line.data)
--             )
--         end
--     end
--
--     return normalized
-- end
--
-- ---@param row integer
-- ---@return MiniFugitLine?
-- function ui_status.get_line(row)
--     return ui_status._lines[row]
-- end
--
-- ---@return integer
-- function ui_status.get_win()
--     return ui_status._win
-- end
--
-- ---@return integer
-- function ui_status.get_buf()
--     return ui_status._buf
-- end
--
-- ---@return UIBufWin
-- function ui_status.open_win()
--     if
--         not vim.api.nvim_buf_is_valid(ui_status._buf)
--         or not vim.api.nvim_win_is_valid(ui_status._win)
--     then
--         if ui_status._buf ~= -1 then
--             ui.close_win()
--         end
--
--         local bufwin = create_win()
--
--         ui_status._buf = bufwin.buf
--         ui_status._win = bufwin.win
--         ui_status._lines = {}
--
--         return {
--             buf = ui_status._buf,
--             win = ui_status._win,
--         }
--     end
--
--     log.info(
--         string.format(
--             'reusing status window win=%d buf=%d',
--             ui_status._win,
--             ui_status._buf
--         )
--     )
--     vim.api.nvim_set_current_win(ui_status._win)
--
--     return {
--         buf = ui_status._buf,
--         win = ui_status._win,
--     }
-- end
--
-- ---@param lines (string|MiniFugitLine)[] Array of lines to replace in the window
-- function ui_status.set_lines(lines)
--     local b = ui_status._buf
--     local normalized_lines = normalize_lines(lines)
--
--     ui.set_lines(normalized_lines, b)
--     highlight.apply(ui_status._buf, normalized_lines)
--     ui_status._lines = normalized_lines
-- end
--
-- return ui_status
