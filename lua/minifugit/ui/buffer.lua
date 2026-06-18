---@class Buffer
---@field listed boolean
---@field scratch boolean
---@field name string
---@field id number
local Buffer = {}
Buffer.__index = Buffer

local log = require('minifugit.log')

---@alias BufferOpts {
---listed: boolean,
---scratch: boolean,
---name?: string,
---buftype?: string,
---bufhidden?: string,
---filetype?: string,
---}

---@param buf integer
---@param name string
---@param value any
function Buffer.set_buf_option(buf, name, value)
    vim.api.nvim_set_option_value(name, value, {
        buf = buf,
        scope = 'local',
    })
end

---@param opts BufferOpts
---@return Buffer
function Buffer.new(opts)
    vim.validate('opts', opts, 'table', '`opts` table is required')
    vim.validate('name', opts.name, 'string', true, '`name` should be a string')
    vim.validate('listed', opts.listed, 'boolean', '`listed` is required')
    vim.validate('scratch', opts.scratch, 'boolean', '`scratch` is required')
    vim.validate('buftype', opts.buftype, 'string', true)
    vim.validate('bufhidden', opts.bufhidden, 'string', true)
    vim.validate('filetype', opts.filetype, 'string', true)

    local self = setmetatable({}, Buffer)

    self.listed = opts.listed
    self.scratch = opts.scratch

    local buf = vim.api.nvim_create_buf(opts.listed, opts.scratch)

    if opts.name and #opts.name > 0 then
        vim.api.nvim_buf_set_name(buf, opts.name)
    end

    self.id = buf
    self.lines = {}

    if opts.scratch then
        Buffer.set_buf_option(buf, 'buftype', opts.buftype or 'nofile')
        Buffer.set_buf_option(buf, 'bufhidden', opts.bufhidden or 'hide')
        Buffer.set_buf_option(buf, 'swapfile', false)
    elseif opts.buftype ~= nil then
        Buffer.set_buf_option(buf, 'buftype', opts.buftype)
    end

    if opts.bufhidden ~= nil and not opts.scratch then
        Buffer.set_buf_option(buf, 'bufhidden', opts.bufhidden)
    end

    if opts.filetype ~= nil then
        Buffer.set_buf_option(buf, 'filetype', opts.filetype)
    end

    return self
end

---@param name string
---@param value any
function Buffer:set_option(name, value)
    if not self:is_valid() then
        log.error('Cannot set option on buf=' .. self.id)
        return
    end

    Buffer.set_buf_option(self.id, name, value)
end

---@param value boolean
function Buffer:set_modifiable(value)
    self:set_option('modifiable', value)
end

function Buffer:is_valid()
    return self.id and vim.api.nvim_buf_is_valid(self.id)
end

function Buffer:delete()
    if not self:is_valid() then
        log.error('Cannot delete buf=' .. self.id)
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
