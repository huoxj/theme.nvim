local M = {}

---@param buf integer
---@param win integer
function M.setup_preview(buf, win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    buf, 0, -1, false,
    require("theme.preview_code")
  )
  pcall(vim.treesitter.start, buf, "lua")
  vim.bo[buf].modifiable = false

  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
end

return M
