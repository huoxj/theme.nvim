-- Panel content: dataset-backed repo and colorscheme rows, the managed-theme
-- rows, the preview bodies, and the hint bar. Row builders return render.Line
-- objects.
local M = {}

local data = require("theme.data")
local render = require("theme.ui.render")
local install = require("theme.install")

-- Highlight groups whose colour is shown as a swatch on each colorscheme row.
local SWATCH_GROUPS = { "Search", "PmenuSel", "Visual", "StatusLine", "Pmenu" }
local LABEL_W = 5 -- widest variant label ("light")

-- Glyphs on the info card, matching the panel's existing icon style.
local REPO_ICON = "\u{f09b}"
local USER_ICON = "\u{f007}"
local STAR = "\u{2605}"
local SECTION = "\u{25B8}"

-- Install-state chip on a repo row: ours (installed by the panel), elsewhere
-- (provided by the user's own config), shadow (both). "none" renders blank.
local CHIP = { ours = "\u{2713}", elsewhere = "\u{2261}", shadow = "\u{26A0}" }
local CHIP_HL = { ours = "ThemeUIOurs", elsewhere = "ThemeUIElsewhere",
  shadow = "ThemeUIWarn" }
local CHIP_W = 2 -- glyph + separator space; reserved even when there is no chip

--- A theme in theme.nvim's own pack dir, as the `managed` filter shows it.
--- `repo` is the dataset record when the dataset knows a repo of that
--- directory name; a theme we only have on disk carries `repo = nil`.
---@class ManagedItem
---@field name string shown name: "owner/repo", or the directory name
---@field dir string absolute path of our clone
---@field repo Repo? dataset record, nil for a theme only on disk

---@type Repo[]?
local repos
---@type ManagedItem[]?
local managed_items
--- The repo or managed item the colorscheme pane describes.
---@type Repo|ManagedItem?
local prev_repo
--- Set when the lists were rebuilt under the panel, forcing the next `sync`
--- to re-render even though the selected item did not change.
local forced = false
--- repo name -> install status, probed once per panel open (and after a job).
---@type table<string, string>?
local statuses

--- Every harvested repo, most-starred first.
---@return Repo[]
function M.repos()
  if not repos then
    repos = vim.tbl_values(data.repos())
    table.sort(repos, function(a, b) return a.stars > b.stars end)
  end
  return repos
end

--- Every theme in theme.nvim's own pack dir. A directory whose name matches a
--- dataset repo is shown under that repo's name -- "owner/repo", which is what
--- the installer was given -- and keeps its stars; a directory the dataset does
--- not know is shown by directory name alone. Scanned once per panel open and
--- again after every job.
---@return ManagedItem[]
function M.managed()
  if not managed_items then
    local by_base = {}
    for _, repo in ipairs(M.repos()) do
      local base = vim.fs.basename(repo.name)
      if not by_base[base] then by_base[base] = repo end
    end
    managed_items = {}
    for _, entry in ipairs(install.installed()) do
      local repo = by_base[entry.name]
      managed_items[#managed_items + 1] = {
        name = repo and repo.name or entry.name,
        dir = entry.dir,
        repo = repo,
      }
    end
  end
  return managed_items
end

--- Colorscheme names a clone ships, read from its own `colors/` directory: the
--- fallback for a theme the dataset has never harvested.
---@param dir string
---@return string[]
local function clone_colorschemes(dir)
  local names = {}
  for name, kind in vim.fs.dir(vim.fs.joinpath(dir, "colors")) do
    if kind == "file" and (name:match("%.vim$") or name:match("%.lua$")) then
      names[#names + 1] = vim.fn.fnamemodify(name, ":t:r")
    end
  end
  table.sort(names)
  return names
end

--- Whether `item` is a dataset record rather than a Managed-view item. Repos
--- always carry their colorscheme table; managed items never do.
---@param item Repo|ManagedItem
---@return boolean
local function harvested(item)
  return item.colorschemes ~= nil
end

--- Install status of every repo, keyed by repo name. Probed once and cached:
--- the filesystem is only re-read after a job or on the next panel open.
---@return table<string, string>
function M.statuses()
  if not statuses then
    statuses = {}
    for _, repo in ipairs(M.repos()) do
      statuses[repo.name] = install.status(repo.name)
    end
  end
  return statuses
end

--- Forget everything derived from the filesystem (install statuses, the pack
--- dir scan) so the next render re-probes. Called after a job and on open.
function M.refresh()
  statuses = nil
  managed_items = nil
end

--- One selectable row per variant; a "both" colorscheme yields two rows (dark
--- then light), so a repo's row count can exceed its colorscheme count.
---@param repo Repo
---@return { name: string, bg: "light"|"dark", hlgs: HighlightGroups? }[]
function M.cs_rows(repo)
  local colorschemes = vim.tbl_values(repo.colorschemes)
  table.sort(colorschemes, function(a, b) return a.name < b.name end)

  ---@param name string
  ---@param bg "light"|"dark"
  local function row(name, bg)
    -- Look the variant up by name: query_hl also covers the "both" case, where
    -- the row's background picks which stored variant is previewed.
    return { name = name, bg = bg, hlgs = data.query_hl(name, bg) }
  end

  local rows = {}
  for _, colorscheme in ipairs(colorschemes) do
    if colorscheme.bg_type == "both" then
      rows[#rows + 1] = row(colorscheme.name, "dark")
      rows[#rows + 1] = row(colorscheme.name, "light")
    else
      rows[#rows + 1] = row(colorscheme.name, colorscheme.bg_type)
    end
  end
  return rows
end

--- Colorscheme rows for a managed item: the dataset's rows when the dataset
--- knows the repo, otherwise one row per colorscheme our clone ships. A clone
--- we have not harvested has no stored highlights, so those rows carry no
--- swatches and no variant label -- showing another repo's colours for a
--- same-named colorscheme would be a guess, not a fact.
---@param item ManagedItem
---@return { name: string, bg: string, hlgs: HighlightGroups? }[]
function M.cs_rows_managed(item)
  if item.repo then return M.cs_rows(item.repo) end
  local rows = {}
  for _, name in ipairs(clone_colorschemes(item.dir)) do
    rows[#rows + 1] = { name = name, bg = "", hlgs = nil }
  end
  return rows
end

--- The colorscheme rows for whatever the repos pane has selected.
---@param item Repo|ManagedItem
---@return { name: string, bg: string, hlgs: HighlightGroups? }[]
function M.cs_rows_of(item)
  if harvested(item) then return M.cs_rows(item) end
  return M.cs_rows_managed(item)
end

--- Fresh panel: forget the last rendered item so the colorscheme list is built
--- again. Without this, reopening with the same first repo selected would keep
--- the previous panel's (empty) colorscheme pane.
function M.reset()
  prev_repo = nil
  forced = false
  M.refresh()
end

--- Force the next `sync` to re-render: the lists were rebuilt (a view toggle,
--- a finished job), so the item the colorscheme pane holds is stale even when
--- the selection reads the same.
function M.forget()
  forced = true
end

--- Re-render the colorscheme list only when the selected item changed.
---@param item Repo|ManagedItem?
---@return boolean changed
function M.sync(item)
  if not forced and item == prev_repo then return false end
  forced = false
  prev_repo = item
  return true
end

--- Content width the left column needs to show its widest row without clipping.
---@return integer
function M.min_left_width()
  local width = 20
  for _, repo in ipairs(M.repos()) do
    width = math.max(width, 2 + vim.api.nvim_strwidth(repo.name) + 1
      + CHIP_W + 2 + #tostring(repo.stars) + 2)
    for name in pairs(repo.colorschemes) do
      width = math.max(width,
        2 + vim.api.nvim_strwidth(name) + 1 + LABEL_W + 2 + #SWATCH_GROUPS + 1)
    end
  end
  -- Managed-only themes have no stars column, but their directory names still
  -- have to fit the row (gutter, name, gap to the pane edge).
  for _, item in ipairs(M.managed()) do
    if not item.repo then
      width = math.max(width, vim.api.nvim_strwidth(item.name) + 3)
    end
  end
  return width
end

--------------------------------------------------------------------- builders
--- "  folke/tokyonight.nvim  ✓   ★ 8213" -- chip and stars right-aligned on
--- the pane edge.
--- Layout: gutter(2) name gap(>=1) chip(2) star(2) digits margin(2).
---@param item Repo
---@param width integer
---@param selected boolean
---@return table[]
function M.build_repo(item, width, selected)
  local stars = tostring(item.stars)
  local right = CHIP_W + 2 + #stars + 2
  local status = M.statuses()[item.name]
  local ln = render.line()
  ln:text(selected and "\u{258C}" or " ", selected and "ThemeUIAccent" or nil)
  ln:text(" ")
  ln:text(render.fit(item.name, width - 2 - right - 1), "ThemeUIName")
  ln:pad(width - right)
  ln:text(CHIP[status] or " ", status and CHIP_HL[status] or nil)
  ln:text(" ")
  ln:text("\u{2605} ", "ThemeUIStar")
  ln:text(stars, "ThemeUIDim")
  ln:text("  ")
  return { ln }
end

--- "  folke/tokyonight.nvim  ★ 8213" -- the dataset row without the install
--- chip: everything the managed filter lists is ours by construction. Themes
--- the dataset does not know have no stars to show.
--- Layout: gutter(2) name gap(>=1) star(2) digits margin(2).
---@param item ManagedItem
---@param width integer
---@param selected boolean
---@return table[]
function M.build_managed(item, width, selected)
  local stars = item.repo and tostring(item.repo.stars) or ""
  local right = stars ~= "" and (#stars + 4) or 0
  local ln = render.line()
  ln:text(selected and "\u{258C}" or " ", selected and "ThemeUIAccent" or nil)
  ln:text(" ")
  ln:text(render.fit(item.name, width - 2 - right - 1), "ThemeUIName")
  ln:pad(width - right)
  if stars ~= "" then
    ln:text("\u{2605} ", "ThemeUIStar")
    ln:text(stars, "ThemeUIDim")
    ln:text("  ")
  end
  return { ln }
end

--- "  nothing installed": the empty state of the repos pane, worded for the
--- filter that produced it.
---@param width integer
---@param filter string?
---@return table[]
function M.build_empty(width, filter)
  local text = filter == "installed" and "nothing installed"
    or filter == "managed" and "nothing installed by theme.nvim"
    or "nothing to show"
  local ln = render.line()
  ln:text("  " .. text, "ThemeUIDim")
  ln:pad(width)
  return { ln }
end

--- "  tokyonight-moon   dark    ∙∙∙∙∙"
--- Row layout: gutter(2) name gap(>=1) label(5) gap(2) swatches(5) margin(1).
---@param item { name: string, bg: "light"|"dark", hlgs: HighlightGroups? }
---@param width integer
---@param selected boolean
---@return table[]
function M.build_cs(item, width, selected)
  local right = LABEL_W + 2 + #SWATCH_GROUPS + 1
  local ln = render.line()
  ln:text(selected and "\u{258C}" or " ", selected and "ThemeUIAccent" or nil)
  ln:text(" ")
  ln:text(render.fit(item.name, width - 2 - right - 1), "ThemeUIName")
  ln:pad(width - right)
  ln:text(string.format("%-" .. LABEL_W .. "s", item.bg), "ThemeUITag")
  ln:text("  ")
  for i = 1, #SWATCH_GROUPS do
    local attrs = item.hlgs and item.hlgs[SWATCH_GROUPS[i]]
    ln:swatch(attrs and (attrs.fg or attrs.bg) and attrs or nil)
  end
  ln:text(" ")
  return { ln }
end

--- The info card: what the preview shows when no live markdown render is
--- available (no markview, a managed theme with no dataset record, or a render
--- failure). Unlike a README, prose is wrapped here and the pane does not wrap.
--- Layout: icon + name, author/stars, description, then the colorschemes.
---@param item Repo|ManagedItem
---@param width integer
---@param height integer
---@return table[]
function M.build_info(item, width, height)
  local repo = item.repo
  if not repo and harvested(item) then repo = item end

  local out = {}
  ---@param ln table
  local function emit(ln)
    out[#out + 1] = ln:pad(width)
  end

  local title = repo and repo.name or item.name
  emit(render.line():text("  ")
    :text(render.fit(REPO_ICON .. "  " .. title, width - 2), "ThemeUIBold"))

  if repo then
    local owner = repo.name:match("^([^/]+)/") or repo.name
    local stars = tostring(repo.stars)
    local meta = render.line():text("  ")
    meta:text(USER_ICON .. " ", "ThemeUIDim")
    meta:text(render.fit(owner, math.max(1, width - meta.width - 5 - #stars)),
      "ThemeUIName")
    meta:text("   ")
    meta:text(STAR .. " ", "ThemeUIStar")
    meta:text(stars, "ThemeUIDim")
    emit(meta)
    for _, text in ipairs(render.wrap(repo.description or "",
      math.max(1, width - 2))) do
      emit(render.line():text("  "):text(text, "ThemeUIDim"))
    end
  else
    for _, text in ipairs(render.wrap(item.dir, math.max(1, width - 2))) do
      emit(render.line():text("  "):text(text, "ThemeUIDim"))
    end
  end

  emit(render.line())
  emit(render.line():text("  " .. SECTION .. " colorschemes", "ThemeUIAccent"))

  local colors = {}
  if repo then
    colors = vim.tbl_values(repo.colorschemes)
    table.sort(colors, function(a, b) return a.name < b.name end)
  else
    for _, name in ipairs(clone_colorschemes(item.dir)) do
      colors[#colors + 1] = { name = name }
    end
  end
  for _, color in ipairs(colors) do
    local ln = render.line():text("  ")
    local label = color.bg_type
    if label and label ~= "" then
      ln:text(render.fit(color.name, math.max(1, width - ln.width - 2 - #label)),
        "ThemeUIName")
      ln:text("  ")
      ln:text(label, "ThemeUITag")
    else
      ln:text(render.fit(color.name, math.max(1, width - ln.width)),
        "ThemeUIName")
    end
    emit(ln)
  end
  return out
end

--- The bottom bar, padded to `width`. `ctx.kind` is the focused pane
--- ("repos", "cs" or "preview"); `ctx.status` is the selected repo's install
--- status and `ctx.installed` says whether the colorscheme list's repo is
--- available. On a narrow panel the bar is truncated with an ellipsis rather
--- than clipped mid-word.
---@param width integer
---@param ctx { kind: string, status?: string, installed?: boolean }
---@return table[]
function M.build_hint(width, ctx)
  local segs
  if ctx.kind == "repos" then
    segs = { "f: filter", "s: sort" }
    if ctx.status == "none" then
      segs[#segs + 1] = "i: install"
    elseif ctx.status then
      segs[#segs + 1] = "x: remove"
      segs[#segs + 1] = "u: update"
    end
    segs[#segs + 1] = "Enter: view"
  elseif ctx.kind == "cs" then
    segs = { "f: filter", "s: sort",
      ctx.installed and "Enter: switch" or "Enter: install & switch" }
  else
    segs = {}
  end
  segs[#segs + 1] = "q: quit"

  local text = " " .. table.concat(segs, "  ")
  local ln = render.line()
  ln:text(render.fit(text, width))
  ln:pad(width)
  return { ln }
end

return M
