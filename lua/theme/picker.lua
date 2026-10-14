-- Telescope picker over every theme on runtimepath (R2a).
local M = {}

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config")
local previewers = require("telescope.previewers")

local pool = require("theme.pool")
local data = require("theme.data")
local cs = require("theme.colorscheme")
local preview = require("theme.preview")

local function entry_maker(name)
  local current = name == cs.current()
  return {
    value = name,
    display = current and (name .. "  (current)") or name,
    ordinal = name,
  }
end

---@param opts? table
function M.pick(opts)
  local names = pool.all_themes()
  table.sort(names)
  if #names == 0 then
    return vim.notify("theme: no themes found", vim.log.levels.WARN)
  end

  pickers.new(opts or {
    layout_config = { preview_width = 0.7, preview_cutoff = 30 },
  }, {
    prompt_title = "Themes (" .. #names .. ")",
    finder = finders.new_table({ results = names, entry_maker = entry_maker }),
    sorter = conf.values.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Preview",
      define_preview = function(self, entry)
        preview.fill(self.state.bufnr)
        preview.tint(self.state.winid, data.query_hl(entry.value, "dark"))
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local name = action_state.get_selected_entry().value
        actions.close(prompt_bufnr)
        cs.apply(name)
      end)
      return true
    end,
  }):find()
end

return M
