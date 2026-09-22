# Theme.nvim

> A powerful and comprehensive theme manager for Neovim

## Features

- 🗃️ Built-in theme manager to install, switch and preview themes from github
- 🎲 Random theme on startup with customizable options
- ⏰ Auto light/dark theme detect and switching based on system time

## Installation

### Lazy.nvim

```lua
return {
  "huoxj/theme.nvim",
  lazy = false,
  opts = {
    -- your config here
  },
}
```

## Usage

### Customize random theme pool

On startup, theme.nvim picks a random theme from the **random pool**.

Random pool = `include` - `exclude`. It support both theme name or predefined tag, starting with `#`.

For example, if you want to randomly pick theme from all themes except neovim built-in theme `default` and `blue`:

```lua
opts = {
  random_pool = {
    include = { "#all" },
    exclude = { "default", "blue" },
  }
}
```

Available tags:

| Tag | Description |
| --- | --- |
| `#all` | All loaded themes under run time path |
| `#builtin` | Neovim built-in themes |

> More tags and customizable tags are on the way

## WIP

This project is still under development. Many breaking changes may be introduced in the future.

Any suggestions and contributions are welcome. Feel free to open an issue or submit a pull request.

- [x] Startup random theme
- [ ] Like/dislike theme
- [ ] Theme switching panel
- [ ] Github theme browser & previewer
- [ ] Light/dark theme detection & time-based switching

