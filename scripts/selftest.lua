-- Integration self-test for the hl.json refactor (headless nvim)
vim.opt.runtimepath:prepend("/tmp/theme-refactor/theme.nvim")
local data = require("theme.data")

local fails = 0
local function check(name, cond, extra)
  if cond then
    print("PASS " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (extra and (": " .. tostring(extra)) or ""))
  end
end

-- 1. load & shape
local repos = data.repos()
check("repos loaded", #repos > 0, #repos)
check("repos have meta fields",
  repos[1].name and type(repos[1].stars) == "number"
  and type(repos[1].description) == "string" and repos[1].num_colorschemes)

-- 2. dual colorscheme retrievable on BOTH backgrounds (the original bug)
local dual_name = nil
for _, r in ipairs(repos) do
  for _, cs in ipairs(r.colorschemes) do
    if cs.bg_type == "both" then dual_name = cs.name break end
  end
  if dual_name then break end
end
check("found a dual colorscheme", dual_name ~= nil)
local dual_dark = dual_name and data.query_hl(dual_name, "dark")
local dual_light = dual_name and data.query_hl(dual_name, "light")
local function normal_bg(hl) return hl and hl.Normal and hl.Normal.bg or nil end
check("dual: dark query hits", dual_dark ~= nil)
check("dual: light query hits", dual_light ~= nil)
check("dual: dark bg is dark", normal_bg(dual_dark) and normal_bg(dual_dark) < 128,
  normal_bg(dual_dark))
check("dual: light bg is light", normal_bg(dual_light) and normal_bg(dual_light) > 128,
  normal_bg(dual_light))
check("dual: dark != light (no clobber)", normal_bg(dual_dark) ~= normal_bg(dual_light))

-- 3. attrs passthrough: scan whole dataset
local saw_bold, saw_reverse, saw_italic, n_hlgs = false, false, false, 0
for _, r in ipairs(repos) do
  for _, cs in ipairs(r.colorschemes) do
    for _, key in ipairs({ "hlgs_light", "hlgs_dark" }) do
      for _, hlg in ipairs(cs[key] or {}) do
        if hlg and hlg ~= vim.NIL then
          n_hlgs = n_hlgs + 1
          if hlg.bold then saw_bold = true end
          if hlg.reverse then saw_reverse = true end
          if hlg.italic then saw_italic = true end
          if hlg.cterm or hlg.ctermfg or hlg.ctermbg then
            check("no terminal attrs leaked", false, vim.inspect(hlg))
            return
          end
        end
      end
    end
  end
end
check("non-null hlg entries present", n_hlgs > 0, n_hlgs)
check("bold attrs present in dataset", saw_bold)
check("italic attrs present in dataset", saw_italic)
check("reverse attrs present in dataset", saw_reverse)

-- 4. query_repo roundtrip
local some_repo = repos[1]
local some_cs = some_repo.colorschemes[1]
check("query_repo", data.query_repo(some_cs.name) == some_repo.name,
  data.query_repo(some_cs.name) .. " vs " .. some_repo.name)

-- 5. ui row model: repo rows -> expand -> bg filters -> swatches
local ui_list = require("theme.ui.cs_list")
local buf = vim.api.nvim_create_buf(false, true)
-- capture the LIST window handle (cs_list renders/cursors operate on it)
local lwin = vim.api.nvim_open_win(buf, false, {
  relative = "editor", row = 0, col = 0, width = 60, height = 30,
})
ui_list.setup_cs_list(buf, lwin)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("list rendered repo rows only", #lines == #repos, #lines .. " vs " .. #repos)
check("first row is a repo", lines[1]:find("▸ ") ~= nil, lines[1]:sub(1, 40))

-- expand the repo that owns the dual
local dual_repo_name = nil
for _, r in ipairs(repos) do
  for _, cs in ipairs(r.colorschemes) do
    if cs.name == dual_name and cs.bg_type == "both" then
      dual_repo_name = r.name
    end
  end
end
local dual_repo_row = nil
for i, l in ipairs(lines) do
  if l:find(dual_repo_name, 1, true) then dual_repo_row = i break end
end
check("dual repo row visible", dual_repo_row ~= nil, dual_repo_name)
vim.api.nvim_win_set_cursor(lwin, { dual_repo_row, 0 })
ui_list.toggle_expand(lwin, buf)
local expanded_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("expand adds cs rows", #expanded_lines > #lines, #expanded_lines)

local dual_row = nil
for i, l in ipairs(expanded_lines) do
  if l:find(dual_name, 1, true) then dual_row = i break end
end
check("dual cs row visible after expand", dual_row ~= nil)
if dual_row then
  vim.api.nvim_win_set_cursor(lwin, { dual_row, 0 })
  local kind, _, cs = ui_list.get_cursor_entry(lwin)
  check("cursor entry is cs", kind == "cs" and cs ~= nil and cs.name == dual_name,
    kind .. " " .. tostring(cs and cs.name))
  local ns = vim.api.nvim_create_namespace("theme_ui_list")
  local marks = vim.api.nvim_buf_get_extmarks(
    buf, ns, { dual_row - 1, 0 }, { dual_row - 1, -1 }, {})
  check("swatch marks present on cs row", #marks >= 3, #marks)
end

-- also expand tokyonight (has a light-only cs) so bg filters can differ
vim.api.nvim_win_set_cursor(lwin, { 1, 0 })
ui_list.toggle_expand(lwin, buf)
local expanded_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- bg filter cycle changes row count
ui_list.cycle_bg_filter(lwin, buf)
local dark_rows = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
ui_list.cycle_bg_filter(lwin, buf)
local light_rows = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
ui_list.cycle_bg_filter(lwin, buf)
local both_rows = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("both filter == expanded rows", both_rows == #expanded_lines,
  both_rows .. " vs " .. #expanded_lines)
check("dark filter < both", dark_rows < both_rows, dark_rows)
check("light filter != dark", light_rows ~= dark_rows, light_rows)

print(fails == 0 and "ALL TESTS PASSED" or (fails .. " TESTS FAILED"))
os.exit(fails == 0 and 0 or 1)
