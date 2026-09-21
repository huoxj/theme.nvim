local M = {}

M.defaults = {
  opts = {
    random_pool = {
      -- '#all: all themes in rtp; #builtin: vim builtin themes'
      include = { '#all' },
      exclude = {}
    }
  }
}

M.opts = vim.deepcopy(M.defaults.opts)

function M.setup(opts)
  M.opts = vim.tbl_deep_extend(
    "force", vim.deepcopy(M.defaults.opts), opts or {}
  )
end

return M

