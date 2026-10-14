local M = {}

local DEFAULTS = {
  random_pool = {
    -- '#all': every theme on runtimepath; '#builtin': Neovim's own themes
    include = { "#all" },
    exclude = {},
  },
}

M.opts = vim.deepcopy(DEFAULTS)

---@param opts? { random_pool?: { include?: string[], exclude?: string[] } }
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
end

return M
