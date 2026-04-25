---@class Buffer
---@field listed boolean
---@field scratch boolean
---@field name string
---@field id number
local Buffer = {}
Buffer.__index = Buffer

local log = require("minifugit.log")

---@alias BufferOpts {
    ---listed: boolean,
    ---scratch: boolean,
    ---name?: string,
    ---}

-- local function create_buf()

---@param opts BufferOpts
---@return Buffer
function Buffer.new(opts)
    local self = setmetatable({}, Buffer)

    assert(opts.listed, "`listed` is required")
    assert(opts.scratch, "`scratch` is required")

    self.listed = opts.listed
    self.scratch = opts.scratch

    local buf = vim.api.nvim_create_buf(opts.listed, opts.scratch)

    if opts.name and #opts.name > 0 then
        vim.api.nvim_buf_set_name(buf, opts.name)
    end

    self.id = buf
    self.lines = {}

    return self
end

function Buffer:is_valid()
    return self.id and vim.api.nvim_buf_is_valid(self.id)
end

function Buffer:delete()
    if not self:is_valid() then
        log.error("Cannot delete buf=" .. self.id)
        return
    end
    vim.api.nvim_buf_delete(self.id, { force = true })
end

---@param lines string[] Array of lines to replace in the Buffer
function Buffer:set_lines(lines)
    if not self:is_valid() then
        log.error('Cannot set lines into buf=' .. self.id)
        return
    end

    if #lines == 0 then
        log.debug('No lines to write')
        return
    end

    vim.api.nvim_buf_set_lines(self.id, 0, -1, false, lines)
    self.lines = lines
end

return Buffer
