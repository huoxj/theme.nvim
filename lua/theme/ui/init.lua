-- The :Theme panel: a centered float of three bordered panes (Repos,
-- Colorschemes, Preview) over a dimmed backdrop, plus an unbordered hint bar.
--
-- The preview follows the focused list's selection: the repo list shows that
-- repo's README, the colorscheme list shows the sample code tinted with the
-- selected variant. The preview itself is a read-only document; Tab cycles
-- through all three panes, and focusing the preview never changes its content.
local M = {}

local render = require("theme.ui.render")
local list = require("theme.ui.list")
local readme = require("theme.ui.readme")
local chrome = require("theme.ui.chrome")
local preview = require("theme.preview")
local install = require("theme.install")
local cs = require("theme.colorscheme")

local B = 1             -- border cost per side of a bordered float
local GAP_X = 1         -- blank columns between the left column and the preview
local MIN_PREVIEW_W = 24
-- The pane number shown in each border title, and the key that jumps to it.
local PANE_NUM = { "1", "2", "3" }
-- The fixed names the two lists and the preview carry.
local PANE_TITLE = { [1] = "Repos", [2] = "Colorschemes", [3] = "Preview" }
-- Repo filter and sort cycles; the colorscheme list has its own filter and a
-- single sort.
local REPO_FILTERS = { "all", "installed", "managed" }
local REPO_SORTS = { "stars", "name", "owner" }
local CS_FILTERS = { "all", "light", "dark" }

local active = nil

---@param i integer
---@return string
local function pane_title(i)
  return (" [%s] %s "):format(PANE_NUM[i], PANE_TITLE[i])
end

