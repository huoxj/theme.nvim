# AGENTS.md — `lua/`

Conventions and invariants for the Lua runtime modules. See
`docs/architecture.md` for the full module map, data flow, and numbered
invariants; this file is the editing checklist.

## Module conventions

- **One responsibility per file.** Each module is a plain table:
  `local M = {}` … `return M`. No classes, no metatables, no event system.
- **No defensive wrappers.** Call functions directly and let them fail loudly,
  except at the two places that are *meant* to be safe: `colorscheme.apply`
  (pcall + notify) and the JSON load in `data.lua`.
- **Lazy `require` at call time for cross-cutting entries.** `init.lua` and
  `plugin/theme.lua` require `theme.ui` / `theme.pool` inside the function body
  so that loading the plugin does not pull in the UI or the dataset.
- **Type annotations, not runtime checks.** The `---@class` schema for the
  dataset lives at the top of `data.lua`; other modules reuse those aliases
  (`Repo`, `Colorscheme`, `HighlightGroups`, `HighlightGroup`) in `---@param`
  comments. Do not create a separate types file.
- **Keep telescope optional.** Only `theme/picker.lua` and
  `telescope/_extensions/theme.lua` may require `telescope.*`, and only at the
  top of those files. Requiring any other module must work without telescope
  installed.

## Invariants to preserve

- **`theme.pool.random_pool()` is a set:** the union of every resolved
  `include` spec, minus `exclude`, minus `colorscheme.current()`, deduplicated
  with a `seen` table. Never merge arrays with `vim.tbl_extend("force", …)` —
  integer keys collide and silently drop themes. `pool.lua` uses
  `vim.list_extend` + dedup deliberately.
- **`#all` / `#builtin` resolve in `pool.lua`, not `config.lua`.** `config.lua`
  only stores options; the tag names appear there as a comment.
- **Builtin vs installed** is decided by whether the `colors/*` file path is
  under `$VIMRUNTIME`.
- **`data.query_hl(name, background)`** looks up by colorscheme *name* (via the
  `by_name` index) and falls back to the colorscheme's own `bg_type` when the
  requested background is missing. Returning `nil` means the name is not in the
  dataset.
- **`by_name` is first-repo-wins.** `load()` keeps the first colorscheme seen
  for a name; collisions across repos resolve by `pairs` order (arbitrary but
  stable within a session).
- **Previews never apply a colorscheme.** `preview.tint` writes into the
  `theme_preview` namespace and sets it as the target window's highlight
  namespace. `preview.fill` is the only writer of the sample buffer.
- **`ui/init.lua` is a singleton:** module-level `active` panel and a
  module-level `vim.uv` timer. `M.close(p)` requires the panel table — it does
  not fall back to `active`, so `M.close()` with no argument is a no-op. Close
  only through the buffer keymaps or the `WinClosed` autocmd, which pass `p`.
- **`ui/list.lua` must reset `prev_repo` in `setup()`**, otherwise reopening the
  panel with the same first repo selected leaves the colorscheme list empty.
- **The panel has no apply key** — preview only. This mirrors the README WIP
  list; treat it as intentional.
- **`"both"` colorschemes produce two rows** (dark + light) in `ui/list.lua`.
- **`ui/list.lua` extmark columns are byte offsets** while padding uses display
  width; `GLYPH` is 3 bytes / 1 cell. Keep the two coordinate systems separate.

## Verifying changes

Run the module smoke test and the panel cycle from `docs/architecture.md`:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
for _, m in ipairs({"theme","theme.config","theme.pool","theme.data",
  "theme.colorscheme","theme.preview","theme.preview_code","theme.ui",
  "theme.ui.list"}) do require(m) end
print("modules ok")' -c 'qa!'
```
