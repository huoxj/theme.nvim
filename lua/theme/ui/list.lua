-- Repo list (left-top) and colorscheme list (left-bottom) of the panel.
local M = {}

local data = require("theme.data")

-- Highlight groups whose colour is shown as a swatch on each colorscheme row.
local SWATCH_KEYS = { { "Search" }, { "PmenuSel" }, { "Visual" }, { "StatusLine" }, { "Pmenu" } }
local GLYPH = "∙"
local SWATCH_TEXT = GLYPH:rep(#SWATCH_KEYS)

local ns = vim.api.nvim_create_namespace("theme_ui_list")
local hl_seq = 0
local repo_rows, cs_rows = {}, {}
local repo_pane, cs_pane
local prev_repo

---@param text string
---@param max integer
---@return string
local function truncate(text, max)
  if vim.fn.strdisplaywidth(text) <= max then return text end
  return vim.fn.strcharpart(text, 0, math.max(1, max - 2)) .. ".."
end

--- Define a one-off highlight group in the list namespace.
---@param attrs HighlightGroup?
---@return string? name
local function hl_for(attrs)
  if not (attrs and (attrs.fg or attrs.bg)) then return nil end
  hl_seq = hl_seq + 1
  local name = "ThemeUIList" .. hl_seq
  vim.api.nvim_set_hl(ns, name, attrs)
  return name
end

---@param hlgs HighlightGroups?
---@param keys string[]
---@return HighlightGroup?
local function pick(hlgs, keys)
  for _, key in ipairs(keys) do
    local attrs = hlgs and hlgs[key]
    if attrs and (attrs.fg or attrs.bg) then return attrs end
  end
end

---@param rows table[]
---@param win integer
local function under_cursor(rows, win)
  return rows[vim.api.nvim_win_get_cursor(win)[1]]
end

---@return Repo?
function M.current_repo() return under_cursor(repo_rows, repo_pane.win) end
---@return { name: string, bg: "light"|"dark", hlgs: HighlightGroups? }?
function M.current_cs() return under_cursor(cs_rows, cs_pane.win) end

--- One renderable row per colorscheme; "both" colorschemes yield two rows.
---@param repo Repo
local function rows_for(repo)
  local colorschemes = vim.tbl_values(repo.colorschemes)
  table.sort(colorschemes, function(a, b) return a.name < b.name end)

  local rows = {}
  for _, colorscheme in ipairs(colorschemes) do
    if colorscheme.bg_type == "both" then
      rows[#rows + 1] = { name = colorscheme.name, bg = "dark", hlgs = colorscheme.hlgs.dark }
      rows[#rows + 1] = { name = colorscheme.name, bg = "light", hlgs = colorscheme.hlgs.light }
    else
      rows[#rows + 1] = {
        name = colorscheme.name, bg = colorscheme.bg_type,
        hlgs = colorscheme.hlgs[colorscheme.bg_type],
      }
    end
  end
  return rows
end

---@param row0 integer
---@param row { name: string, bg: "light"|"dark", hlgs: HighlightGroups? }
---@param width integer
---@return string text, integer[][] marks
local function build_cs_row(row0, row, width)
  local icon = row.bg == "light" and "" or ""
  local text = truncate(icon .. " " .. row.name, width - #SWATCH_KEYS - 1)
  local pad = (" "):rep(math.max(0, width - vim.fn.strdisplaywidth(text) - #SWATCH_KEYS))
  local full = text .. pad .. SWATCH_TEXT

  -- extmark columns are byte offsets; GLYPH is 3 bytes, 1 cell wide
  local swatch_col = #text + #pad
  local marks = {}
  local name_hl = hl_for(row.hlgs and row.hlgs.Normal)
  if name_hl then
    marks[#marks + 1] = { row0, 0, swatch_col, name_hl, 0 }
  end
  for i, keys in ipairs(SWATCH_KEYS) do
    local swatch_hl = hl_for(pick(row.hlgs, keys))
    if swatch_hl then
      marks[#marks + 1] = {
        row0, swatch_col + (i - 1) * #GLYPH, swatch_col + i * #GLYPH, swatch_hl,
      }
    end
  end
  return full, marks
end

---@param repo Repo
local function render_cs_list(repo)
  cs_rows = rows_for(repo)
  hl_seq = 0

  local buf, win = cs_pane.buf, cs_pane.win
  local width = vim.api.nvim_win_get_width(win)
  local lines, marks = {}, {}
  for i, row in ipairs(cs_rows) do
    local text, row_marks = build_cs_row(i - 1, row, width)
    lines[i] = text
    vim.list_extend(marks, row_marks)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_win_set_hl_ns(win, ns)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], {
      end_col = mark[3], hl_group = mark[4], priority = mark[5] or 0,
    })
  end
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

---@param buf integer
---@param win integer
local function render_repo_list(buf, win)
  repo_rows = vim.tbl_values(data.repos())
  table.sort(repo_rows, function(a, b) return a.stars > b.stars end)

  local width = vim.api.nvim_win_get_width(win)
  local lines = {}
  for i, repo in ipairs(repo_rows) do
    local stars = "★ " .. repo.stars
    local name = truncate(repo.name, width - vim.fn.strdisplaywidth(stars) - 1)
    local pad = (" "):rep(math.max(0,
      width - vim.fn.strdisplaywidth(name) - vim.fn.strdisplaywidth(stars)))
    lines[i] = name .. pad .. stars
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

---@param repo_buf integer
---@param repo_win integer
---@param cs_buf integer
---@param cs_win integer
function M.setup(repo_buf, repo_win, cs_buf, cs_win)
  repo_pane = { buf = repo_buf, win = repo_win }
  cs_pane = { buf = cs_buf, win = cs_win }
  prev_repo = nil -- fresh panel: force the colorscheme list to re-render

  render_repo_list(repo_buf, repo_win)
  vim.api.nvim_set_current_win(repo_win)
end

--- Re-render the colorscheme list when the selected repo changes.
function M.sync()
  local repo = M.current_repo()
  if repo == prev_repo then return end
  prev_repo = repo
  cs_rows = {}
  if repo then render_cs_list(repo) end
end

return M
