-- Offline dataset lua/theme/hl.json, harvested by scripts/build_hljson.py.
--
--   { [repo] = Repo }
--
--   Repo        = { name, default_branch, stars, description, num_colorschemes,
--                   readme, colorschemes = { [name] = Colorscheme } }
--   Colorscheme = { name, repo, bg_type, hlgs = { light = HighlightGroups?,
--                                                  dark  = HighlightGroups? } }
--
-- `readme` is the repo's README text (capped by the harvester). Datasets built
-- before the field existed simply omit it. The panel no longer displays it:
-- the live README is rendered with markview, and every fallback is the info
-- card built from the rest of the record.
--
-- Only repos whose colorschemes could be sampled are present.

---@class HighlightGroup : vim.api.keyset.highlight
---@alias HighlightGroups table<string, HighlightGroup>
---@alias BgType "light"|"dark"|"both"
---@class Colorscheme
---@field name string
---@field repo string
---@field bg_type BgType
---@field hlgs table<"light"|"dark", HighlightGroups>
---@class Repo
---@field name string "owner/repo"
---@field default_branch string
---@field stars number
---@field description string
---@field num_colorschemes number
---@field readme string? README text; absent in datasets built before the field
---@field colorschemes table<string, Colorscheme>

local M = {}

---@type table<string, Repo>
local repos = {}
--- colorscheme name -> its record, for previews keyed by theme name only
---@type table<string, Colorscheme>
local by_name = {}
local loaded = false

local function load()
  if loaded then return end
  loaded = true

  local path = vim.api.nvim_get_runtime_file("lua/theme/hl.json", false)[1]
  local file = path and io.open(path, "rb")
  if not file then return end
  local ok, doc = pcall(vim.json.decode, file:read("*a"))
  file:close()
  if not ok then
    vim.notify("theme: failed to parse hl.json: " .. tostring(doc),
      vim.log.levels.WARN)
    return
  end

  repos = doc
  for _, repo in pairs(repos) do
    for _, colorscheme in pairs(repo.colorschemes) do
      by_name[colorscheme.name] = by_name[colorscheme.name] or colorscheme
    end
  end
end

--- Highlight groups of a colorscheme (looked up by name), for one background.
--- Falls back to the colorscheme's own background when the asked one is absent.
---@param name string
---@param background "light"|"dark"
---@return HighlightGroups?
function M.query_hl(name, background)
  load()
  local colorscheme = by_name[name]
  if not colorscheme then return nil end
  return colorscheme.hlgs[background] or colorscheme.hlgs[colorscheme.bg_type]
end

---@return table<string, Repo>
function M.repos()
  load()
  return repos
end

return M
