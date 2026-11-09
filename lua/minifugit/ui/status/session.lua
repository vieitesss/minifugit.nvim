---Restoring a session (`:mksession`, `ZR`) recreates each status window as an
---empty normal buffer that keeps the status buffer's name. Those leftovers are
---not status windows: they block the name of the next status buffer with the
---same id (E95) and leave a dead split in the layout.
local M = {}

local STATUS_NAME = '^Minifugit %[%d+%]$'

---@param bufnr integer
---@return boolean
local function is_restored_status(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)

    return vim.bo[bufnr].buftype == ''
        and not vim.bo[bufnr].modified
        and vim.fn.fnamemodify(name, ':t'):match(STATUS_NAME) ~= nil
        and vim.uv.fs_stat(name) == nil
end

---Wipe the buffers a session restored in place of status windows, closing
---their windows.
function M.drop_restored()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if is_restored_status(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
end

return M
