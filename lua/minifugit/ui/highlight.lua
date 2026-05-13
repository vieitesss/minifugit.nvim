---@class Highlight
---@field fallback_fg number?
---@field fallback_bg number?
---@field ensure function

local Highlight = {}
Highlight.__index = Highlight

---@alias HighlightOptions {
---name: string,
---namespace: string,
---sources: string[],
---fallback_fg: number?,
---fallback_bg: number?,
---}

---@param names string[]
---@return vim.api.keyset.get_hl_info
local function get_highlight(names)
    for _, name in ipairs(names) do
        local ok, source = pcall(vim.api.nvim_get_hl, 0, {
            name = name,
            link = false,
        })

        if ok and next(source) ~= nil then
            return source
        end
    end

    return {}
end

---@param names string[]
---@param key 'fg'|'bg'
---@return integer?
local function get_highlight_attr(names, key)
    for _, name in ipairs(names) do
        local ok, source = pcall(vim.api.nvim_get_hl, 0, {
            name = name,
            link = false,
        })

        if ok and source[key] ~= nil then
            return source[key]
        end
    end

    return nil
end

---@param name string
---@param sources string[]
---@param fallback_fg integer?
---@param fallback_bg integer?
local function set_highlight(name, sources, fallback_fg, fallback_bg)
    local source = get_highlight(sources)
    local resolved_fg = get_highlight_attr(sources, 'fg')
    local resolved_bg = get_highlight_attr(sources, 'bg')

    local opts = {
        bold = source.bold,
        italic = source.italic,
        underline = source.underline,
    }

    if fallback_fg ~= nil then
        opts.fg = resolved_fg or fallback_fg
    end

    if fallback_bg ~= nil then
        opts.bg = resolved_bg or fallback_bg
    end

    vim.api.nvim_set_hl(0, name, opts)
end

---name: string,
---namespace: string,
---sources: string[],
---fallback_fg: number?,
---fallback_bg: number?,
---@param opts HighlightOptions
---@return Highlight
function Highlight.new(opts)
    vim.validate('opts', opts, 'table', '`opts` table is required')
    vim.validate('name', opts.name, 'string', '`name` is required')
    vim.validate(
        'namespace',
        opts.namespace,
        'string',
        '`namespace` is required'
    )
    vim.validate('sources', opts.sources, 'table', '`sources` is required')
    vim.validate(
        'fallback_fg',
        opts.fallback_fg,
        'number',
        true,
        '`fallback_fg` should be a number'
    )
    vim.validate(
        'fallback_bg',
        opts.fallback_bg,
        'number',
        true,
        '`fallback_bg` should be a number'
    )

    if opts.fallback_fg == nil and opts.fallback_bg == nil then
        error('Highlight requires fallback_fg or fallback_bg')
    end

    local self = setmetatable({}, Highlight)

    self.name = opts.name
    self.namespace_id = vim.api.nvim_create_namespace(opts.namespace)
    self.sources = opts.sources
    self.fallback_fg = opts.fallback_fg
    self.fallback_bg = opts.fallback_bg

    return self
end

function Highlight:ensure()
    set_highlight(self.name, self.sources, self.fallback_fg, self.fallback_bg)
end

return Highlight
