local M = {}

local cfg = require("theme.config")
local utils = require("theme.utils")

M._scanned = false
---@type string[]
M._builtin_themes = {}
---@type string[]
M._installed_themes = {}

local function seed_random()
  local seed = vim.uv.hrtime() * vim.fn.getpid()
  math.randomseed(math.floor(seed) % 2147483647)
end

---@param a string[]
---@param b string[]
---@return string[] result
local function arr_diff(a, b)
  local result = {}

  ---@type table<string, true>
  local set_b = {}
  for _, v in ipairs(b) do
    set_b[v] = true
  end

  for _, v in ipairs(a) do
    if not set_b[v] then
      table.insert(result, v)
    end
  end
  return result
end

local function scan_themes()
  if M._scanned then return end
  M._scanned = true
  M._builtin_themes = {}
  M._installed_themes = {}

  local runtime = vim.fs.normalize(vim.env.VIMRUNTIME or "")

  for _, file in ipairs(
    vim.api.nvim_get_runtime_file("colors/*", true)
  ) do
    local ext = vim.fn.fnamemodify(file, ":e")
    if ext ~= "vim" and ext ~= "lua" then
      goto continue
    end

    local name = vim.fn.fnamemodify(file, ":t:r")

    if vim.fs.normalize(file):sub(1, #runtime + 1) == runtime .. "/" then
      table.insert(M._builtin_themes, name)
    else
      table.insert(M._installed_themes, name)
    end

    ::continue::
  end

end

---@param specs string[]
---@return string[]
local function resolve_specs(specs)
  local result = {}
  for _, name in ipairs(specs) do
    local themes = {}
    if name == "#all" then themes = M.get_all_themes()
    elseif name == "#builtin" then themes = M.get_builtin_themes()
    elseif name:sub(1, 1) == "#" then
      vim.notify(
        string.format("Theme: Unknown theme spec: %s", name),
        vim.log.levels.WARN
      )
    else themes = { name } end
    result = vim.tbl_extend("force", result, themes)
  end
  return result
end

---@return string[]
function M.get_builtin_themes()
  scan_themes()
  return M._builtin_themes
end

---@return string[]
function M.get_installed_themes()
  scan_themes()
  return M._installed_themes
end

----@return string[]
function M.get_all_themes()
  scan_themes()
  return vim.tbl_extend(
    "force", M._builtin_themes, M._installed_themes
  )
end

---@return string[]
function M.get_random_pool()
  local include = resolve_specs(
    cfg.opts.random_pool.include
  )
  local exclude = resolve_specs(
    cfg.opts.random_pool.exclude
  )
  table.insert(exclude, utils.current_colorscheme())
  local result = arr_diff(include, exclude)
  -- TODO: filter out disliked themes

  return result
end

function M.apply_random()
  seed_random()
  local pool = M.get_random_pool()
  if #pool == 0 then
    vim.notify(
      "theme-manager: no themes available in random pool",
      vim.log.levels.WARN
    )
    return
  end
  utils.apply_colorscheme(pool[math.random(#pool)])
end

return M

