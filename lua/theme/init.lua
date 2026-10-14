local M = {}

local cfg = require("theme.config")

---@param opts? table
function M.setup(opts)
  cfg.setup(opts)
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function() require("theme.pool").apply_random() end,
  })
end

--- Entry point for the `:Theme` command.
---@param args string[]
function M.command(args)
  local sub = args[1]
  if sub == nil then
    return require("theme.ui").open()
  end
  if sub == "random" then
    return require("theme.pool").apply_random()
  end
  vim.notify("theme: unknown subcommand: " .. sub, vim.log.levels.WARN)
end

return M
