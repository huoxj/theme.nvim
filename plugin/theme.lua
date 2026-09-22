local SUBCOMMANDS = { "random" }

vim.api.nvim_create_user_command("Theme", function(opts)
  require("theme.commands").dispatch(opts.fargs)
end, {
  nargs = '*',
  complete = function(ArgLead, CmdLine)
    local params = vim.split(CmdLine, "%s+", { trimempty = true })
    if #params <= 2 then
      return vim.tbl_filter(function(cmd)
        return vim.startswith(cmd, ArgLead)
      end, SUBCOMMANDS)
    end
    return {}
  end
})

