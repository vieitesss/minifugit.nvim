---@class MiniFugitWordDiffRange
---@field start_col integer
---@field end_col integer

local M = {}

---@param text string
---@return string[]
local function tokenize(text)
    local tokens = {}
    local index = 1

    while index <= #text do
        local start_index = index
        local char = text:sub(index, index)
        local is_word = char:match('[%w_]') ~= nil

        index = index + 1

        while index <= #text do
            local next_char = text:sub(index, index)
            local next_is_word = next_char:match('[%w_]') ~= nil

            if next_is_word ~= is_word then
                break
            end

            index = index + 1
        end

        table.insert(tokens, text:sub(start_index, index - 1))
    end

    if #tokens == 0 then
        return { text }
    end

    return tokens
end

---@param tokens string[]
---@param start_token integer 1-indexed
---@param token_count integer
---@return MiniFugitWordDiffRange?
local function token_range(tokens, start_token, token_count)
    if token_count <= 0 then
        return nil
    end

    local end_token = start_token + token_count - 1
    local start_col = 0

    for token = 1, start_token - 1 do
        start_col = start_col + #(tokens[token] or '')
    end

    local end_col = start_col

    for token = start_token, end_token do
        end_col = end_col + #(tokens[token] or '')
    end

    if end_col <= start_col then
        return nil
    end

    return {
        start_col = start_col,
        end_col = end_col,
    }
end

---@param old_text string
---@param new_text string
---@param side 'left'|'right'
---@return MiniFugitWordDiffRange[]
function M.changed_ranges(old_text, new_text, side)
    local old_tokens = tokenize(old_text)
    local new_tokens = tokenize(new_text)
    local old_token_text = table.concat(old_tokens, '\n') .. '\n'
    local new_token_text = table.concat(new_tokens, '\n') .. '\n'
    local ok, hunks = pcall(vim.diff, old_token_text, new_token_text, {
        result_type = 'indices',
    })

    if not ok or hunks == nil then
        return {}
    end

    local ranges = {}

    for _, hunk in ipairs(hunks) do
        local range

        if side == 'left' then
            range = token_range(old_tokens, hunk[1], hunk[2])
        else
            range = token_range(new_tokens, hunk[3], hunk[4])
        end

        if range ~= nil then
            table.insert(ranges, range)
        end
    end

    return ranges
end

return M
