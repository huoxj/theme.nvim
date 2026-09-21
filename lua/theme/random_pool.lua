local M = {}

local cfg = require("theme.config")
local utils = require("theme.utils")

M._scanned = false
---@type table<string, true>
M._builtin_themes = {}
---@type table<string, true>
M._installed_themes = {}

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
      M._builtin_themes[name] = true
    else
      M._installed_themes[name] = true
    end

    ::continue::
  end

end

---@param specs string[]
---@return table<string, true>
local function resolve_specs(specs)
  local theme_set = {}
  for _, name in ipairs(specs) do
    local themes = {}
    if name == "#all" then themes = vim.tbl_extend(
      "force", M.get_builtin_themes(), M.get_installed_themes()
    )
    elseif name == "#builtin" then themes = M.get_builtin_themes()
    elseif name:sub(1, 1) == "#" then
      vim.notify(
        string.format("Unknown theme spec: %s", name),
        vim.log.levels.WARN
      )
    else themes = { [name] = true } end
    theme_set = vim.tbl_extend("force", theme_set, themes)
  end
  return theme_set
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

---@return string[]
function M.get_random_pool()
  local include_set = resolve_specs(
    cfg.opts.random_pool.include
  )
  local exclude_set = resolve_specs(
    cfg.opts.random_pool.exclude
  )
  local set = utils.set_difference(include_set, exclude_set)
  -- TODO: filter out disliked themes

  -- convert set to string[]
  local pool = {}
  for name in pairs(set) do
    table.insert(pool, name)
  end
  return pool
end

return M

