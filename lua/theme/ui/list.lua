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

-- Install-state chip on a repo row: ours (installed by the panel), elsewhere
-- (provided by the user's own config), shadow (both). "none" renders blank.
local CHIP = { ours = "\u{2713}", elsewhere = "\u{2261}", shadow = "\u{26A0}" }
local CHIP_HL = { ours = "ThemeUIOurs", elsewhere = "ThemeUIElsewhere",
  shadow = "ThemeUIWarn" }
local CHIP_W = 2 -- glyph + separator space; reserved even when there is no chip

--- A theme in theme.nvim's own pack dir, as the Managed view shows it. `repo`
--- is the dataset record when the dataset knows a repo of that directory name;
--- a theme we only have on disk carries `repo = nil`.
---@class ManagedItem
---@field name string shown name: "owner/repo", or the directory name
---@field dir string absolute path of our clone
---@field repo Repo? dataset record, nil for a theme only on disk

---@type Repo[]?
local repos
---@type ManagedItem[]?
local managed_items
--- The repo (Browse) or managed item (Managed) the colorscheme pane describes.
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

--- The colorscheme rows for whatever the repos pane has selected, in either
--- view.
---@param item Repo|ManagedItem
---@return { name: string, bg: string, hlgs: HighlightGroups? }[]
function M.cs_rows_of(item)
  if harvested(item) then return M.cs_rows(item) end
  return M.cs_rows_managed(item)
end

--- Whether the dataset carries a README for this repo. Harvests made before the
--- readme field existed simply have none.
---@param repo Repo
---@return boolean
function M.has_readme(repo)
  return repo.readme ~= nil and repo.readme ~= ""
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

--- "  folke/tokyonight.nvim  ★ 8213" -- same row as the Browse view without
--- the install chip: everything in this view is ours by construction. Themes
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

--- "  nothing installed yet — press b for Browse": the Managed view before
--- anything has been installed.
---@param width integer
---@return table[]
function M.build_empty(width)
  local ln = render.line()
  ln:text("  nothing installed yet \u{2014} press b for Browse", "ThemeUIDim")
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

--- The repo preview: the README verbatim (raw markdown, the window wraps
--- it), or the wrapped description when the dataset has no readme for the
--- repo.
---@param repo Repo
---@param width integer
---@param height integer
---@return table[]
function M.build_readme(repo, width, height)
  local out = {}
  if M.has_readme(repo) then
    local text = repo.readme:gsub("\r\n", "\n")
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = render.markdown_line(line, "ThemeUICode")
    end
    -- A trailing newline should not become a trailing blank row.
    if #out > 0 and out[#out]:str() == "" then out[#out] = nil end
  else
    local wrapped = render.wrap(repo.description or "", math.max(1, width - 3),
      math.max(1, height - 2))
    for _, line in ipairs(wrapped) do
      out[#out + 1] =
        render.line():text("  "):text(line, "ThemeUIDim"):pad(width)
    end
  end
  return out
end

--- The preview body for the selected item: the dataset README (or the wrapped
--- description) when the dataset knows the theme, otherwise what our own clone
--- tells us -- where it lives and which colorschemes it ships. With nothing
--- selected (an empty Managed view) it is the empty-state note.
---@param item Repo|ManagedItem?
---@param width integer
---@param height integer
---@return table[]
function M.build_preview(item, width, height)
  if not item then return M.build_empty(width) end
  if harvested(item) then return M.build_readme(item, width, height) end

  local out = {}
  ---@param text string
  ---@param group string?
  local function line(text, group)
    out[#out + 1] = render.line():text("  "):text(text, group):pad(width)
  end
  line(item.dir, "ThemeUIDim")
  line("")
  for _, name in ipairs(clone_colorschemes(item.dir)) do
    line(name, "ThemeUIName")
  end
  return out
end

--- Whether the preview window should wrap for this item. Only dataset READMEs
--- are prose; a path and a list of names read better clipped.
---@param item Repo|ManagedItem?
---@return boolean
function M.preview_wraps(item)
  return item ~= nil and harvested(item) and M.has_readme(item)
end

--- The bottom bar, padded to `width`. The management keys are contextual: the
--- Managed view holds nothing to install, so it drops `i`. On a narrow panel
--- the bar is truncated with an ellipsis rather than clipped mid-word.
---@param width integer
---@param view "browse"|"managed"?
---@return table[]
function M.build_hint(width, view)
  local text = " Tab: List  [/]: View  "
    .. (view == "managed" and "" or "i: Install  ")
    .. "x: Remove  u: Update  q: Quit"
  local ln = render.line()
  ln:text(render.fit(text, width))
  ln:pad(width)
  return { ln }
end

return M
