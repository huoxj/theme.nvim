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

local colorschemes = data.colorschemes()
local colorscheme_names = vim.tbl_keys(colorschemes)

local ns = vim.api.nvim_create_namespace("theme_ui_list")
local hl_seq, hl_cache = 0, {}

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

---@param row0 integer
---@param name string
---@param width integer
---@param hlgs HighlightGroups
local function build_row(row0, name, width, hlgs)
  local max_name_len = math.max(0, width - SWATCH_W - 1)
  local cs_name = name
  if cs_name:len() > max_name_len then
    cs_name = cs_name:sub(1, math.max(0, max_name_len - 3)) .. "..."
  end
  local spaces = (" "):rep(math.max(0, width - #cs_name - SWATCH_W))
  local text = cs_name .. spaces .. SWATCH_TEXT

  local marks = {}
  -- Name and spaces
  local row = hl_for(name .. "|row", hlgs.Normal)
  if row then
    marks[1] = { row0, 0, #cs_name + #spaces, row, 0 }
  end

  local swatch_col = #cs_name + #spaces
  for i, candidate_keys in ipairs(SWATCH) do
    local color = pick(hlgs, candidate_keys)
    if color then
      marks[#marks + 1] = {
        row0,
        swatch_col + (i - 1) * #(GLYPH),
        swatch_col + i * #(GLYPH),
        hl_for(name .. "|sw" .. i, color),
      }
    end
  end
  return text, marks
end

---@param buf integer
---@param win integer
function M.setup_cs_list(buf, win)
  local width = vim.api.nvim_win_get_width(win)
  table.sort(colorscheme_names)

  local lines, marks = {}, {}
  for i, name in ipairs(colorscheme_names) do
    local text, row_marks = build_row(
      i - 1, name, width, colorschemes[name]
    )
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
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.api.nvim_set_current_win(win)

end

function M.get_cursor_colorscheme(win)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local cs_name = colorscheme_names[row]
  return cs_name, colorschemes[cs_name]
end


return M
