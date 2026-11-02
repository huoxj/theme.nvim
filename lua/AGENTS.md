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
  namespace. `preview.fill` is the only writer of the *sample* buffer; the
  panel's readme view writes its own lines into the same pane buffer and stops
  the lua treesitter highlighter first.
- **`ui/init.lua` is a singleton:** module-level `active` panel. `M.close(p)`
  requires the panel table — it does not fall back to `active`, so `M.close()`
  with no argument is a no-op. The panel state holds `state.panes` (repos, cs,
  preview) plus `state.hint` and `state.backdrop`; there is no frame window and
  no debounce timer. Close only through the buffer keymaps or the `WinClosed`
  autocmd, which pass `p`.
- **`ui/list.lua` must reset `prev_repo` in `reset()` (called from `open()`)**,
  otherwise reopening the panel with the same first repo selected leaves the
  colorscheme list empty. `sync(repo)` gates the re-render on the repo changing.
- **The focus model is explicit.** `<Tab>`/`<S-Tab>` cycle through the three
  panes (forward/reverse, wrapping); `1`/`2`/`3` jump by number, and `3` (the
  preview) is read mode — focusing it must not change the preview's content or
  title. `M.follow` only re-evaluates the preview when the focused pane is a
  list.
- **The installer owns exactly one tree.** `lua/theme/install.lua` writes only
  `stdpath("data")/site/pack/theme/start/<repo-basename>`; installs are atomic
  (clone to `<dir>.tmp-<pid>` → verify `colors/` → `fs_rename`), and every
  failure path removes the temp dir. It must not require the UI or telescope.
- **Status precedence is `shadow > ours > elsewhere > none`**, and "provided
  elsewhere" ignores runtimepath entries under our pack dir and under
  `$VIMRUNTIME`. The panel detects conflicts, never adjudicates: `elsewhere`
  blocks `i`, `shadow` is notified once per open, and `x` removes our copy only.
- **`<CR>` on a colorscheme row applies it.** An `ours`/`shadow`/`elsewhere`
  theme applies immediately; a `none` theme is installed first and applied only
  when the install reports success. The previews themselves still never apply.
  `<CR>` on a repo row only moves focus to the colorscheme list.
- **`"both"` colorschemes produce two rows** (dark + light) in `ui/list.lua`.
- **`ui/render.lua` extmark columns are byte offsets** while padding uses display
  width; the swatch glyph (`∙`, U+2219) is 3 bytes / 1 cell. Keep the two
  coordinate systems separate, and mint swatch groups per render inside the
  pane's namespace (skipping groups with neither fg nor bg).
- **Panel chrome is derived from the active colorscheme** (`ui/chrome.lua`,
  `ThemeUI*` groups). The tinted preview is the only pane that borrows another
  theme's colors, and its `Normal` stays out of `winhighlight` while tinted.
- **`repo.readme` is optional**; the panel falls back to the wrapped
  `description`. Keep both shapes working.

## Verifying changes

Run the module smoke test and the panel cycle from `docs/architecture.md`:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
for _, m in ipairs({"theme","theme.config","theme.pool","theme.data",
  "theme.colorscheme","theme.preview","theme.preview_code","theme.ui",
  "theme.ui.render","theme.ui.chrome","theme.ui.list",
  "theme.install"}) do require(m) end
print("modules ok")' -c 'qa!'
```
