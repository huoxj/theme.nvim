-- Panel chrome: the highlight groups and window-highlight mappings the panel
-- paints itself with. The palette is derived from the user's active colorscheme
-- so the panel blends into the current editor; the preview pane is the only
-- surface that borrows another theme's colors.
local M = {}

-- Used when the active colorscheme leaves a group undefined (a bare `-u NONE`
-- session, for instance), so the panel never renders as an unreadable void.
local FALLBACK = {
  fg = 0xc0caf5, bg = 0x1a1b26, sel = 0x292e42,
  accent = 0x7aa2f7, dim = 0x565f89, border = 0x3b4261, hint = 0x1f2335,
}

-- Foreground-only runs that sit inside the selection bar.
local SEGMENTS = { "ThemeUIName", "ThemeUIStar", "ThemeUIDim",
  "ThemeUITag", "ThemeUIAccent" }

---@param name string
---@return vim.api.keyset.highlight
local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

--- Define every chrome group from the active colorscheme. Idempotent, and cheap
--- enough to run on each open so a colorscheme change is picked up.
function M.apply()
  local normal = hl("Normal")
  local accent = hl("Title").fg or hl("WinSeparator").fg or FALLBACK.accent
  local dim = hl("LineNr").fg or hl("NonText").fg or FALLBACK.dim
  local border = hl("NonText").fg or hl("LineNr").fg or FALLBACK.border
  -- CursorLine rather than Visual/PmenuSel: those two are already swatch
  -- chips, so reusing them would make a swatch vanish on the selected row.
  local sel = hl("CursorLine").bg or hl("Visual").bg or FALLBACK.sel
  local status = hl("StatusLine")
  local hint_bg = status.bg or hl("Pmenu").bg or FALLBACK.hint
  local pane_fg = normal.fg or FALLBACK.fg
  local pane_bg = normal.bg or FALLBACK.bg

  local set = vim.api.nvim_set_hl
  set(0, "ThemeUIPane", { fg = pane_fg, bg = pane_bg })
  set(0, "ThemeUIBorderFocus", { fg = accent, bold = true })
  set(0, "ThemeUIBorderDim", { fg = border })
  set(0, "ThemeUITitleFocus", { fg = accent, bold = true })
  set(0, "ThemeUITitleDim", { fg = border })
  set(0, "ThemeUISel", { bg = sel })
  set(0, "ThemeUIName", { fg = pane_fg })
  set(0, "ThemeUIStar", { fg = accent })
  set(0, "ThemeUIDim", { fg = dim })
  set(0, "ThemeUITag", { fg = dim })
  set(0, "ThemeUIAccent", { fg = accent })
  set(0, "ThemeUICode", { fg = accent })
  set(0, "ThemeUIBackdrop", { bg = pane_bg })
  set(0, "ThemeUIHint", { fg = status.fg or pane_fg, bg = hint_bg })

  -- "*Sel" twins carry the selection bg as well as the fg. The colored runs are
  -- extmarks with a higher priority than the selection bar, so without this the
  -- selected row would show unhighlighted holes under every colored run.
  for _, g in ipairs(SEGMENTS) do
    set(0, g .. "Sel", {
      fg = vim.api.nvim_get_hl(0, { name = g }).fg, bg = sel
    })
  end

  -- Swatch groups are NOT defined here: they are minted per render inside each
  -- pane's own highlight namespace, with the dataset's stored attributes (see
  -- render.lua paint()).
end

--- The border/title groups restated for a TINTED window's namespace: without
--- them the frame cells fall through onto the previewed theme's Normal
--- background and the title stops matching the other panes.
---@return table<string, vim.api.keyset.highlight>
function M.frame()
  return {
    ThemeUIBorderFocus = hl("ThemeUIBorderFocus"),
    ThemeUIBorderDim = hl("ThemeUIBorderDim"),
    ThemeUITitleFocus = hl("ThemeUITitleFocus"),
    ThemeUITitleDim = hl("ThemeUITitleDim"),
  }
end

--- The `winhighlight` value for one pane. The focused pane gets the accent
--- border/title, the others the dim pair, so a focus change visibly repaints
--- all three frames.
---@param kind string
---@param focused boolean
---@param tinted boolean whether the preview is showing a tinted colorscheme
---@return string
function M.winhl(kind, focused, tinted)
  local s = "FloatBorder:"
    .. (focused and "ThemeUIBorderFocus" or "ThemeUIBorderDim")
    .. ",FloatTitle:" .. (focused and "ThemeUITitleFocus" or "ThemeUITitleDim")
  if kind == "preview" then
    -- A tinted preview's body colors come from the previewed theme, resolved
    -- through the window's own highlight namespace, so Normal stays unmapped.
    if not tinted then
      s = s .. ",Normal:ThemeUIPane,EndOfBuffer:ThemeUIPane"
    end
  else
    s = s .. ",Normal:ThemeUIPane,EndOfBuffer:ThemeUIPane,Cursor:ThemeUISel"
  end
  return s
end

return M
