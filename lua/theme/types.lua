
error('Cannot require a meta file')

---@class HighlightGroup : vim.api.keyset.highlight

--- table<hlg_key, HighlightGroup>
---@alias HighlightGroups table<string, HighlightGroup>

---@alias BgType "light"|"dark"|"both"

---@class Colorscheme
---@field name string
---@field bg_type BgType
---@field hlgs_light (HighlightGroup?)[]?  indexed by hlg_keys
---@field hlgs_dark (HighlightGroup?)[]?  indexed by hlg_keys

---@class Repo
---@field name string "owner/repo"
---@field stars number
---@field description string
---@field num_colorschemes number
---@field colorschemes Colorscheme[]
