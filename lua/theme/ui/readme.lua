-- Live README preview for the repos pane. While a debounced `curl` fetches the
-- selected repo's README from GitHub, the preview shows the dataset
-- description and an npm-style spinner. A fetched README is rendered by
-- markview when it is installed; otherwise (or when rendering fails) the pane
-- shows a static info card. Nothing is cached: every selection change starts
-- over, and a generation counter drops stale responses.
local M = {}

local list = require("theme.ui.list")
local render = require("theme.ui.render")

-- Same candidates, in the same order, as scripts/build_hljson.py.
-- shortcut: they are requested concurrently, so a repo that ships more than one
-- (e.g. README.md and README.rst) shows whichever answers first, not the first
-- in this list.
local NAMES = { "README.md", "README.rst", "README", "readme.md" }
local FRAMES = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}",
  "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }
local FRAME_MS = 90
local DEBOUNCE_MS = 500

-- The rich renderer is optional: markview plus its two markdown parsers must be
-- loadable. Probed once per session.
---@type boolean?
local rich

---@return boolean
local function rich_renderer()
  if rich == nil then
    rich = pcall(require, "markview")
      and pcall(vim.treesitter.language.add, "markdown")
      and pcall(vim.treesitter.language.add, "markdown_inline")
  end
  return rich
end

--- Drop a markview render from `pane`, restoring the options it changed.
---@param pane table
local function unpaint(pane)
  if vim.api.nvim_buf_is_valid(pane.buf) then
    pcall(vim.treesitter.stop, pane.buf)
    if rich then
      pcall(function()
        require("markview").strict_render:clear(pane.buf)
      end)
    end
    if vim.bo[pane.buf].filetype ~= "" then
      vim.bo[pane.buf].filetype = ""
    end
  end
  if vim.api.nvim_win_is_valid(pane.win) then
    vim.wo[pane.win].conceallevel = 0
  end
end

--- Clear the rich render from a pane whose content is about to be replaced by
--- something else (loading lines, info card, colorscheme sample, empty state,
--- panel close).
---@param pane table
function M.clear(pane)
  unpaint(pane)
end

--- Paint the static info card: the item's name, author/stars when the dataset
--- knows it, and its colorschemes. Used when no README can be rendered.
---@param state table
---@param pane table
---@param item Repo|ManagedItem
local function show_info(state, pane, item)
  M.cancel(state)
  if state.closed or not vim.api.nvim_win_is_valid(pane.win) then return end
  unpaint(pane)
  vim.wo[pane.win].wrap = false
  render.render_lines(pane, list.build_info(item, pane.width, pane.height))
end

--- Show `item`'s info card (no fetch, no spinner).
---@param state table
---@param pane table
---@param item Repo|ManagedItem
function M.info(state, pane, item)
  show_info(state, pane, item)
end

---@param timer uv.uv_timer_t?
local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param state table
local function stop_timers(state)
  local timers = state.readme_timers
  if not timers then return end
  stop_timer(timers.debounce)
  stop_timer(timers.spinner)
  state.readme_timers = nil
end

--- Kill every in-flight curl handle and drop the list. A handle whose process
--- already exited must not raise, hence the pcall.
---@param state table
local function kill_procs(state)
  local procs = state.readme_procs
  if not procs then return end
  state.readme_procs = nil
  for _, proc in pairs(procs) do
    pcall(proc.kill, proc)
  end
end

--- Bump the generation, stop every timer, and kill the in-flight fetches:
--- whatever is in flight, including a scheduled paint or a curl callback, is
--- now stale.
---@param state table
---@return integer generation
function M.cancel(state)
  state.readme_gen = (state.readme_gen or 0) + 1
  stop_timers(state)
  kill_procs(state)
  return state.readme_gen
end

