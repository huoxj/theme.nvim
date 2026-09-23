local M = {}

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config")
local previewers = require("telescope.previewers")

local pool = require("theme.random_pool")
local utils = require("theme.utils")

local function entry_maker(name)
  local current = name == (vim.g.colors_name or "")
  return {
    value = name,
    display = current and (name .. "  (current)") or name,
    ordinal = name,
  }
end

---@param opts? table
function M.pick(opts)
  if not pickers then
    return vim.notify("theme: telescope.nvim", vim.log.levels.ERROR)
  end

  local names = pool.get_all_themes()
  table.sort(names)
  if #names == 0 then
    return vim.notify("theme: No theme found", vim.log.levels.WARN)
  end

  pickers.new(opts or {}, {
    prompt_title = "Themes (" .. #names .. ")",
    finder = finders.new_table({ results = names, entry_maker = entry_maker }),
    sorter = conf.values.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Preview",
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {
          entry.value,
          "",
          "Preview: TODO",
        })
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local name = action_state.get_selected_entry().value
        actions.close(prompt_bufnr)
        utils.apply_colorscheme(name)
      end)
      return true
    end,
  }):find()
end

return M
