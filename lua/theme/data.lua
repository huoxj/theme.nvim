-- Hl.bin data layout:
--
-- offset  size                  content
-- 0       16                    header: magic(8) key_count(2)
--                                       colorscheme_count(2)
--                                       name_len(2) repo_name_len(2)
-- 16      key_count*name_len    vocab: highlight group key names
-- ...     cs_count*record       record: colorscheme records
--
-- record = colorscheme_name(name_len)
--        + github_repo(repo_name_len)
--        + flags(1)
--        + highlight groups : fg_bitmap | bg_bitmap | fg_colors | bg_colors
-- bitmap = ceil(key_count/8) bytes, each bit indicates whether the group
--          has fg/bg in this background
-- colors = key_count×3 bytes, 3 bytes big-endian RGB.

local M = {}

local bit = require("bit")

local MAGIC = "HLBIN\0\0\1"
local FLAG_IS_LIGHT = 1

---@param str string
---@return string
local function read_cstring(str)
  local nul = str:find("\0", 1, true)
  return nul and str:sub(1, nul - 1) or str
end

---@type table<string>
local highlight_keys = {}
---@type table<string, HighlightGroups>
local light_colorschemes = {}
---@type table<string, HighlightGroups>
local dark_colorschemes = {}
---@type table<string, string>
local cs_repo_map = {}
local hlbin_loaded = false

local function load_hlbin()
  local path = vim.api.nvim_get_runtime_file("lua/theme/hl.bin", false)[1]
  local handle = io.open(path, "rb")
  if not handle then
    return
  end
  local data = handle:read("*a")

  -- read helpers
  local pos = 1
  local take = function(n)
    local s = data:sub(pos, pos + n - 1)
    pos = pos + n
    return s
  end
  local take_u16 = function()
    local low, high = data:byte(pos, pos + 1)
    pos = pos + 2
    return low + high * 256
  end
  local take_rgb = function()
    local r, g, b = data:byte(pos, pos + 2)
    pos = pos + 3
    return r * 65536 + g * 256 + b
  end


  -- 1. parse header and metadata
  local header_magic = take(8)
  if header_magic ~= MAGIC then return end

  local key_count = take_u16()
  local colorscheme_count = take_u16()
  local name_len = take_u16()
  local repo_name_len = take_u16()
  local bitmap_len = math.ceil(key_count / 8)

  -- 2. parse vocab
  for i = 1, key_count do
    highlight_keys[i] = read_cstring(take(name_len))
  end

  -- 3. parse records
  local function read_hlgs(hlgs, bitmap, set_field)
    for j = 1, key_count do
      local byte_idx = math.floor((j - 1) / 8)
      local mask = bit.lshift(1, (j - 1) % 8)
      local key = highlight_keys[j]
      local group = hlgs[key] or {}
      local color = take_rgb()
      if bit.band(bitmap:byte(byte_idx + 1), mask) ~= 0 then
        group[set_field] = color
      end
      hlgs[key] = group
    end
  end
  for _ = 1, colorscheme_count do
    -- Names
    local cs_name = read_cstring(take(name_len))
    local repo_name = read_cstring(take(repo_name_len))

    -- Flags
    local flags = take(1):byte(1)
    local is_light = bit.band(flags, FLAG_IS_LIGHT) ~= 0

    -- Highlight groups
    local fg_bitmap = take(bitmap_len)
    local bg_bitmap = take(bitmap_len)

    ---@type HighlightGroups
    local hlgs = {}

    -- Foreground colors
    read_hlgs(hlgs, fg_bitmap, "fg")
    -- Background colors
    read_hlgs(hlgs, bg_bitmap, "bg")

    local target = is_light and light_colorschemes or dark_colorschemes
    target[cs_name] = hlgs
    cs_repo_map[cs_name] = repo_name
  end

  hlbin_loaded = true

end

--- Query colorscheme highlight groups
---@param name string
---@param background "light"|"dark"
---@return HighlightGroup?
function M.query_hl(name, background)
  if not hlbin_loaded then load_hlbin() end
  return (background == "light" and light_colorschemes[name])
      or (background == "dark" and dark_colorschemes[name])
      or nil
end

--- Query colorscheme repo name
---@param name string
---@return string?
function M.query_repo(name)
  if not hlbin_loaded then load_hlbin() end
  return cs_repo_map[name]
end

--- Get colorschemes
---@param background "light"|"dark"?
---@return table<string, HighlightGroups>
function M.colorschemes(background)
  if not hlbin_loaded then load_hlbin() end
  if background == "light" then
    return light_colorschemes
  elseif background == "dark" then
    return dark_colorschemes
  else
    -- TODO: bug, colorschemes with same name will be overwritten
    return vim.tbl_extend("force", light_colorschemes, dark_colorschemes)
  end
end

return M