--- The next value in a cycle.
---@param value string
---@param values string[]
---@return string
local function cycle(value, values)
  local at = 1
  for i, v in ipairs(values) do
    if v == value then at = i end
  end
  return values[((at - 1 + 1) % #values) + 1]
end

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
-- Rebuilt on every apply_focus; defined below with the state helpers it reads.
local refresh_hint

---@param state table
function M.apply_focus(state)
  for i, pane in ipairs(state.panes) do
    if vim.api.nvim_win_is_valid(pane.win) then
      vim.wo[pane.win].winhighlight =
        chrome.winhl(pane.kind, i == state.focus, state.preview_tinted)
    end
  end
  refresh_hint(state)
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

--- Tab / S-Tab: move to the next or previous pane, wrapping around. Focusing
--- the preview is read mode; M.focus only refreshes it for list panes.
---@param state table
---@param delta integer
function M.cycle_focus(state, delta)
  M.focus(state, state.focus + delta)
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

  --- Nothing to describe (a filter with no rows): say so, untinted.
  local function empty()
    readme.cancel(state)
    state.preview_tinted = false
    vim.wo[pane.win].wrap = false
    pcall(vim.treesitter.stop, pane.buf)
    render.render_lines(pane, list.build_empty(pane.width,
      state.preview_src == "repos" and state.filter or state.filter_cs))
    return " [3] Preview "
  end

  local title
  if state.preview_src == "repos" then
    local item = state.panes[1].items[state.panes[1].sel]
    if not item then
      title = empty()
    else
      state.preview_tinted = false
      -- Drop the lua highlighter the colorscheme view installed, or it would
      -- color the markdown as if it were code.
      pcall(vim.treesitter.stop, pane.buf)
      -- The dataset record behind this row: a dataset repo is itself, a
      -- managed item delegates to `repo` (nil for a theme only on disk).
      local repo = item
      if item.dir then repo = item.repo end
      if repo then
        -- A live README: description + spinner now, fetched text after the
        -- debounce. Raw markdown wraps.
        readme.start(state, pane, item, repo)
      else
        -- A theme only on disk has no repo to fetch from: keep the clone
        -- description (path + shipped colorschemes).
        readme.cancel(state)
        vim.wo[pane.win].wrap = list.preview_wraps(item)
        render.render_lines(pane,
          list.build_preview(item, pane.width, pane.height))
      end
      title = " [3] " .. item.name .. " "
    end
  else
    local row = state.panes[2].items[state.panes[2].sel]
    if not row then
      title = empty()
    else
      readme.cancel(state)
      state.preview_tinted = true
      vim.wo[pane.win].wrap = false
      preview.fill(pane.buf)
      preview.tint(pane.win, row.hlgs, chrome.frame())
      title = " [3] " .. row.name .. " "
    end
  end

  vim.api.nvim_win_set_config(pane.win, { title = title, title_pos = "center" })
  vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
  M.apply_focus(state)
end

--------------------------------------------------------------------- actions
--- "owner/name" split into its two sort keys. A name without `/` sorts as an
--- empty owner and itself as the name.
---@param name string
---@return string owner
---@return string base
local function split_repo(name)
  local slash = name:find("/", 1, true)
  if not slash then return "", name end
  return name:sub(1, slash - 1), name:sub(slash + 1)
end

---@param item Repo|ManagedItem
---@return integer
local function repo_stars(item)
  if item.repo then return item.repo.stars end
  return item.stars or 0
end

---@param mode "stars"|"name"|"owner"
---@return fun(a: Repo|ManagedItem, b: Repo|ManagedItem): boolean
local function repo_sort(mode)
  return function(a, b)
    local ao, an = split_repo(a.name)
    local bo, bn = split_repo(b.name)
    if mode == "name" then
      if an ~= bn then return an < bn end
    elseif mode == "owner" then
      if ao ~= bo then return ao < bo end
      if an ~= bn then return an < bn end
    else
      local as, bs = repo_stars(a), repo_stars(b)
      if as ~= bs then return as > bs end
      if an ~= bn then return an < bn end
    end
    return a.name < b.name
  end
end

--- The rows the repos pane shows: the filter picks the item set and the sort
--- orders it. The cached arrays are copied, never sorted in place.
---@param state table
---@return table[]
local function repo_items(state)
  local items = {}
  if state.filter == "managed" then
    vim.list_extend(items, list.managed())
  elseif state.filter == "installed" then
    local status = list.statuses()
    for _, repo in ipairs(list.repos()) do
      local st = status[repo.name]
      if st and st ~= "none" then items[#items + 1] = repo end
    end
  else
    vim.list_extend(items, list.repos())
  end
  table.sort(items, repo_sort(state.sort_repo))
  return items
end

--- A managed item carries a directory; a dataset repo does not.
---@param item Repo|ManagedItem
---@param width integer
---@param selected boolean
---@return table[]
local function repo_builder(item, width, selected)
  if item.dir then return list.build_managed(item, width, selected) end
  return list.build_repo(item, width, selected)
end

--- The colorscheme rows of `item`, filtered by background and name-sorted.
---@param state table
---@param item Repo|ManagedItem?
---@return { name: string, bg: string, hlgs: HighlightGroups? }[]
local function cs_rows(state, item)
  local rows = item and list.cs_rows_of(item) or {}
  if state.filter_cs ~= "all" then
    rows = vim.tbl_filter(function(row) return row.bg == state.filter_cs end, rows)
  end
  table.sort(rows, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.bg < b.bg
  end)
  return rows
end

--- Re-render the colorscheme pane for `item`, unless it is already showing it.
--- `keep_sel` forces a rebuild that clamps the current selection to the new
--- row count instead of resetting to the first row.
---@param state table
---@param item Repo|ManagedItem?
---@param keep_sel boolean?
local function render_cs(state, item, keep_sel)
  local pane = state.panes[2]
  local changed = list.sync(item)
  if not changed and not keep_sel then return end
  local rows = cs_rows(state, item)
  local sel = 1
  if keep_sel then sel = math.max(1, math.min(pane.sel or 1, #rows)) end
  render.render(pane, rows, sel, list.build_cs)
end

--- Repaint the repo rows in place: install chips change after a job, and a job
--- can move a repo into or out of the current filter.
---@param state table
---@param items table[]?
local function render_repos(state, items)
  local pane = state.panes[1]
  items = items or repo_items(state)
  if #items == 0 then
    render.render_lines(pane, list.build_empty(pane.width, state.filter))
    return
  end
  pane.sel = math.min(pane.sel or 1, #items)
  render.render(pane, items, pane.sel, repo_builder)
end

--- The selected item of the repos pane, or nil when the filter yields nothing.
---@param state table
---@return Repo|ManagedItem?
local function selected_item(state)
  return state.panes[1].items[state.panes[1].sel]
end

--- How `item` is currently provided. Dataset rows use the probe cached for
--- their chips; a managed row is scanned live, so a theme whose directory
--- disappeared behind the panel's back cannot be deleted or applied as if it
--- were still ours.
---@param item Repo|ManagedItem
---@return string?
local function item_status(item)
  if item.dir then return install.status(item.name) end
  return list.statuses()[item.name]
end

--- Rebuild the hint bar from what the focused pane currently offers. The
--- colorscheme list describes the repo the repos list has selected.
---@param state table
function refresh_hint(state)
  local kind = state.panes[state.focus].kind
  local ctx = { kind = kind }
  if kind == "repos" then
    local item = selected_item(state)
    ctx.status = item and item_status(item) or nil
  elseif kind == "cs" then
    local item = selected_item(state)
    local status = item and item_status(item) or nil
    ctx.installed = status ~= nil and status ~= "none"
  end
  render.render_lines(state.hint, list.build_hint(state.hint.width, ctx))
end

--- Run one job for `item`, ignoring further keys for it while it runs, and
--- rebuild the lists when it finishes. `after`, when given, runs once the
--- lists are fresh, with the job's outcome.
---@param state table
---@param item Repo|ManagedItem
---@param fn fun(item: table, done: fun(ok: boolean, err: string?))
---@param after fun(ok: boolean, err: string?)?
local function job(state, item, fn, after)
  local name = item.name
  if state.jobs[name] then return end
  state.jobs[name] = true
  fn(item, function(ok, err)
    state.jobs[name] = nil
    if state.closed then return end
    list.refresh()
    list.forget()
    render_repos(state)
    render_cs(state, selected_item(state))
    -- The lists moved under the preview, so redraw it even if the selection
    -- reads the same.
    state.preview_key = nil
    M.sync_preview(state)
    if after then after(ok, err) end
  end)
end

--- Install the selected repo into theme.nvim's own pack dir.
---@param state table
function M.install_repo(state)
  local item = selected_item(state)
  if not item then return end
  local status = item_status(item)
  if status == "elsewhere" then
    return vim.notify(("theme: %s is already provided by your config")
      :format(item.name), vim.log.levels.WARN)
  end
  if status ~= "none" then
    return vim.notify(("theme: %s is already installed here"):format(item.name),
      vim.log.levels.WARN)
  end
  job(state, item, function(r, done) install.install(r.name, done) end)
end

--- Remove theme.nvim's own copy of the selected theme.
---
--- `x` is the only key that deletes anything, so it is gated twice over: the
--- row must be ours (status `ours` or `shadow` -- `shadow` means our copy
--- exists alongside the user's, and removing ours is exactly the resolution),
--- and the status of a managed row is read live. A theme provided only by the
--- user's own config is never touched: this hands a shadowed theme back to
--- them and nothing else.
---@param state table
function M.uninstall_repo(state)
  local item = selected_item(state)
  if not item then return end
  local status = item_status(item)
  if status ~= "ours" and status ~= "shadow" then
    return vim.notify(
      ("theme: %s is not ours \u{2014} nothing was removed"):format(item.name),
      vim.log.levels.WARN)
  end
  job(state, item, function(r, done) install.uninstall(r.name, done) end)
end

--- Re-clone theme.nvim's own copy of the selected theme.
---@param state table
function M.update_repo(state)
  local item = selected_item(state)
  if not item then return end
  -- Updating means re-cloning from the theme's own repo, which we only know
  -- for themes the dataset carries. A clone we cannot place is left alone.
  if item.dir and not item.repo then
    return vim.notify(("theme: %s is not in the theme index \u{2014} update it "
      .. "where you got it"):format(item.name), vim.log.levels.WARN)
  end
  local status = item_status(item)
  if status ~= "ours" and status ~= "shadow" then
    return vim.notify(("theme: %s is not installed here"):format(item.name),
      vim.log.levels.WARN)
  end
  job(state, item, function(r, done) install.update(r.name, done) end)
end

--- Apply the selected colorscheme, installing its theme first when the theme is
--- not already provided. `elsewhere` means the user's own config provides it,
--- so it is on the runtimepath and applies just like our own copy.
---@param state table
function M.apply_cs(state)
  local item = selected_item(state)
  local row = state.panes[2].items[state.panes[2].sel]
  if not item or not row then return end

  local function apply()
    -- The row IS a background variant: applying it without moving
    -- vim.o.background would render the theme's other half. Rows without a
    -- known variant (non-dataset managed rows) keep the current background.
    if row.bg ~= "" and vim.o.background ~= row.bg then
      vim.o.background = row.bg
    end
    cs.apply(row.name)
  end

  local status = item_status(item)
  if status == "none" then
    job(state, item, function(r, done) install.install(r.name, done) end,
      function(ok) if ok then apply() end end)
  elseif status == "ours" or status == "shadow" or status == "elsewhere" then
    apply()
  end
end

--- Show `text` in pane `i`'s border for one second, then restore that pane's
--- normal title. A second trigger cancels the pending timer, so an older
--- restore never overwrites a newer flash.
---@param state table
---@param i integer
---@param text string
local function flash_title(state, i, text)
  local pane = state.panes[i]
  if state.closed or not vim.api.nvim_win_is_valid(pane.win) then return end
  vim.api.nvim_win_set_config(pane.win, {
    title = " " .. text .. " ", title_pos = "center",
  })
  local old = state.title_timers[i]
  if old and not old:is_closing() then
    old:stop()
    old:close()
  end
  local timer = vim.uv.new_timer()
  state.title_timers[i] = timer
  timer:start(1000, 0, vim.schedule_wrap(function()
    if timer:is_closing() then return end
    timer:close()
    if state.title_timers[i] == timer then state.title_timers[i] = nil end
    if state.closed then return end
    if vim.api.nvim_win_is_valid(pane.win) then
      vim.api.nvim_win_set_config(pane.win, {
        title = pane_title(i), title_pos = "center",
      })
    end
  end))
end

--- `f`: all -> installed -> managed. The repos selection resets, and both the
--- colorscheme list and the preview follow the new selection.
---@param state table
function M.cycle_repo_filter(state)
  state.filter = cycle(state.filter, REPO_FILTERS)
  state.panes[1].sel = 1
  list.forget()
  render_repos(state)
  render_cs(state, selected_item(state))
  state.preview_key = nil
  M.sync_preview(state)
  flash_title(state, 1, "filter: " .. state.filter)
end

--- `s`: stars -> name -> owner, keeping the selected item when it survives the
--- reorder and falling back to the first row otherwise.
---@param state table
function M.cycle_repo_sort(state)
  local prev = selected_item(state)
  state.sort_repo = cycle(state.sort_repo, REPO_SORTS)
  local items = repo_items(state)
  local sel = 1
  for i, item in ipairs(items) do
    if item == prev then sel = i break end
  end
  state.panes[1].sel = sel
  render_repos(state, items)
  render_cs(state, selected_item(state))
  state.preview_key = nil
  M.sync_preview(state)
  flash_title(state, 1, "sort: " .. state.sort_repo)
end

--- `f` on the colorscheme list: all -> light -> dark, clamped to the new row
--- count.
---@param state table
function M.cycle_cs_filter(state)
  state.filter_cs = cycle(state.filter_cs, CS_FILTERS)
  render_cs(state, selected_item(state), true)
  state.preview_key = nil
  M.sync_preview(state)
  flash_title(state, 2, "filter: " .. state.filter_cs)
end

--- `s` on the colorscheme list: name ascending, the only sort for now.
---@param state table
function M.sort_cs(state)
  render_cs(state, selected_item(state), true)
  state.preview_key = nil
  M.sync_preview(state)
  flash_title(state, 2, "sort: name")
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
      render.render(pane, pane.items, sel, repo_builder)
      render_cs(state, pane.items[sel])
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
    map(pane.buf, "<Tab>", function() M.cycle_focus(state, 1) end)
    map(pane.buf, "<S-Tab>", function() M.cycle_focus(state, -1) end)
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
  -- Each list filters and sorts itself; the keys live on its own buffer.
  local repos = state.panes[1].buf
  local cs_buf = state.panes[2].buf
  map(repos, "f", function() M.cycle_repo_filter(state) end)
  map(repos, "s", function() M.cycle_repo_sort(state) end)
  map(cs_buf, "f", function() M.cycle_cs_filter(state) end)
  map(cs_buf, "s", function() M.sort_cs(state) end)
  -- Manage keys live on the repo list only. Its `<CR>` moves to the
  -- COLORSCHEME list: applying belongs to a colorscheme, not a repo.
  map(repos, "i", function() M.install_repo(state) end)
  map(repos, "x", function() M.uninstall_repo(state) end)
  map(repos, "u", function() M.update_repo(state) end)
  map(repos, "<CR>", function() M.focus(state, 2) end)
  map(cs_buf, "<CR>", function() M.apply_cs(state) end)
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
    filter = "all", sort_repo = "stars", filter_cs = "all",
    preview_src = "repos", preview_tinted = false, preview_key = nil,
    readme_gen = 0, readme_timers = nil,
    origin = vim.api.nvim_get_current_win(), jobs = {}, title_timers = {},
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
      title = pane_title(i),
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

  list.reset()
  state.panes[1].sel = 1
  render_repos(state)
  render_cs(state, selected_item(state))

  -- A shadowed theme is provided twice; say so once per open and let the user
  -- decide which copy to keep. The panel never adjudicates.
  local shadowed = {}
  for _, repo in ipairs(list.repos()) do
    if list.statuses()[repo.name] == "shadow" then
      shadowed[#shadowed + 1] = repo.name
    end
  end
  if #shadowed > 0 then
    vim.notify("theme: also provided by your config \u{2014} consider "
      .. "uninstalling one copy: " .. table.concat(shadowed, ", "),
      vim.log.levels.WARN)
  end

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
  -- No README fetch, spinner, or title restore may fire after the panel is
  -- gone.
  readme.cancel(p)
  -- No title restore may fire after the panel is gone.
  for _, timer in pairs(p.title_timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
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
