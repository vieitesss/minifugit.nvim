---@class MiniFugitPreviewBufferActions
---@field close_diff fun()
---@field jump_hunk fun(delta: integer)
---@field toggle_wrap fun()
---@field toggle_numbers fun()
---@field toggle_headers fun()
---@field toggle_split_numbers fun()
---@field stage_current_hunk fun()
---@field unstage_current_hunk fun()
---@field discard_current_hunk fun()
---@field toggle_layout fun()
---@field goto_code fun()
---@field toggle_help fun()

---@class MiniFugitPreviewActions : MiniFugitPreviewBufferActions
---@field has_open_diff fun(): boolean
---@field focus_open_diff fun()
---@field refresh fun(state: GitStatusCursorState?)

return {}
