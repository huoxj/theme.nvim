local M = {}

--- Apply a colorscheme, reporting the outcome instead of raising.
---@param name string
---@return boolean ok
function M.apply(name)
  local ok, err = pcall(vim.cmd.colorscheme, name)
  if ok then
    vim.notify(("theme: applied '%s'"):format(name), vim.log.levels.INFO)
  else
    vim.notify("theme: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

---@return string name
function M.current()
  return vim.g.colors_name or ""
end

return M
