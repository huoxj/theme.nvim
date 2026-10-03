local M = {}

---@type table<string, string>
local readme_cache = {}



function M.setup_preview(buf, win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    buf, 0, -1, false,
    require("theme.preview_code")
  )
  vim.bo[buf].modifiable = false

  pcall(vim.treesitter.start, buf, "lua")

  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
end

function M.update_info(buf)
end

return M
