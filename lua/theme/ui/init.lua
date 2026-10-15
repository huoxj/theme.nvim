-- The :Theme panel: a centered float of three bordered panes (Repos,
-- Colorschemes, Preview) over a dimmed backdrop, plus an unbordered hint bar.
--
-- The preview follows the focused list's selection: the repo list shows that
-- repo's README, the colorscheme list shows the sample code tinted with the
-- selected variant. The preview itself is a read-only document, reached with
-- its own number key rather than by cycling.
local M = {}

local render = require("theme.ui.render")
local list = require("theme.ui.list")
local chrome = require("theme.ui.chrome")
local preview = require("theme.preview")

local B = 1             -- border cost per side of a bordered float
local GAP_X = 1         -- blank columns between the left column and the preview
local MIN_PREVIEW_W = 24
-- Tab and S-Tab only ever move between the two LISTS: the preview is a
-- document, not a stop on the focus ring.
local LIST_PANES = { 1, 2 }
-- The pane number shown in each border title, and the key that jumps to it.
local PANE_NUM = { "1", "2", "0" }
local PANE_TITLE = { "Repos", "Colorschemes", "Preview" }

local active = nil

--------------------------------------------------------------------- geometry
---@param min_left_w integer content width the widest list row needs
---@return table<string, { row: integer, col: integer, width: integer,
---  height: integer }>
function M.layout(min_left_w)
  local GW, GH = vim.o.columns, vim.o.lines - vim.o.cmdheight

  -- Centered panel, 80% x 80% of the editor.
  local panel_w = math.min(GW, math.max(24, math.floor(GW * 0.8)))
  local panel_h = math.min(GH, math.max(10, math.floor(GH * 0.8)))
  local panel_row = math.floor((GH - panel_h) / 2)
  local panel_col = math.floor((GW - panel_w) / 2)

  -- The hint bar takes the bottom row INSIDE the panel, so the panes get
  -- the rest.
  local panes_h = math.max(6, panel_h - 1)

  -- Left column: 40% of the panel (4:6 with the preview). It never grows
  -- beyond its widest row (borders included), but on small panels it may
  -- shrink up to 10 columns below that: names then truncate with an ellipsis
  -- (render.fit) instead of the lists starving the preview.
  local left_floor = math.max(12, min_left_w - 10) + 2 * B
  local left_w = math.max(left_floor, math.floor(panel_w * 0.4))
  local max_left = panel_w - GAP_X - 4 * B - MIN_PREVIEW_W
  if left_w > max_left then left_w = math.max(2 * B + 4, max_left) end

  -- 2:1 split of the left column, minus the four border rows that split costs.
  local usable = math.max(2, panes_h - 4 * B)
  local cs_h = math.max(1, math.floor(usable / 3))
  local repos_h = math.max(1, usable - cs_h)

  -- A bordered float's (row, col) IS its box's top-left corner, and its
  -- width/height describe the content only, so the box is (width + 2) x
  -- (height + 2) and no conversion is needed here.
  local left_box_r = panel_col + left_w - 1
  local prev_box_l = left_box_r + 1 + GAP_X
  local prev_box_r = panel_col + panel_w - 1

  return {
    panel = { row = panel_row, col = panel_col,
              width = panel_w, height = panel_h },
    backdrop = { row = 0, col = 0, width = GW, height = GH },
    repos = { row = panel_row, col = panel_col,
              width = left_w - 2 * B, height = repos_h },
    cs = { row = panel_row + repos_h + 2 * B, col = panel_col,
           width = left_w - 2 * B, height = cs_h },
    preview = { row = panel_row, col = prev_box_l,
                width = math.max(4, prev_box_r - prev_box_l + 1 - 2 * B),
                height = math.max(1, panes_h - 2 * B) },
    hint = { row = panel_row + panel_h - 1, col = panel_col,
             width = panel_w, height = 1 },
  }
end

----------------------------------------------------------------------- focus
---@param state table
function M.apply_focus(state)
  for i, pane in ipairs(state.panes) do
    if vim.api.nvim_win_is_valid(pane.win) then
      vim.wo[pane.win].winhighlight =
        chrome.winhl(pane.kind, i == state.focus, state.preview_tinted)
    end
  end
end

