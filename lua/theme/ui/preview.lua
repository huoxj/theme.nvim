local M = {}

local ns = vim.api.nvim_create_namespace("theme_ui_preview")
local timer = vim.uv.new_timer()
local cur_cs = nil

--- Apply a colorscheme's hlgs (resolved by bg filter) to the preview window
---@param win integer
---@param cs Colorscheme
function M.update_preview_hl(win, cs)
  if not timer then return end
  if cur_cs == cs then return end
  cur_cs = cs
  timer:stop()
  timer:start(200, 0, vim.schedule_wrap(
    function ()
      for group, attrs in pairs(cs.hlgs[cs.bg_type]) do
        vim.api.nvim_set_hl(ns, group, attrs)
      end
      vim.api.nvim_win_set_hl_ns(win, ns)
    end
  ))
end

---@param buf integer
---@param win integer
function M.setup_preview(buf, win)
  -- Initialize with preview code
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
