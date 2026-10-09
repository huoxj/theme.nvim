local M = {}

local ui_preview = require("theme.ui.preview")
local ui_list = require("theme.ui.list")

local ORDER = { "repo_list", "cs_list", "info", "preview" }
local active = nil

local function sections()
  local w = math.floor(vim.o.columns * 0.8)
  local h = math.floor(vim.o.lines * 0.8)
  local row0 = math.floor((vim.o.lines - h) / 2)
  local col0 = math.floor((vim.o.columns - w) / 2)
  local w20, w40, w60 = math.floor(w * 0.2), math.floor(w * 0.4), math.floor(w * 0.6)
  local h70 = math.floor(h * 0.7)
  return {
    repo_list = {
      rect = {
        row = row0, col = col0,
        width = w20, height = h70,
      },
      win_conf = {
        border = "rounded"
      }
    },
    cs_list = {
      rect = {
        row = row0 + h70 + 1, col = col0,
        width = w20, height = h - h70 - 3,
      },
      win_conf = {
        border = "rounded"
      }
    },
    info = {
      rect = {
        row = row0, col = col0 + w20 + 1,
        width = w40, height = h - 2,
      },
      win_conf = {
        zindex = 41,
        border = "rounded"
      }
    },
    preview = {
      rect = {
        row = row0, col = col0 + w60 + 2,
        width = w - w60 - 2, height = h - 2
      },
      win_conf = {
        border = "rounded"
      }
    },
    tabs = {
      rect = {
        row = row0 + 2, col = col0,
        width = w, height = 1
      },
      win_conf = {
        focusable = false,
      }
    },
    frame = {
      rect = {
        row = row0 - 1, col = col0 - 1,
        width = w + 2, height = h + 2
      },
      win_conf = {
        focusable = false, zindex = 39,
        title = " theme ", title_pos = "center",
        border = "rounded"
      }
    },
    backdrop = {
      rect = {
        row = 0, col = 0,
        width = vim.o.columns, height = vim.o.lines
      },
      win_conf = {
        zindex = 38, focusable = false
      },
      win_opts = {
        winblend = 60, winhighlight = "Normal:ThemeUIBackdrop"
      }
    }
  }
end

---@param buf integer
---@param r table
---@param win_conf vim.api.keyset.win_config
local function open_win(buf, r, win_conf)
  local win = vim.api.nvim_open_win(
    buf, false,
    vim.tbl_extend("force", {
      relative = "editor",
      row = r.row, col = r.col,
      width = r.width, height = r.height,
      style = "minimal", border = "none", zindex = 40,
    }, win_conf or {})
  )
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  return win
end

--- Focus on next/prev window in the ui panel
---@param wins table<string, integer>
---@param step integer
local function focus_win(wins, step)
  local cur = vim.api.nvim_get_current_win()
  local idx = 1
  for i, name in ipairs(ORDER) do
    if wins[name] == cur then idx = i end
  end
  local next = wins[ORDER[(idx - 1 + step) % #ORDER + 1]]
  if next and vim.api.nvim_win_is_valid(next) then
    vim.api.nvim_set_current_win(next)
  end
end

-- Setup keymappings for ui panel
local function map_keys(p)
  local function close_keymap(buf, key)
    vim.keymap.set(
      "n", key,
      function() M.close(p) end,
      { buffer = buf })
  end
  local function focus_keymap(buf, key, step)
    vim.keymap.set(
      "n", key,
      function() focus_win(p.wins, step) end,
      { buffer = buf })
    end
  for _, buf in pairs(p.bufs) do
    close_keymap(buf, "<Esc>")
    close_keymap(buf, "q")
    focus_keymap(buf, "<Tab>", 1)
    focus_keymap(buf, "<S-Tab>", -1)
  end
end

function M.open()
  if active and not active.closed then
    if vim.api.nvim_win_is_valid(active.wins.repo_list) then
      vim.api.nvim_set_current_win(active.wins.repo_list)
    end
    return
  end
  local p = {
    wins = {}, bufs = {},
    origin_win = vim.api.nvim_get_current_win(),
  }

  local secs = sections()
  for k, v in pairs(secs) do
    local buf = vim.api.nvim_create_buf(false, true)
    p.bufs[k] = buf
    vim.bo[buf].bufhidden = "wipe"
    p.wins[k] = open_win(buf, v.rect, v.win_conf)
    for opt, val in pairs(v.win_opts or {}) do
      vim.wo[p.wins[k]][opt] = val
    end
  end

  -- Setup list section
  ui_list.setup_list(
    p.bufs.repo_list, p.wins.repo_list,
    p.bufs.cs_list, p.wins.cs_list
  )
  -- Setup preview section
  ui_preview.setup_preview(
    p.bufs.preview, p.wins.preview
  )

  -- Misc
  map_keys(p)


  local aug = vim.api.nvim_create_augroup("ThemeUI", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(e)
      if p.closed then return end
      for _, w in pairs(p.wins) do
        if e.match == tostring(w) then
          M.close(p)
          return
        end
      end
    end
  })

  for _, name in ipairs({ "repo_list", "cs_list" }) do
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = p.bufs[name],
      callback = function()
        ui_list.sync()
        local cs = ui_list.current_cs()
        if cs then
          ui_preview.update_preview_hl(
            p.wins.preview, cs
          )
        end
      end
    })
  end

  active = p
end

function M.close(p)
  if not p or p.closed then return end
  p.closed = true
  pcall(vim.api.nvim_del_augroup_by_name, "ThemeUI")
  for _, w in pairs(p.wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if vim.api.nvim_win_is_valid(p.origin_win) then
    vim.api.nvim_set_current_win(p.origin_win)
  end
end

return M

