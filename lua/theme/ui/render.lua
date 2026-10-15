-- Generic float-pane plumbing and the hand-drawn row renderer.
local M = {}

-- The swatch glyph and the prefix for the per-render highlight groups that
-- carry a swatch's colors. The glyph is the one theme.nvim's list UI has
-- always used.
local SWATCH_GLYPH = "\u{2219}" -- small bullet, 3 bytes / 1 cell
local SWATCH_PREFIX = "ThemeUISwatch"
local SEL_GROUP = "ThemeUISel"

----------------------------------------------------------------------- Line
-- A Line tracks byte offsets (extmark columns are byte-based) and display
-- width (padding is cell-based) separately, because the glyphs used here --
-- star, bar, block -- are one cell wide but three bytes long in UTF-8.
local Line = {}
Line.__index = Line

---@return table
function M.line()
  return setmetatable(
    { parts = {}, segs = {}, swatches = {}, bytes = 0, width = 0 }, Line)
end

---@param s string
---@param group string?
---@return table
function Line:text(s, group)
  if s == "" then return self end
  local b0 = self.bytes
  self.parts[#self.parts + 1] = s
  self.bytes = b0 + #s
  self.width = self.width + vim.api.nvim_strwidth(s)
  if group then
    self.segs[#self.segs + 1] =
      { start = b0, finish = self.bytes, group = group }
  end
  return self
end

--- A swatch carries one highlight group's stored attributes; the painter
--- turns it into a two-color chip: the glyph in the group's fg, on the
--- group's bg.
---@param attrs HighlightGroup?
---@return table
function Line:swatch(attrs)
  local b0 = self.bytes
  self:text(SWATCH_GLYPH)
  self.swatches[#self.swatches + 1] =
    { start = b0, finish = self.bytes, attrs = attrs }
  return self
end

--- Pad the row out to `target` display cells, so the full-row selection extmark
--- has real characters to cover.
---@param target integer
---@return table
function Line:pad(target)
  local d = target - self.width
  if d > 0 then self:text(string.rep(" ", d)) end
  return self
end

---@return string
function Line:str()
  return table.concat(self.parts)
end

----------------------------------------------------------------------- text
--- Truncate `s` to at most `maxw` display cells, marking the cut with an
--- ellipsis.
---@param s string
---@param maxw integer
---@return string
function M.fit(s, maxw)
  if maxw <= 0 then return "" end
  if vim.api.nvim_strwidth(s) <= maxw then return s end
  local out, w = "", 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local cw = vim.api.nvim_strwidth(ch)
    if w + cw > maxw - 1 then break end
    out, w = out .. ch, w + cw
  end
  return out .. "\u{2026}"
end

--- One line of raw markdown, with `inline code` runs dimmed. Deliberately not a
--- markdown renderer: every syntax character stays on screen.
---@param s string
---@param code_group string
---@return table
function M.markdown_line(s, code_group)
  local ln = M.line()
  local i = 1
  while true do
    local a, b = s:find("`[^`]*`", i)
    if not a then break end
    if a > i then ln:text(s:sub(i, a - 1)) end
    ln:text(s:sub(a, b), code_group)
    i = b + 1
  end
  if i <= #s then ln:text(s:sub(i)) end
  return ln
end

--- Greedy word wrap to `width` display cells, optionally capped at `max_lines`
--- (the last kept line then ends in an ellipsis).
---@param s string
---@param width integer
---@param max_lines integer?
---@return string[]
function M.wrap(s, width, max_lines)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    if line == "" then
      line = word
    elseif vim.api.nvim_strwidth(line) + 1 + vim.api.nvim_strwidth(word)
      <= width then
      line = line .. " " .. word
    else
      out[#out + 1], line = line, word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  if max_lines and #out > max_lines then
    for i = #out, max_lines + 1, -1 do out[i] = nil end
    out[max_lines] =
      M.fit(out[max_lines], math.max(1, width - 2)) .. " \u{2026}"
  end
  return out
end

----------------------------------------------------------------------- panes
---@class ThemeUIPane
---@field kind string
---@field buf integer
---@field win integer
---@field width integer
---@field height integer
---@field ns integer
---@field items table[]
---@field sel integer?
---@field rowmap table<integer, { first: integer, last: integer }>
---@field swatch_marks { row: integer, group: string, attrs HighlightGroup? }[]

---@param spec { kind: string, row: integer, col: integer, width: integer,
---  height: integer, title?: string, border?: string, focusable?: boolean,
---  zindex?: integer, winblend?: integer }
---@return ThemeUIPane
function M.new_pane(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local cfg = {
    relative = "editor", row = spec.row, col = spec.col,
    width = spec.width, height = spec.height, style = "minimal",
    focusable = spec.focusable ~= false, zindex = spec.zindex or 50,
  }
  if spec.border == "none" then
    cfg.border = "none"
  else
    cfg.border = spec.border or "rounded"
    cfg.title = spec.title
    cfg.title_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, false, cfg)
  vim.wo[win].wrap = false
  -- Blank past the end of the buffer instead of "~", and blank nvim's "the
  -- last line does not fit" marker: without the second one the readme
  -- preview ends in a row of "@@@" whenever the panel is shorter than the
  -- document.
  vim.wo[win].fillchars = "eob: ,lastline: "
  if spec.winblend then vim.wo[win].winblend = spec.winblend end

  return {
    kind = spec.kind, buf = buf, win = win,
    width = spec.width, height = spec.height,
    -- Window-local namespace: each pane owns its extmarks and can clear
    -- only its own without disturbing anything else.
    ns = vim.api.nvim_create_namespace("theme_ui:win:" .. win),
    items = {}, sel = nil, rowmap = {}, swatch_marks = {},
  }
end

--- Paint a flat list of Line objects into `pane`. `sel` is an optional
--- {first, last} pair of 0-based row indices covered by the hand-drawn bar.
---@param pane ThemeUIPane
---@param flat table[]
---@param sel integer[]?
local function paint(pane, flat, sel)
  local lines = {}
  for i, ln in ipairs(flat) do lines[i] = ln:str() end

  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, pane.ns, 0, -1)

  -- Swatch colors are defined FRESH on every render, in the pane's own
  -- highlight namespace, under a counter-based name:
  --   * the group lives in the same namespace the window is pointed at, so
  --     it is resolved by the window that draws it and cannot fall back to a
  --     global group of the same name,
  --   * the attributes are the dataset's stored fg and bg, so the chip is a
  --     real two-color sample rather than a single flat color, and
  --   * minting new names each time avoids a stale definition being reused
  --     after a different colorscheme row is selected.
  local seq = 0
  local function hl_for(attrs)
    if not (attrs and (attrs.fg or attrs.bg)) then return nil end
    seq = seq + 1
    local name = SWATCH_PREFIX .. seq
    vim.api.nvim_set_hl(pane.ns, name, attrs)
    return name
  end

  -- The selection is drawn by hand as a full-row background extmark;
  -- cursorline is deliberately left off (it does not render underneath a
  -- full-row extmark bg).
  if sel then
    vim.api.nvim_buf_set_extmark(pane.buf, pane.ns, sel[1], 0, {
      end_row = sel[2],
      end_col = #lines[sel[2] + 1],
      hl_group = SEL_GROUP,
      hl_eol = true,
      priority = 200,
    })
  end

  pane.swatch_marks = {}
  for i, ln in ipairs(flat) do
    local row = i - 1
    -- Colored runs are extmarks above the bar, so on the selected row they must
    -- carry the bar's background themselves -- hence the "*Sel" twin groups.
    local selected = sel and row >= sel[1] and row <= sel[2]
    local function put(s, group)
      vim.api.nvim_buf_set_extmark(pane.buf, pane.ns, row, s.start, {
        end_row = row, end_col = s.finish, hl_group = group, priority = 300,
      })
    end
    -- A swatch keeps its own attributes even on the selected row: the chip
    -- brings both fg and bg, so the row's bar background only shows around it.
    for _, s in ipairs(ln.swatches) do
      local group = hl_for(s.attrs)
      if group then
        put(s, group)
        pane.swatch_marks[#pane.swatch_marks + 1] = {
          row = row, group = group, attrs = s.attrs,
        }
      end
    end
    for _, s in ipairs(ln.segs) do
      put(s, selected and (s.group .. "Sel") or s.group)
    end
  end

  -- Point the window at its own namespace, so the groups just defined are
  -- the ones its redraw resolves. Groups the namespace does not define
  -- (ThemeUISel, ThemeUIName, ...) still fall back to the global table.
  vim.api.nvim_win_set_hl_ns(pane.win, pane.ns)
end

--- Render `items` into `pane`. `build(item, width, selected, height)` returns a
--- list of Line objects. `sel` is nil for panes without a selection.
---@param pane ThemeUIPane
---@param items table[]
---@param sel integer?
---@param build fun(item: table, width: integer, selected: boolean,
---  height: integer): table[]
---@return table<integer, { first: integer, last: integer }>
function M.render(pane, items, sel, build)
  local flat, rowmap = {}, {}
  for i, item in ipairs(items) do
    local ls = build(item, pane.width, i == sel, pane.height)
    rowmap[i] = { first = #flat, last = #flat + #ls - 1 }
    for _, ln in ipairs(ls) do flat[#flat + 1] = ln end
  end

  local r = sel and rowmap[sel]
  paint(pane, flat, r and { r.first, r.last })

  pane.items, pane.sel, pane.rowmap = items, sel, rowmap
  if r and vim.api.nvim_win_is_valid(pane.win) then
    -- nvim scrolls the window to keep the cursor visible, so a selection that
    -- walks past the bottom of a short pane still shows.
    vim.api.nvim_win_set_cursor(pane.win, { r.first + 1, 0 })
  end
  return rowmap
end

--- Render a fixed block of lines with no selection (preview, hint bar).
---@param pane ThemeUIPane
---@param lines table[]
function M.render_lines(pane, lines)
  paint(pane, lines, nil)
  pane.items, pane.sel, pane.rowmap = {}, nil, {}
end

---@param pane ThemeUIPane
function M.close_pane(pane)
  if vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_win_close(pane.win, true)
  end
end

return M
