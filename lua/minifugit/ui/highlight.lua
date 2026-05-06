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

-----@class MiniFugitHighlight
-----@field group string
-----@field start_col integer
-----@field end_col integer
--
-----@class MiniFugitLine
-----@field text string
-----@field highlights MiniFugitHighlight[]
-----@field data GitStatusEntry?
--
-----@class MiniFugitHighlightModule
-----@field line function Creates a line with optional highlights
-----@field plain_line function Creates a line without highlights
-----@field add function Adds a highlight range to a line
-----@field apply function Applies highlights to a buffer
--
--local namespace = vim.api.nvim_create_namespace('minifugit.ui')
--
-----@type MiniFugitHighlightModule
--local highlight = {
--    line = function() end,
--    plain_line = function() end,
--    add = function() end,
--    apply = function() end,
--}
--
--
--
-----@param text string
-----@param highlights MiniFugitHighlight[]?
-----@param data GitStatusEntry?
-----@return MiniFugitLine
--function highlight.line(text, highlights, data)
--    return {
--        text = text,
--        highlights = highlights or {},
--        data = data,
--    }
--end
--
-----@param line string
-----@return MiniFugitLine
--function highlight.plain_line(line)
--    return highlight.line(line)
--end
--
-----@param line MiniFugitLine
-----@param group string?
-----@param start_col integer
-----@param end_col integer?
--function highlight.add(line, group, start_col, end_col)
--    if not group then
--        return
--    end
--
--    table.insert(line.highlights, {
--        group = group,
--        start_col = start_col,
--        end_col = end_col or (start_col + 1),
--    })
--end
--
-----@param buf integer
-----@param lines MiniFugitLine[]
--function highlight.apply(buf, lines)
--    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
--
--    for index, line in ipairs(lines) do
--        local line_number = index - 1
--
--        for _, range in ipairs(line.highlights) do
--            vim.api.nvim_buf_set_extmark(
--                buf,
--                namespace,
--                line_number,
--                range.start_col,
--                {
--                    end_col = range.end_col,
--                    hl_group = range.group,
--                }
--            )
--        end
--    end
--end
--
