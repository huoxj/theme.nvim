local M = {}

local random_pool = require("theme.random_pool")
local cfg = require("theme.config")

---@param opts? table
function M.setup(opts)
  cfg.setup(opts)
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function() random_pool.apply_random() end, once = true
  })

end

return M
