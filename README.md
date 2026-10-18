# Theme.nvim

> A powerful and comprehensive theme manager for Neovim

## Features

- 🗃️ Browse and preview themes from github, and switch between installed ones
- 🎲 Random theme on startup with customizable options
- ⏰ Auto light/dark theme detect and switching based on system time (planned)

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

### Commands

| Command | Description |
| --- | --- |
| `:Theme` | Open the theme panel: browse repos and preview colorschemes live. |
| `:Theme random` | Apply a random theme from the random pool. |
| `:Telescope themes` | Pick from every theme on `runtimepath` (requires telescope.nvim). |

Previews never change your active colorscheme; `<CR>` on the colorscheme list is
the only key that applies one (see
[Managing installed themes](#managing-installed-themes)).

### Managing installed themes

theme.nvim manages the themes it installs itself, in its own namespace:
`stdpath("data")/site/pack/theme/start`. The Repos list has two views, shown as
tabs on its title and switched with `[` and `]` from either list:

- **Browse** (the default) — the whole catalogue, most-starred first. Each row
  carries an install chip: `✓` installed by theme.nvim, `≡` provided by your own
  config, `⚠` both. Title: `[1] [Browse] Managed`.
- **Managed** — only the themes under theme.nvim's own pack dir. Title:
  `[1] Browse [Managed]`.

With a repo selected in the Browse view:

| Key | Action |
| --- | --- |
| `i` | Install the repo (shallow clone, then `:packadd`). |
| `x` | Uninstall it — removes theme.nvim's own copy only. |
| `u` | Update it (re-clone from scratch). |

In the Managed view `x` and `u` do the same, and the colorscheme list describes
the selected theme. `u` needs the theme's repository, which is only known for
themes in the catalogue; for one you dropped into the pack dir yourself the
panel says so instead of guessing.

`x` only ever deletes theme.nvim's own copy: on a row that is not ours (a theme
your config provides, or nothing at all) it refuses and leaves the filesystem
alone. That is also how a shadowed theme is resolved — removing our copy hands
it back to your own management.

`<CR>` applies a colorscheme, and it lives on the colorscheme list: press it
there, and the row's theme must be installed (`✓`/`⚠` in Browse, any row in
Managed). Anything else gets a hint to install it first. Installed themes land
in `pack/theme/start`, so they are on `runtimepath` from the next start on and
join the random pool automatically — narrow the pool with
`random_pool.exclude` if you want to.

The panel never installs over a theme your config already provides. Your config
is never touched, moved, or written to.

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
- [ ] Light/dark theme detection & time-based switching

