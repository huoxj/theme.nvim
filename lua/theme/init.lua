local M = {}

local random_pool = require("theme.random_pool")
local cfg = require("theme.config")
local utils = require("theme.utils")

local function seed_random()
  local seed = vim.uv.hrtime() * vim.fn.getpid()
  math.randomseed(math.floor(seed) % 2147483647)
end

local function apply_random()
  seed_random()
  local pool = random_pool.get_random_pool()
  utils.apply_colorscheme(pool[math.random(#pool)])
end

---@param opts? table
function M.setup(opts)
  cfg.setup(opts)
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
      apply_random()
    end, once = true
  })

end

return M
