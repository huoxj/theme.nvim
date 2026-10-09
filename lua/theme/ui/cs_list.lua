local M = {}

local data = require("theme.data")

local SWATCH = {
  { "Search" },
  { "PmenuSel" },
  { "Visual" },
  { "StatusLine" },
  { "Pmenu" },
}
-- Use super small circle character as swatch
local SWATCH_W = #SWATCH
local GLYPH = "∙"
local SWATCH_TEXT = GLYPH:rep(SWATCH_W)

local ns = vim.api.nvim_create_namespace("theme_ui_list")
local hl_seq, hl_cache = 0, {}

-- background filter for colorschemes: "both" shows every colorscheme,
-- "light"/"dark" only ones supporting that background
local bg_filter = "both"
-- repo.name -> expanded?
local expanded = {}
-- Flat row model, rebuilt on any filter/expand change:
-- { kind = "repo"|"cs", repo = Repo, cs = Colorscheme? }
local rows = {}

local function hl_for(key, attrs)
  if not (attrs and (attrs.fg or attrs.bg)) then return nil end
  if hl_cache[key] then return hl_cache[key] end
  hl_seq = hl_seq + 1
  hl_cache[key] = "ThemeUIList" .. hl_seq
  vim.api.nvim_set_hl(ns, hl_cache[key], attrs)
  return hl_cache[key]
end

-- Seek first highlight group with fg or bg from SWATCH candidate keys
---@param hls HighlightGroups
---@param candidate_keys string[]
---@return HighlightGroup?
local function pick(hls, candidate_keys)
  for _, key in ipairs(candidate_keys) do
    local hl = hls[key]
    if hl and (hl.fg or hl.bg) then return hl end
  end
  return nil
end

--- Does this colorscheme match the current bg filter?
---@param cs Colorscheme
---@return boolean
local function bg_match(cs)
  return bg_filter == "both" or cs.bg_type == "both" or cs.bg_type == bg_filter
end

--- Rebuild the flat row model from repos + expanded + bg_filter
local function rebuild_rows()
  rows = {}
  for _, repo in ipairs(data.repos()) do
    local shown = 0
    for _, cs in ipairs(repo.colorschemes) do
      if bg_match(cs) then shown = shown + 1 end
    end
    if shown > 0 then
      rows[#rows + 1] = { kind = "repo", repo = repo, count = shown }
      if expanded[repo.name] then
        for _, cs in ipairs(repo.colorschemes) do
          if bg_match(cs) then
            rows[#rows + 1] = { kind = "cs", repo = repo, cs = cs }
          end
        end
      end
    end
  end
end

---@param row0 integer
---@param text string
---@param width integer
---@param hlgs HighlightGroups
---@return string, integer[][]
local function build_row(row0, text, width, hlgs)
  local pad = (" "):rep(math.max(0, width - #text - SWATCH_W))
  local full = text .. pad .. SWATCH_TEXT

  local marks = {}
  -- Name and spaces
  local row = hl_for(text .. "|row", hlgs.Normal)
  if row then
    marks[1] = { row0, 0, #text + #pad, row, 0 }
  end

  local swatch_col = #text + #pad
  for i, candidate_keys in ipairs(SWATCH) do
    local color = pick(hlgs, candidate_keys)
    if color then
      marks[#marks + 1] = {
        row0,
        swatch_col + (i - 1) * #(GLYPH),
        swatch_col + i * #(GLYPH),
        hl_for(text .. "|sw" .. i, color),
      }
    end
  end
  return full, marks
end

--- Colorscheme row: name + swatches from its hlgs for the filtered bg
---@param row0 integer
---@param cs Colorscheme
---@param width integer
---@return string, integer[][]
local function build_cs_row(row0, cs, width)
  local bg = bg_filter == "light" and "light" or "dark"
  local by_key = data.query_hl(cs.name, bg)
  return build_row(row0, cs.name, width, by_key or {})
end

local function render(buf, win)
  local width = vim.api.nvim_win_get_width(win)

  local lines, marks = {}, {}
  for i, r in ipairs(rows) do
    local text, row_marks
    if r.kind == "repo" then
      local arrow = expanded[r.repo.name] and "▾ " or "▸ "
      text, row_marks = build_row(
        i - 1, arrow .. r.repo.name .. " (" .. r.count .. ")",
        width, {}
      )
    else
      text, row_marks = build_cs_row(i - 1, r.cs, width)
    end
    lines[i] = text
    vim.list_extend(marks, row_marks)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_win_set_hl_ns(win, ns)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(
      buf, ns, m[1], m[2], {
        end_col = m[3],
        hl_group = m[4],
        priority = m[5] or 0,
      }
    )
  end
  vim.bo[buf].modifiable = false
end

function M.setup_cs_list(buf, win)
  rebuild_rows()
  render(buf, win)

  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.api.nvim_set_current_win(win)
end

---@return "repo"|"cs" kind
---@return Repo repo
---@return Colorscheme? cs
function M.get_cursor_entry(win)
  local row = rows[vim.api.nvim_win_get_cursor(win)[1]]
  if not row then return "repo", { name = "", colorschemes = {} }, nil end
  return row.kind, row.repo, row.cs
end

function M.toggle_expand(win, buf)
  local kind, repo = M.get_cursor_entry(win)
  if kind ~= "repo" then return end
  expanded[repo.name] = not expanded[repo.name] or nil
  rebuild_rows()
  render(buf, win)
end

function M.cycle_bg_filter(win, buf)
  bg_filter = bg_filter == "both" and "dark"
    or bg_filter == "dark" and "light" or "both"
  rebuild_rows()
  render(buf, win)
  vim.notify("theme: showing " .. bg_filter, vim.log.levels.INFO)
end

--- Current bg filter ("both"|"light"|"dark")
---@return string
function M.bg_filter()
  return bg_filter
end

function M.apply_cursor(win)
  local kind, _, cs = M.get_cursor_entry(win)
  if kind ~= "cs" then return end
  require("theme.utils").apply_colorscheme(cs.name)
end

return M
