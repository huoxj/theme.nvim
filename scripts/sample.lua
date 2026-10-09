local keys = vim.json.decode(vim.env.HLG_KEYS)
local function resolve_group(k)
  local seen = {}
  while true do
    local hl = vim.api.nvim_get_hl(0, { name = k })
    if hl and (hl.fg ~= nil or hl.bg ~= nil) then
      -- nvim_get_hl returns a dict where missing fields are vim.NIL;
      -- vim.NIL stringifies to 0, so json-encoding it verbatim corrupts
      -- colors into 0x000000. Copy only true scalar attrs instead.
      local out = {}
      for attr, val in pairs(hl) do
        if type(val) == "number" or type(val) == "boolean"
            or type(val) == "string" then
          out[attr] = val
        end
      end
      return out
    end
    if not hl or not hl.link or seen[hl.link] then
      return nil
    end
    seen[k] = true
    k = hl.link
  end
end
local function grab()
  local out = {}
  for _, k in ipairs(keys) do
    local hl = vim.api.nvim_get_hl(0, { name = k })
    if hl and (hl.fg ~= nil or hl.bg ~= nil or hl.link ~= nil) then
      out[k] = resolve_group(k)
    end
  end
  return out
end
vim.opt.rtp:prepend(vim.env.CS_DIR)
vim.cmd("highlight clear")
local ok = pcall(vim.cmd, "colorscheme " .. vim.env.CS_NAME)
if not (ok and vim.g.colors_name == vim.env.CS_NAME) then
  os.exit(1)
end
io.stderr:write("[[[THEME.NVIM SAMPLING START]]]\n")
io.stderr:write(vim.json.encode(grab()))
io.stderr:write("\n[[[THEME.NVIM SAMPLING END]]]\n")