--- The preview always describes the FOCUSED LIST's current selection, so moving
--- between the two lists with Tab is enough to refresh it.
---
--- Focusing the preview itself is deliberately NOT a context change: it is read
--- mode. Its content stays whatever the last list selection put there, and j/k
--- then scroll that document instead of moving a selection.
---@param state table
function M.follow(state)
  local pane = state.panes[state.focus]
  if pane and (pane.kind == "repos" or pane.kind == "cs") then
    M.sync_preview(state, pane.kind)
  end
end

---@param state table
---@param i integer
function M.focus(state, i)
  state.focus = ((i - 1) % #state.panes) + 1
  local pane = state.panes[state.focus]
  if vim.api.nvim_win_is_valid(pane.win) then
    -- state.focus is already updated, so the WinEnter handler sees no
    -- change and does not repeat the work.
    vim.api.nvim_set_current_win(pane.win)
  end
  M.apply_focus(state)
  M.follow(state)
end

--- Tab / S-Tab: walk the two list panes. `dir` is kept so the two call
--- sites read as forward/backward, but with two panes both directions
--- reach the other one.
---@param state table
---@param dir integer
function M.focus_list(state, dir)
  local at = 1
  for i, p in ipairs(LIST_PANES) do
    if p == state.focus then at = i end
  end
  local n = #LIST_PANES
  M.focus(state, LIST_PANES[((at - 1 + dir) % n) + 1])
end

--- Number keys: jump straight to a pane (lazygit-style pane picker).
---@param state table
---@param n integer
function M.focus_num(state, n)
  if n >= 1 and n <= #state.panes then M.focus(state, n) end
end

--------------------------------------------------------------------- preview
---@param state table
---@param src "repos"|"cs"?
function M.sync_preview(state, src)
  local pane = state.panes[3]
  if src then state.preview_src = src end
  if not vim.api.nvim_win_is_valid(pane.win) then return end

  local sel = state.panes[state.preview_src == "repos" and 1 or 2].sel
  local key = state.preview_src .. ":" .. tostring(sel)
  if state.preview_key == key then return end
  state.preview_key = key

  local title
  if state.preview_src == "repos" then
    local repo = list.repos()[state.panes[1].sel]
    state.preview_tinted = false
    -- Raw markdown reads badly clipped, so the readme window wraps; the code
    -- sample below stays unwrapped, where clipping a long line is the
    -- right thing.
    vim.wo[pane.win].wrap = list.has_readme(repo)
    -- Drop the lua highlighter the colorscheme view installed, or it would
    -- color the markdown as if it were code.
    pcall(vim.treesitter.stop, pane.buf)
    render.render_lines(pane, list.build_readme(repo, pane.width, pane.height))
    title = " [0] " .. repo.name .. " "
  else
    local row = state.panes[2].items[state.panes[2].sel]
    state.preview_tinted = true
    vim.wo[pane.win].wrap = false
    preview.fill(pane.buf)
    preview.tint(pane.win, row.hlgs, chrome.frame())
    title = " [0] " .. row.name .. " "
  end

  vim.api.nvim_win_set_config(pane.win, { title = title, title_pos = "center" })
  vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
  M.apply_focus(state)
end

--------------------------------------------------------------------- actions
--- Re-render the colorscheme pane for `repo`, unless it is already showing it.
---@param state table
---@param repo Repo
local function render_cs(state, repo)
  if not list.sync(repo) then return end
  render.render(state.panes[2], list.cs_rows(repo), 1, list.build_cs)
end

---@param state table
---@param delta integer
function M.move(state, delta)
  local pane = state.panes[state.focus]
  if not pane then return end

  if pane.kind == "preview" then -- the preview is a document, not a list
    local last = vim.api.nvim_buf_line_count(pane.buf)
    local row = vim.api.nvim_win_get_cursor(pane.win)[1]
    vim.api.nvim_win_set_cursor(pane.win,
      { math.max(1, math.min(last, row + delta)), 0 })
    return
  end

  local n = #pane.items
  if n == 0 then return end
  local sel = ((pane.sel - 1 + delta) % n) + 1
  if sel ~= pane.sel then
    if pane.kind == "repos" then
      render.render(pane, pane.items, sel, list.build_repo)
      render_cs(state, list.repos()[sel])
    else
      render.render(pane, pane.items, sel, list.build_cs)
    end
    M.sync_preview(state, pane.kind)
  end
end

------------------------------------------------------------------- lifecycle
---@param state table
local function map_keys(state)
  ---@param buf integer
  ---@param lhs string
  ---@param fn function
  local function map(buf, lhs, fn)
    vim.keymap.set("n", lhs, fn,
      { buffer = buf, noremap = true, silent = true, nowait = true })
  end
  for _, pane in ipairs(state.panes) do
    map(pane.buf, "<Tab>", function() M.focus_list(state, 1) end)
    map(pane.buf, "<S-Tab>", function() M.focus_list(state, -1) end)
    for i = 1, #PANE_NUM do
      map(pane.buf, PANE_NUM[i], function() M.focus_num(state, i) end)
    end
    map(pane.buf, "j", function() M.move(state, 1) end)
    map(pane.buf, "<Down>", function() M.move(state, 1) end)
    map(pane.buf, "k", function() M.move(state, -1) end)
    map(pane.buf, "<Up>", function() M.move(state, -1) end)
    map(pane.buf, "q", function() M.close(state) end)
    map(pane.buf, "<Esc>", function() M.close(state) end)
  end
end

---@return table
function M.open()
  if active and vim.api.nvim_win_is_valid(active.panes[1].win) then
    M.focus(active, 1)
    return active
  end

  chrome.apply()
  local geo = M.layout(list.min_left_width())
  local state = {
    closed = false, focus = 1, panes = {}, geo = geo,
    preview_src = "repos", preview_tinted = false, preview_key = nil,
    origin = vim.api.nvim_get_current_win(),
  }

  -- Backdrop first: it sits behind everything and dims the editor behind
  -- the panel.
  local bg = geo.backdrop
  state.backdrop = render.new_pane({
    kind = "backdrop", row = bg.row, col = bg.col, width = bg.width,
    height = bg.height,
    border = "none", focusable = false, zindex = 10, winblend = 60,
  })
  vim.wo[state.backdrop.win].winhighlight =
    "Normal:ThemeUIBackdrop,EndOfBuffer:ThemeUIBackdrop"

  for i, key in ipairs({ "repos", "cs", "preview" }) do
    local g = geo[key]
    state.panes[i] = render.new_pane({
      kind = key, row = g.row, col = g.col, width = g.width, height = g.height,
      -- The title carries the pane's number, so the number keys are
      -- discoverable without reading the hint bar.
      title = " [" .. PANE_NUM[i] .. "] " .. PANE_TITLE[i] .. " ",
    })
  end

  local hg = geo.hint
  state.hint = render.new_pane({
    kind = "hint", row = hg.row, col = hg.col, width = hg.width,
    height = hg.height,
    border = "none", focusable = false, zindex = 60,
  })
  vim.wo[state.hint.win].winhighlight =
    "Normal:ThemeUIHint,EndOfBuffer:ThemeUIHint"
  render.render_lines(state.hint, list.build_hint(hg.width))

  list.reset()
  render.render(state.panes[1], list.repos(), 1, list.build_repo)
  render_cs(state, list.repos()[1])

  map_keys(state)

  state.augroup = vim.api.nvim_create_augroup("ThemeUI", { clear = true })
  -- Keep the border -- and the preview -- in sync if focus arrives from
  -- anywhere else (mouse, C-w): the preview must always describe the
  -- focused pane.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.augroup,
    callback = function()
      if state.closed then return end
      local cur = vim.api.nvim_get_current_win()
      for i, pane in ipairs(state.panes) do
        if pane.win == cur and i ~= state.focus then
          state.focus = i
          M.apply_focus(state)
          M.follow(state)
          return
        end
      end
    end,
  })
  -- Closing any panel window (:q, C-w c, mouse) tears the whole panel down.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(e)
      if state.closed then return end
      for _, win in ipairs({
        state.panes[1].win, state.panes[2].win, state.panes[3].win,
        state.hint.win, state.backdrop.win }) do
        if e.match == tostring(win) then return M.close(state) end
      end
    end,
  })

  active = state
  M.focus(state, 1)
  return state
end

---@param p table?
function M.close(p)
  if not p or p.closed then return end
  p.closed = true
  if p.augroup then pcall(vim.api.nvim_del_augroup_by_id, p.augroup) end
  for _, pane in ipairs(p.panes) do render.close_pane(pane) end
  render.close_pane(p.hint)
  render.close_pane(p.backdrop)
  if vim.api.nvim_win_is_valid(p.origin) then
    vim.api.nvim_set_current_win(p.origin)
  end
  active = nil
end

return M
