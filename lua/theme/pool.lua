-- Theme discovery on runtimepath + the random-pool include/exclude rules.
local M = {}

local cfg = require("theme.config")
local cs = require("theme.colorscheme")

local scanned = false
local builtin, installed = {}, {}

local function scan()
  if scanned then return end
  scanned = true

  local runtime = vim.fs.normalize(vim.env.VIMRUNTIME or "")
  for _, file in ipairs(vim.api.nvim_get_runtime_file("colors/*", true)) do
    local ext = vim.fn.fnamemodify(file, ":e")
    if ext == "vim" or ext == "lua" then
      local name = vim.fn.fnamemodify(file, ":t:r")
      if vim.fs.normalize(file):sub(1, #runtime + 1) == runtime .. "/" then
        builtin[#builtin + 1] = name
      else
        installed[#installed + 1] = name
      end
    end
  end
end

---@return string[]
function M.builtin_themes()
  scan()
  return builtin
end

---@return string[]
function M.installed_themes()
  scan()
  return installed
end

---@return string[]
function M.all_themes()
  scan()
  local all = vim.list_slice(builtin)
  vim.list_extend(all, installed)
  return all
end

--- Resolve one pool entry: a tag (#all/#builtin) or a plain theme name.
---@param spec string
---@return string[]
local function resolve(spec)
  if spec == "#all" then return M.all_themes() end
  if spec == "#builtin" then return M.builtin_themes() end
  if spec:sub(1, 1) == "#" then
    vim.notify("theme: unknown theme spec: " .. spec, vim.log.levels.WARN)
    return {}
  end
  return { spec }
end

--- Append (never overwrite) the names resolved from every spec.
---@param specs string[]
---@return string[]
local function resolve_all(specs)
  local names = {}
  for _, spec in ipairs(specs) do
    vim.list_extend(names, resolve(spec))
  end
  return names
end

--- The names a random theme is picked from: include - exclude - current.
---@return string[]
function M.random_pool()
  local excluded = {}
  for _, name in ipairs(resolve_all(cfg.opts.random_pool.exclude)) do
    excluded[name] = true
  end
  excluded[cs.current()] = true

  local pool, seen = {}, {}
  for _, name in ipairs(resolve_all(cfg.opts.random_pool.include)) do
    if not excluded[name] and not seen[name] then
      seen[name] = true
      pool[#pool + 1] = name
    end
  end
  -- TODO(R6): drop disliked themes here
  return pool
end

function M.apply_random()
  math.randomseed(math.floor(vim.uv.hrtime() * vim.fn.getpid()) % 2147483647)
  local pool = M.random_pool()
  if #pool == 0 then
    vim.notify("theme: no themes in random pool", vim.log.levels.WARN)
    return
  end
  cs.apply(pool[math.random(#pool)])
end

return M
