-- Float panel: repo list -> colorscheme list -> live preview (R2b, R3).
local M = {}

local list = require("theme.ui.list")
local preview = require("theme.preview")

local FOCUS_ORDER = { "repo", "cs", "preview" }
local DEBOUNCE_MS = 200

local active = nil
local timer = vim.uv.new_timer()

---@return table<string, { row: integer, col: integer, width: integer, height: integer }>
local function layout()
  local cols, lines = vim.o.columns, vim.o.lines
  local w, h = math.floor(cols * 0.8), math.floor(lines * 0.8)
  local row0, col0 = math.floor((lines - h) / 2), math.floor((cols - w) / 2)
  local left = math.floor(w * 0.2)   -- width of the two list panes
  local list_h = math.floor(h * 0.7) -- height of the repo list
  return {
    backdrop = { row = 0, col = 0, width = cols, height = lines },
    frame = { row = row0 - 1, col = col0 - 1, width = w + 2, height = h + 2 },
    repo = { row = row0, col = col0, width = left, height = list_h },
    cs = { row = row0 + list_h + 1, col = col0, width = left, height = h - list_h - 3 },
    preview = { row = row0, col = col0 + left + 1, width = w - left - 1, height = h - 2 },
  }
end

---@param buf integer
---@param rect table
---@param conf table?
---@return integer win
local function open_float(buf, rect, conf)
  local win = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", {
    relative = "editor", style = "minimal", border = "none", zindex = 40,
  }, rect, conf or {}))
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  return win
end

---@param p table
local function focus(p, step)
  local cur = vim.api.nvim_get_current_win()
  local idx = 1
  for i, name in ipairs(FOCUS_ORDER) do
    if p.wins[name] == cur then idx = i end
  end
  local next_win = p.wins[FOCUS_ORDER[(idx - 1 + step) % #FOCUS_ORDER + 1]]
  if next_win and vim.api.nvim_win_is_valid(next_win) then
    vim.api.nvim_set_current_win(next_win)
  end
end

---@param p table
local function map_keys(p)
  for _, name in ipairs(FOCUS_ORDER) do
    local buf = p.bufs[name]
    local opts = { buffer = buf }
    vim.keymap.set("n", "<Esc>", function() M.close(p) end, opts)
    vim.keymap.set("n", "q", function() M.close(p) end, opts)
    vim.keymap.set("n", "<Tab>", function() focus(p, 1) end, opts)
    vim.keymap.set("n", "<S-Tab>", function() focus(p, -1) end, opts)
  end
end

---@param p table
local function show_preview(p, hlgs)
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_win_is_valid(p.wins.preview) then
      preview.tint(p.wins.preview, hlgs)
    end
  end))
end

function M.open()
  if active and vim.api.nvim_win_is_valid(active.wins.repo) then
    return vim.api.nvim_set_current_win(active.wins.repo)
  end

  local rects = layout()
  local p = { wins = {}, bufs = {}, origin = vim.api.nvim_get_current_win() }
  local aug = vim.api.nvim_create_augroup("ThemeUI", { clear = true })

  ---@param name string
  ---@param rect table
  ---@param conf table?
  ---@param win_opts table?
  local function add(name, rect, conf, win_opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local win = open_float(buf, rect, conf)
    for opt, val in pairs(win_opts or {}) do vim.wo[win][opt] = val end
    p.bufs[name], p.wins[name] = buf, win
  end

  add("backdrop", rects.backdrop, { zindex = 38, focusable = false },
    { winblend = 60, winhighlight = "Normal:ThemeUIBackdrop" })
  add("frame", rects.frame, {
    focusable = false, zindex = 39,
    title = " theme ", title_pos = "center", border = "rounded",
  })
  add("repo", rects.repo)
  add("cs", rects.cs)
  add("preview", rects.preview)

  list.setup(p.bufs.repo, p.wins.repo, p.bufs.cs, p.wins.cs)
  preview.fill(p.bufs.preview)
  vim.wo[p.wins.preview].cursorline = false
  vim.wo[p.wins.preview].wrap = false

  map_keys(p)

  for _, name in ipairs({ "repo", "cs" }) do
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = aug, buffer = p.bufs[name],
      callback = function()
        list.sync()
        local row = list.current_cs()
        if row then show_preview(p, row.hlgs) end
      end,
    })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(e)
      for _, win in pairs(p.wins) do
        if e.match == tostring(win) then return M.close(p) end
      end
    end,
  })

  active = p
end

---@param p table?
function M.close(p)
  if not p or p.closed then return end
  p.closed = true
  pcall(vim.api.nvim_del_augroup_by_name, "ThemeUI")
  for _, win in pairs(p.wins) do
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_win_is_valid(p.origin) then
    vim.api.nvim_set_current_win(p.origin)
  end
  active = nil
end

return M
