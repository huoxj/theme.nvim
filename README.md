# Theme.nvim

> A powerful and comprehensive theme manager for Neovim

## Features

- 🗃️ Browse themes from GitHub, install them, and switch between installed ones
- 📄 Repo READMEs rendered inside the panel (with an optional markdown renderer)
- 🎲 Random theme on startup with customizable options
- ⏰ Auto light/dark theme detect and switching based on system time (planned)

## Installation

### Lazy.nvim

```lua
return {
  "huoxj/theme.nvim",
  lazy = false,
  dependencies = {
    -- optional: renders the repo README inside the panel
    "OXY2DEV/markview.nvim",
  },
}
```

markview.nvim is optional. Neovim 0.11 bundles the markdown parsers it needs.
Without it the panel shows an info card for the selected repo — name, author,
stars, description and its colorschemes — instead of the rendered README.

## Usage

### Commands

| Command | Description |
| --- | --- |
| `:Theme` | Open the theme panel: browse repos and preview colorschemes live. |
| `:Theme random` | Apply a random theme from the random pool. |
| `:Telescope themes` | Pick from every theme on `runtimepath` (requires telescope.nvim). |

### The panel

`:Theme` opens three panes: `[1] Repos`, `[2] Colorschemes` and `[3] Preview`.
`Tab` / `S-Tab` cycle through them, `1` / `2` / `3` jump straight to one, and
`q` (or `<Esc>`) closes the panel. The bottom bar only lists the keys that work
in the pane you are in.

Each Repos row carries an install chip: `✓` installed by theme.nvim, `≡`
provided by your own config, `⚠` both.

Repos list:

| Key | Action |
| --- | --- |
| `j` / `k` | Move the selection; the colorscheme list and the preview follow. |
| `Enter` | Go to the colorscheme list. |
| `i` | Install the repo (shallow clone, then `:packadd`). |
| `x` | Uninstall it — removes theme.nvim's own copy only. |
| `u` | Update it (re-clone from scratch). |
| `f` | Filter: all → installed → managed. |
| `s` | Sort: stars → name → owner. |

Colorscheme list:

| Key | Action |
| --- | --- |
| `Enter` | Switch to the selected colorscheme; if its repo is not installed yet, install it first. |
| `f` | Filter: all → light → dark. |
| `s` | Sort by name. |

The filter chooses the rows: `all` is the whole catalogue, `installed` keeps the
themes already provided (by theme.nvim or your own config), and `managed` shows
only what theme.nvim's own pack dir holds. The sort orders whatever the filter
left — `stars` descending, `name` and `owner` ascending. The two are
independent.

The Preview follows the focused list. On the Repos list it is the repo's
README, rendered with markview.nvim when it is installed; otherwise (and while
the README is still loading) it is an info card with the repo's name, author,
stars, description and colorschemes. On the Colorscheme list it is the sample
code tinted with the selected colorscheme.

### Installed themes

theme.nvim manages the themes it installs itself, in its own namespace:
`stdpath("data")/site/pack/theme/start`. A successful install is `:packadd`-ed
right away, so the theme is usable in the current session and lands in the
random pool from the next start on — narrow the pool with `random_pool.exclude`
if you want to.

`x` only ever deletes theme.nvim's own copy: on a row that is not ours (a theme
your config provides, or nothing at all) it refuses and leaves the filesystem
alone. That is also how a shadowed theme is resolved — removing our copy hands
it back to your own management.

The panel never installs over a theme your config already provides. Your config
is never touched, moved, or written to.

### Customize random theme pool

On startup, theme.nvim picks a random theme from the **random pool**.

Random pool = `include` - `exclude` - the current theme, deduplicated. Both
sides take theme names or predefined tags starting with `#`. The defaults are
`include = { "#all" }` and `exclude = {}`.

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
| `#all` | Every colorscheme on `runtimepath` (built-in and installed) |
| `#builtin` | Neovim built-in themes |

> More tags and customizable tags are on the way

## Roadmap (open questions)

- Editing colorscheme options inside the panel (the manager would own
  `require` + `setup`) — a strong responsibility claim; under discussion.
- Trying a theme without installing it — clone a candidate and really apply it
  for the session, without registering it as installed. A session-preview layer,
  distinct both from the offline dataset preview (no side effects, dataset
  colors) and from installing (a real, persistent copy). Not implemented.

## WIP

This project is still under development. Many breaking changes may be introduced in the future.

Any suggestions and contributions are welcome. Feel free to open an issue or submit a pull request.

- [x] Startup random theme
- [ ] Like/dislike theme
- [x] Theme switching panel
- [x] Github theme browser & previewer
- [x] Install / update / remove themes from the panel
- [x] Filter and sort the repo and colorscheme lists
- [x] Live README in the repo preview
- [ ] Light/dark theme detection & time-based switching
