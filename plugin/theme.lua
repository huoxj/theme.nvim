local SUBCOMMANDS = { "random" }

vim.api.nvim_create_user_command("Theme", function(opts)
  require("theme").command(opts.fargs)
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line)
    local params = vim.split(cmd_line, "%s+", { trimempty = true })
    if #params <= 2 then
      return vim.tbl_filter(function(cmd)
        return vim.startswith(cmd, arg_lead)
      end, SUBCOMMANDS)
    end
    return {}
  end,
})
