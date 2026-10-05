-- Hl.json layout (offline dataset built by scripts/build_hlbin.py):
--
-- { num_repo: int, hlg_keys: string[], repos: Repo[] }
--
-- Repo = { name: "owner/repo", stars: int, description: string,
--          num_colorschemes: int, colorschemes: Colorscheme[] }
-- Colorscheme = { name: string, bg_type: "light"|"dark"|"both",
--                 hlgs_light: (Hlg?)[?]?, hlgs_dark: (Hlg?)[?]? }
--
-- Hlg arrays are positionally indexed by hlg_keys; a nil entry means the
-- group is unset for that background. Hlg is a subset of vim's hl attrs
-- (fg, bg, bold, italic, reverse, underline, sp, blend, ...) that
-- nvim_set_hl accepts verbatim. Colors are 24-bit ints (0xRRGGBB).

local M = {}

--- background -> cs_name -> hlg_key -> Hlg
---@type table<string, table<string, table<string, HighlightGroup>>>
local hlgs = { light = {}, dark = {} }
---@type table<string, string>
local cs_repo_map = {}
---@type Repo[]
local repos = {}
local loaded = false

local function load_hljson()
  local path = vim.api.nvim_get_runtime_file("lua/theme/hl.json", false)[1]
  local handle = io.open(path, "rb")
  if not handle then
    return
  end
  local data = handle:read("*a")
  handle:close()

  local ok, doc = pcall(vim.json.decode, data)
  if not ok then
    vim.notify("theme: failed to parse hl.json: " .. tostring(doc),
      vim.log.levels.WARN)
    return
  end

  local keys = doc.hlg_keys
  for _, repo in ipairs(doc.repos) do
    repos[#repos + 1] = repo
    for _, cs in ipairs(repo.colorschemes) do
      cs_repo_map[cs.name] = repo.name
      for _, bg in ipairs({ "light", "dark" }) do
        local groups = cs["hlgs_" .. bg]
        if groups then
          local by_name = {}
          for i, hlg in ipairs(groups) do
            -- json null decodes to the vim.NIL userdata, not nil
            by_name[keys[i]] = hlg ~= vim.NIL and hlg or nil
          end
          hlgs[bg][cs.name] = by_name
        end
      end
    end
  end
  loaded = true
end

--- Query colorscheme highlight groups for one background
---@param name string
---@param background "light"|"dark"
---@return HighlightGroup? by_key  table<hlg_key, Hlg>
function M.query_hl(name, background)
  if not loaded then load_hljson() end
  return hlgs[background][name]
end

--- Query the github repo a colorscheme belongs to
---@param name string
---@return string?
function M.query_repo(name)
  if not loaded then load_hljson() end
  return cs_repo_map[name]
end

--- All repos in the offline dataset, ordered by stars (desc, build time)
---@return Repo[]
function M.repos()
  if not loaded then load_hljson() end
  return repos
end

return M
