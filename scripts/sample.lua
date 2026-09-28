local keys = vim.json.decode(vim.env.THEME_KEYS)
local function grab()
  local out = {}
  for _, k in ipairs(keys) do
    local hl = vim.api.nvim_get_hl(0, { name = k })
    if hl and (hl.fg or hl.bg or hl.link) then out[k] = hl end
  end
  return out
end
vim.opt.rtp:prepend(vim.env.THEME_DIR)
vim.o.background = "dark"
pcall(vim.cmd, "colorscheme " .. vim.env.THEME_NAME)
local dark = grab()
vim.o.background = "light"
pcall(vim.cmd, "colorscheme " .. vim.env.THEME_NAME)
local light = grab()
print(vim.json.encode({ dark = dark, light = light }))

