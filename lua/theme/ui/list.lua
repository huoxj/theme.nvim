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

local repo_rows, cs_rows = {}, {}
local repo_pane, cs_pane -- {buf, win}

---@type Repo?
local prev_repo

local ns = vim.api.nvim_create_namespace("theme_ui_list")
local hl_seq = 0

local function under_cursor(rows, win)
  return rows[vim.api.nvim_win_get_cursor(win)[1]]
end

---@return Repo?
function M.current_repo() return under_cursor(repo_rows, repo_pane.win) end
---@return Colorscheme?
function M.current_cs() return under_cursor(cs_rows, cs_pane.win) end

local function hl_for(attrs)
  if not (attrs and (attrs.fg or attrs.bg)) then return nil end
  hl_seq = hl_seq + 1
  local name = "ThemeUIList" .. hl_seq
  vim.api.nvim_set_hl(ns, name, attrs)
  return name
end

-- Seek first highlight group with fg or bg from SWATCH candidate keys
---@param hls HighlightGroups
---@param candidate_keys string[]
---@return HighlightGroup?
local function pick(hls, candidate_keys)
  for _, key in ipairs(candidate_keys) do
    return hls[key]
  end
  return nil
end

---@param row0 integer
---@param cs Colorscheme
---@param width integer
---@param bg "light"|"dark"
---@return string, integer[][]
local function build_cs_row(
  row0, cs, width, bg
)
  local bg_icon = bg == "light" and "" or ""
  local text = bg_icon .. " " .. cs.name

  local max_width = width - SWATCH_W - 1
  if #text > max_width then
    text = text:sub(1, max_width - 2) .. ".."
  end

  local pad = (" "):rep(math.max(0, width - #text - SWATCH_W))
  local full = text .. pad .. SWATCH_TEXT

  local marks = {}
  -- Name and spaces
  local row = hl_for(cs.hlgs[bg].Normal)
  if row then
    marks[#marks+1] = { row0, 0, #text + #pad, row, 0 }
  end

  local swatch_col = #text + #pad
  for i, candidate_keys in ipairs(SWATCH) do
    local color = pick(cs.hlgs[bg], candidate_keys)
    if color then
      marks[#marks + 1] = {
        row0,
        swatch_col + (i - 1) * #(GLYPH),
        swatch_col + i * #(GLYPH),
        hl_for(color),
      }
    end
  end
  return full, marks
end

---@param repo Repo
local function render_cs_list(repo)
  -- 1. update rows of Colorschemes to render
  local rows = vim.tbl_values(repo.colorschemes)
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  cs_rows = {}
  -- split "both" colorschemes into two rows. but this implement is not ideal
  -- TODO: consider using a better way to render "both" colorschemes
  for _, cs in ipairs(rows) do
    if cs.bg_type == "both" then
      local cs_dark, cs_light = vim.deepcopy(cs), vim.deepcopy(cs)
      cs_dark.bg_type, cs_light.bg_type = "dark", "light"
      table.insert(cs_rows, cs_dark)
      table.insert(cs_rows, cs_light)
    else
      table.insert(cs_rows, cs)
    end
  end

  -- 2. calculate line texts and extmarks
  hl_seq = 0
  local buf, win = cs_pane.buf, cs_pane.win
  local width = vim.api.nvim_win_get_width(win)

  local lines, marks = {}, {}
  for i, r in ipairs(cs_rows) do
    assert(r.bg_type ~= "both")
    local text, row_marks = build_cs_row(i - 1, r, width, r.bg_type)
    lines[i] = text
    vim.list_extend(marks, row_marks)
  end

  -- 3. render with lines and marks
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

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

local function setup_repo_list(buf, win)
  local rows = vim.tbl_values(data.get_repos())
  local width = vim.api.nvim_win_get_width(win)
  local lines = {}
  -- Sort repos by stars.
  -- TODO: add more sorting options
  table.sort(rows, function(a, b)
    return a.stars > b.stars
  end)
  repo_rows = rows

  for i, repo in ipairs(repo_rows) do
    local stars_text = "★ " .. repo.stars
    local name_text = repo.name
    if #name_text + #stars_text > width then
      name_text = name_text:sub(1, width - #stars_text - 3) .. ".."
    end
    local pad = (" "):rep(math.max(0, width - #name_text - #stars_text))
    lines[i] = name_text .. pad .. stars_text
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

function M.setup_list(repo_buf, repo_win, cs_buf, cs_win)
  repo_pane = {buf = repo_buf, win = repo_win}
  cs_pane = {buf = cs_buf, win = cs_win}

  setup_repo_list(repo_buf, repo_win)

  vim.api.nvim_set_current_win(repo_win)
end

function M.sync()
  local repo = M.current_repo()
  if repo == prev_repo then return end
  prev_repo = repo
  cs_rows = {}
  if repo then render_cs_list(repo) end
end

return M
