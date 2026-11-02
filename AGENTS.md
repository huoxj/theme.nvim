# AGENTS.md

Orientation for AI maintainers working in this repository.

## What this is

theme.nvim is a Neovim colorscheme manager: it applies a random theme at
startup, and provides a floating panel and a telescope picker for browsing and
live-previewing themes. Neovim 0.11+ is required. `telescope.nvim` is the only
optional dependency and is needed only for the picker.

## Layout

```
lua/theme/init.lua          setup(opts) + command(args); VimEnter random apply
lua/theme/config.lua        options only (random_pool.{include,exclude})
lua/theme/pool.lua          rtp scan + #tag/name resolution + random pick
lua/theme/data.lua          lazy hl.json load + schema annotations + by-name index
lua/theme/colorscheme.lua   apply(name) pcall + current()
lua/theme/install.lua       our pack dir: installed + status + async jobs
lua/theme/preview.lua       fill(buf) + tint(win, hlgs), shared by picker and panel
lua/theme/preview_code.lua  sample Lua source (pure data)
lua/theme/picker.lua        telescope picker
lua/theme/ui/init.lua       panel: layout/open/close, focus model, keymaps
lua/theme/ui/render.lua     float-pane plumbing: Line builder, paint, swatches
lua/theme/ui/chrome.lua     panel highlight groups + winhighlight mapping
lua/theme/ui/list.lua       repo/colorscheme rows, readme preview body, hint bar
lua/telescope/_extensions/theme.lua   telescope extension registration
plugin/theme.lua            :Theme user command + completion
scripts/build_hljson.py     offline harvester (GitHub -> headless nvim -> hl.json)
scripts/sample.lua          sampling script run inside headless nvim
lua/theme/hl.json           GENERATED dataset (~1.2 MB) — do not hand-edit
docs/architecture.md        module map, data flow, invariants, headless testing
```

## Commands

| Command | Behavior |
| --- | --- |
| `:Theme` | Open the floating panel (browse repos, preview colorschemes live). |
| `:Theme random` | Apply a random theme from the random pool. |
| `:Telescope themes` | Pick a theme from every theme on `runtimepath` (needs telescope). |

User configuration is `require("theme").setup({ random_pool = { include = …, exclude = … } })`,
where entries are theme names or the tags `#all` / `#builtin`.

## Where the invariants live

Read `docs/architecture.md` before changing behavior — it holds the full
module map, data flow, and the numbered invariants/gotchas. The short version:

- **`lua/theme/hl.json` is generated.** Rebuild it with
  `python3 scripts/build_hljson.py`; never hand-edit it. Its schema is
  documented by the header comment in `scripts/build_hljson.py` and the
  `---@class` block in `lua/theme/data.lua` — keep both in sync.
- The random pool is **set semantics** (`include − exclude − current`, deduped);
  duplicates must not change pick probability.
- `data.lua`'s by-name index is **first-repo-wins** on name collisions.
- The installer touches **only its own pack dir**
  (`stdpath("data")/site/pack/theme/start`), clones atomically (temp dir →
  verify `colors/` → rename, rolling back on any failure), and never writes
  to the user's own config. Status precedence is
  **`shadow > ours > elsewhere > none`**; the panel detects conflicts rather
  than adjudicating them.
- The panel's only apply path is **`<CR>` on a colorscheme row**: an installed
  theme (`ours`/`shadow`/`elsewhere`) applies immediately, and a `none` theme is
  installed first and applied only on success; previews never apply a
  colorscheme.
- The Repos list is one list with a **filter and a sort** (`F` / `S`). The
  filter is all / installed / managed; the sort is stars / name / owner. The
  managed filter lists our pack dir, joined to the dataset by directory
  basename, with no chips; a theme only on disk shows its directory name, gets
  its colorscheme rows from its own `colors/`, and refuses `u`. The
  colorscheme list has its own filter (`F`: all / light / dark) and one name
  sort (`S`).
- The panel is three bordered panes (Repos, Colorschemes, Preview) over a
  backdrop, with an explicit focus model: `Tab`/`S-Tab` cycle the two lists,
  `1`/`2`/`3` jump by number, and the preview (`3`) is read mode. `<CR>` on a
  repo row moves to the colorscheme list.
- Previews never apply a colorscheme; they write to a window-local highlight
  namespace.

## Editing rules

- One responsibility per module, plain `local M = {}` … `return M`, no
  defensive wrappers or speculative abstractions. This codebase was
  deliberately refactored to be small; keep it that way.
- Keep `plugin/theme.lua` a thin command wrapper; dispatch logic belongs in
  `lua/theme/init.lua`.
- Do not add dependencies. `telescope.nvim` is optional at runtime — nothing
  outside `picker.lua` and the telescope extension may require it.
- Verify changes headlessly before claiming success; see the "Headless testing"
  section of `docs/architecture.md` for the exact invocation patterns.
