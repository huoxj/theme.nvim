local telescope = require("telescope")

return telescope.register_extension({
  exports = {
    themes = function(opts)
      require("theme.picker").pick(opts)
    end,
  },
})

