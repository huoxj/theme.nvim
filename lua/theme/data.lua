-- Hl.json layout (offline dataset built by scripts/build_hljson.py):
--
-- { name: Repo }
--
-- Repo = { name: "owner/repo", stars: int, description: string,
--          num_colorschemes: int, colorschemes: { name: Colorscheme } }
-- 
-- Colorscheme = { name: string, repo: string,
--                 bg_type: "light"|"dark"|"both",
--                 hlgs_light: (Hlg?)[?], hlgs_dark: (Hlg?)[?] }

local M = {}

---@type table<string, Repo>
local repos = {}
local loaded = false

local function ensure_load_hldata()
  if loaded then return end

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

  repos = doc

  loaded = true
end

--- Query colorscheme highlight groups for one background
---@param repo string
---@param name string
---@param background "light"|"dark"
---@return HighlightGroup?
function M.query_hl(repo, name, background)
  ensure_load_hldata()
  if not repos[repo] then return nil end
  if not repos[repo].colorschemes[name] then return nil end
  return repos[repo].colorschemes[name].hlgs[background]
end

---@return table<string, Repo>
function M.repos()
  ensure_load_hldata()
  return repos
end

return M
