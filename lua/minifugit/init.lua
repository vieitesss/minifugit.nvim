local M = {}

local highlight = require('minifugit.highlight')
local log = require('minifugit.log')
local uis = require('minifugit.ui.status')
local git = require('minifugit.git')
local gsf = require('minifugit.git_status.formatting')
local keymaps = require('minifugit.git_status.keymaps')

M.status = function()
    log.info('status command called')

    ---@type UIBufWin
    local info = uis.open_win()

    log.info(string.format("Window opened win=%d buf=%d", info.win, info.buf))

    highlight.ensure()
    keymaps.apply(info.buf)

    local content = {}

    local head_line = gsf.head_line(git.branch())
    local status_lines = gsf.lines(git.status())

    table.insert(content, head_line)
    if #status_lines > 0 then
        table.insert(content, '')
        vim.list_extend(content, status_lines)
    end

    uis.set_lines(content)
end

return M
