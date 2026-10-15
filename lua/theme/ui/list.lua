-- Panel content: dataset-backed repo and colorscheme rows, the repo preview
-- body, and the hint bar. Row builders return render.Line objects.
local M = {}

local data = require("theme.data")
local render = require("theme.ui.render")

-- Highlight groups whose colour is shown as a swatch on each colorscheme row.
local SWATCH_GROUPS = { "Search", "PmenuSel", "Visual", "StatusLine", "Pmenu" }
local LABEL_W = 5 -- widest variant label ("light")

---@type Repo[]?
local repos
--- Repo whose colorscheme rows are currently rendered.
---@type Repo?
local prev_repo

--- Every harvested repo, most-starred first.
---@return Repo[]
function M.repos()
  if not repos then
    repos = vim.tbl_values(data.repos())
    table.sort(repos, function(a, b) return a.stars > b.stars end)
  end
  return repos
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

--- Whether the dataset carries a README for this repo. Harvests made before the
--- readme field existed simply have none.
---@param repo Repo
---@return boolean
function M.has_readme(repo)
  return repo.readme ~= nil and repo.readme ~= ""
end

--- Fresh panel: forget the last rendered repo so the colorscheme list is built
--- again. Without this, reopening with the same first repo selected would keep
--- the previous panel's (empty) colorscheme pane.
function M.reset()
  prev_repo = nil
end

--- Re-render the colorscheme list only when the selected repo changed.
---@param repo Repo?
---@return boolean changed
function M.sync(repo)
  if repo == prev_repo then return false end
  prev_repo = repo
  return true
end

--- Content width the left column needs to show its widest row without clipping.
---@return integer
function M.min_left_width()
  local width = 20
  for _, repo in ipairs(M.repos()) do
    width = math.max(width,
      2 + vim.api.nvim_strwidth(repo.name) + 1 + 2 + #tostring(repo.stars) + 2)
    for name in pairs(repo.colorschemes) do
      width = math.max(width,
        2 + vim.api.nvim_strwidth(name) + 1 + LABEL_W + 2 + #SWATCH_GROUPS + 1)
    end
  end
  return width
end

--------------------------------------------------------------------- builders
--- "  folke/tokyonight.nvim        ★ 8213" -- stars right-aligned on the
--- pane edge.
--- Row layout: gutter(2) name gap(>=1) "★ "(2) digits margin(2).
---@param item Repo
---@param width integer
---@param selected boolean
---@return table[]
function M.build_repo(item, width, selected)
  local stars = tostring(item.stars)
  local right = 2 + #stars + 2
  local ln = render.line()
  ln:text(selected and "\u{258C}" or " ", selected and "ThemeUIAccent" or nil)
  ln:text(" ")
  ln:text(render.fit(item.name, width - 2 - right - 1), "ThemeUIName")
  ln:pad(width - right)
  ln:text("\u{2605} ", "ThemeUIStar")
  ln:text(stars, "ThemeUIDim")
  ln:text("  ")
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

--- " Tab: Switch list  j/k: Move  q/Esc: Quit", padded to the bar width.
---@param width integer
---@return table[]
function M.build_hint(width)
  local ln = render.line()
  ln:text(" Tab: Switch list  j/k: Move  q/Esc: Quit")
  ln:pad(width)
  return { ln }
end

return M
