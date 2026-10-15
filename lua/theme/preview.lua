-- Shared preview plumbing: a scratch buffer holding sample code, tinted by a
-- colorscheme's highlight groups without applying that colorscheme.
local M = {}

local ns = vim.api.nvim_create_namespace("theme_preview")

--- Fill a scratch buffer with the sample Lua source.
---@param buf integer
function M.fill(buf)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, require("theme.preview_code"))
  vim.bo[buf].modifiable = false
  pcall(vim.treesitter.start, buf, "lua")
end

--- Tint a window with highlight groups, leaving the active colorscheme alone.
--- `frame` (name -> attrs) restates panel chrome groups in the namespace so
--- the window's border/title keep the panel's colors instead of the previewed
--- theme's.
---@param win integer
---@param hlgs HighlightGroups?
---@param frame table<string, vim.api.keyset.highlight>?
function M.tint(win, hlgs, frame)
  for group, attrs in pairs(hlgs or {}) do
    vim.api.nvim_set_hl(ns, group, attrs)
  end
  for group, attrs in pairs(frame or {}) do
    vim.api.nvim_set_hl(ns, group, attrs)
  end
  vim.api.nvim_win_set_hl_ns(win, ns)
end

return M
