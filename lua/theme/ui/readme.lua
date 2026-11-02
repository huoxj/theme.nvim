-- Live README preview for the repos pane. While a debounced `curl` fetches the
-- selected repo's README from GitHub, the preview shows the dataset
-- description and an npm-style spinner. Nothing is cached: every selection
-- change starts over, and a generation counter drops stale responses.
local M = {}

local list = require("theme.ui.list")
local render = require("theme.ui.render")

-- Same candidates, in the same order, as scripts/build_hljson.py.
local NAMES = { "README.md", "README.rst", "README", "readme.md" }
local FRAMES = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}",
  "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }
local FRAME_MS = 90
local DEBOUNCE_MS = 500

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

--- Bump the generation and stop every timer: whatever is in flight, including
--- a scheduled paint or a curl callback, is now stale.
---@param state table
---@return integer generation
function M.cancel(state)
  state.readme_gen = (state.readme_gen or 0) + 1
  stop_timers(state)
  return state.readme_gen
end

---@param pane table
---@param item Repo|ManagedItem
---@param repo Repo
---@param gen integer
local function fetch(state, pane, item, repo, gen)
  local base = ("https://raw.githubusercontent.com/%s/%s/")
    :format(repo.name, repo.default_branch)

  local function fallback()
    stop_timers(state)
    if not vim.api.nvim_win_is_valid(pane.win) then return end
    vim.wo[pane.win].wrap = list.preview_wraps(item)
    render.render_lines(pane, list.build_preview(item, pane.width, pane.height))
  end

  local function try(i)
    if state.closed or state.readme_gen ~= gen then return end
    if i > #NAMES then return fallback() end
    local cmd = { "curl", "-fsSL", "--max-time", "15", base .. NAMES[i] }
    -- A missing curl makes vim.system raise; that is a total failure too.
    local ok = pcall(vim.system, cmd, { text = true }, function(res)
      vim.schedule(function()
        if state.closed or state.readme_gen ~= gen then return end
        -- A 200 with an empty file is not a README: treat it as a miss.
        if res.code == 0 and (res.stdout or ""):match("%S") then
          stop_timers(state)
          if vim.api.nvim_win_is_valid(pane.win) then
            vim.wo[pane.win].wrap = true
          end
          render.render_lines(pane, list.readme_lines(res.stdout or ""))
        else
          try(i + 1)
        end
      end)
    end)
    if not ok then fallback() end
  end
  try(1)
end

--- Show `item`'s live README: description + spinner now, the fetched text
--- after the debounce. `repo` is the dataset record to fetch from.
---@param state table
---@param pane table
---@param item Repo|ManagedItem
---@param repo Repo
function M.start(state, pane, item, repo)
  local gen = M.cancel(state)
  if state.closed or not vim.api.nvim_win_is_valid(pane.win) then return end

  vim.wo[pane.win].wrap = false
  pcall(vim.treesitter.stop, pane.buf)
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
