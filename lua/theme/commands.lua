local M = {}

---@param args string[]
function M.dispatch(args)
  if #args == 0 then
    -- TODO: open theme manager panel
  elseif #args == 1 then
    if args[1] == "random" then
      require("theme.random_pool").apply_random()
    else
      vim.notify(
        string.format("Unknown subcommand: %s", args[1]),
        vim.log.levels.WARN
      )
    end
  end
end

return M
