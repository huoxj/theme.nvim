local M = {}

local data = require("theme.data")

local SWATCH = {
  { "@keyword", "@keyword.operator", "@keyword.function" },
  { "@function", "@function.call", "@constructor" },
  { "@string" },
  { "@constant", "@constant.builtin", "@number" },
  { "@variable.member", "@property", "@variable.parameter" },
}

---@param buf integer
---@param win integer
function M.setup_cs_list(buf, win)
  -- 1. prepare colorscheme data for list
  local colorschemes = data.colorschemes()
  local colorscheme_names = vim.tbl_keys(colorschemes)
  table.sort(colorscheme_names)

  -- 2. list content & win/buffer settings
  vim.api.nvim_buf_set_lines(
    buf, 0, -1, false,
    colorscheme_names
  )
  vim.bo[buf].modifiable = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.api.nvim_set_current_win(win)
end

function M.render_list(buf, win)

end

return M