--- Write `text` into the pane as plain markdown lines and render it with
--- markview. The buffer's own marks are dropped first; the rendered README
--- draws its styling with extmarks, so the text itself stays raw.
---@param state table
---@param pane table
---@param text string
---@param item Repo|ManagedItem
local function paint_readme(state, pane, text, item)
  unpaint(pane)

  local lines = {}
  for line in ((text or ""):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end

  vim.bo[pane.buf].filetype = "markdown"
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, pane.ns, 0, -1)
  vim.wo[pane.win].wrap = true

  -- strict_render bypasses markview's nofile-buffer auto-attach filter; the
  -- draw_range covering the whole buffer makes it render at once, not just the
  -- viewport.
  local ok = pcall(function()
    require("markview").strict_render:render(pane.buf, #lines + 1, {
      preview = { draw_range = { #lines + 1, #lines + 1 } },
      html = { enable = true },
    })
  end)
  if not ok then show_info(state, pane, item) end
end

---@param state table
---@param pane table
---@param item Repo|ManagedItem
---@param repo Repo
---@param gen integer
local function fetch(state, pane, item, repo, gen)
  local base = ("https://raw.githubusercontent.com/%s/%s/")
    :format(repo.name, repo.default_branch)

  local procs = {}
  state.readme_procs = procs
  local finished = {}
  local pending = #NAMES
  local done = false

  local function fallback()
    state.readme_procs = nil
    stop_timers(state)
    if not vim.api.nvim_win_is_valid(pane.win) then return end
    unpaint(pane)
    vim.wo[pane.win].wrap = false
    render.render_lines(pane, list.build_info(item, pane.width, pane.height))
  end

  -- First success wins: paint it and abandon the candidates still running.
  local function succeed(stdout)
    done = true
    state.readme_procs = nil
    for j = 1, #NAMES do
      local proc = procs[j]
      if proc and not finished[j] then pcall(proc.kill, proc) end
    end
    stop_timers(state)
    if not vim.api.nvim_win_is_valid(pane.win) then return end
    paint_readme(state, pane, stdout, item)
  end

  for i = 1, #NAMES do
    local cmd = { "curl", "-fsSL", "--max-time", "15", base .. NAMES[i] }
    -- A missing curl makes vim.system raise; that is a total failure too.
    local ok, proc = pcall(vim.system, cmd, { text = true }, function(res)
      vim.schedule(function()
        if state.closed or state.readme_gen ~= gen or done then return end
        finished[i] = true
        -- A 200 with an empty file is not a README: treat it as a miss.
        if res.code == 0 and (res.stdout or ""):match("%S") then
          succeed(res.stdout or "")
        else
          pending = pending - 1
          if pending == 0 then fallback() end
        end
      end)
    end)
    if ok then
      procs[i] = proc
    else
      finished[i] = true
      pending = pending - 1
    end
  end
  if pending == 0 then fallback() end
end

--- Show `item`'s live README: description + spinner now, the fetched markdown
--- after the debounce. `repo` is the dataset record to fetch from. Without the
--- rich renderer there is nothing to fetch for, so the info card shows instead.
---@param state table
---@param pane table
---@param item Repo|ManagedItem
---@param repo Repo
function M.start(state, pane, item, repo)
  if not rich_renderer() then return M.info(state, pane, item) end

  local gen = M.cancel(state)
  if state.closed or not vim.api.nvim_win_is_valid(pane.win) then return end

  unpaint(pane)
  vim.wo[pane.win].wrap = false
  state.readme_timers = {}

  local frame = 1
  local function paint()
    if state.closed or state.readme_gen ~= gen then return end
    if not vim.api.nvim_win_is_valid(pane.win) then return end
    local desc = render.fit(repo.description or "", pane.width)
    render.render_lines(pane, {
      render.line():text(desc, "ThemeUIDim"):pad(pane.width),
      render.line():text(("%s loading readme"):format(FRAMES[frame]),
        "ThemeUIDim"):pad(pane.width),
    })
    frame = frame % #FRAMES + 1
  end
  paint()

  local spinner = vim.uv.new_timer()
  state.readme_timers.spinner = spinner
  spinner:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(paint))

  local debounce = vim.uv.new_timer()
  state.readme_timers.debounce = debounce
  debounce:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if debounce:is_closing() then return end
    debounce:close()
    if state.closed or state.readme_gen ~= gen then return end
    fetch(state, pane, item, repo, gen)
  end))
end

return M
