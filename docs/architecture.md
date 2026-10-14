# theme.nvim architecture

Maintenance reference for the plugin as of commit `a28414f` (the architecture
refactor). It describes the module boundaries, the data flow from the offline
harvester to the on-screen previews, the invariants that keep the modules
consistent, and how to exercise everything headlessly.

Read this together with the `AGENTS.md` files in `lua/` and `scripts/`, which
distill the conventions and the pipeline contract for day-to-day editing.

## What the plugin does

theme.nvim picks a random colorscheme at startup and lets you browse and preview
themes without leaving your current colorscheme:

- **Random on startup** — `setup()` registers a one-shot `VimEnter` autocmd that
  applies a random theme from a configurable pool.
- **`:Theme`** — opens a floating panel that lists harvested GitHub theme repos
  (by stars) and their colorschemes, with a live preview.
- **`:Theme random`** — applies a random theme on demand.
- **`:Telescope themes`** — telescope picker over every theme on `runtimepath`.

The only hard dependency is Neovim 0.11+. `telescope.nvim` is optional and only
needed for the picker; the panel and random-startup paths do not touch it.

## Module map

One responsibility per file. Every module is a plain table (`local M = {}` …
`return M`) with no hidden state beyond the caches noted below.

| File | Responsibility |
| --- | --- |
| `lua/theme/init.lua` | Public entry: `setup(opts)` (delegates to config, registers the `VimEnter` random apply) and `command(args)` (dispatches `:Theme`). |
| `lua/theme/config.lua` | Options only: `DEFAULTS.random_pool.{include,exclude}` and the deep-merged `M.opts`. |
| `lua/theme/pool.lua` | Scans `runtimepath` for themes, resolves pool specs (`#all`, `#builtin`, plain names), computes the random pool, and applies a random theme. |
| `lua/theme/data.lua` | Lazy-loads `lua/theme/hl.json`, carries the dataset's `---@class` schema annotations, and answers highlight-group queries by colorscheme name. |
| `lua/theme/colorscheme.lua` | `apply(name)` (pcall + notify, never raises) and `current()` (`vim.g.colors_name`). |
| `lua/theme/preview.lua` | Shared preview plumbing: `fill(buf)` writes the sample source, `tint(win, hlgs)` paints a window without applying a colorscheme. |
| `lua/theme/preview_code.lua` | Pure data: the sample Lua source shown in every preview. |
| `lua/theme/picker.lua` | telescope picker over all themes on `runtimepath` (uses the shared preview). |
| `lua/theme/ui/init.lua` | Floating panel: layout, open/close, focus cycling, debounced preview wiring. |
| `lua/theme/ui/list.lua` | Renders the repo list (stars-sorted) and the colorscheme list (rows + colour swatches). |
| `lua/telescope/_extensions/theme.lua` | Registers the `themes` telescope extension. |
| `plugin/theme.lua` | Defines the `:Theme` user command and its completion. |
| `scripts/build_hljson.py` | Offline harvester: GitHub search → tarball → headless sampling → `hl.json`. |
| `scripts/sample.lua` | The script run *inside* headless Neovim by the harvester to dump one colorscheme's highlight groups. |

## Data flow

The dataset is built offline and shipped in the repo; nothing in the runtime
path talks to GitHub.

```
scripts/build_hljson.py
  │  GitHub search API (5 keyword queries, stars >= 50, 100/page)
  │  → codeload tarball per repo → temp dir
  │  → for each colors/*.{vim,lua}:
  │       run `nvim --headless -u NONE -c 'set background=<bg>' -l scripts/sample.lua`
  │       (env: CS_DIR, CS_NAME, HLG_KEYS)  ×2, once per forced background
  │       sample.lua: `highlight clear`, apply colorscheme, grab 39 KEY_NAMES,
  │                  follow :hi links, emit JSON on stderr between markers
  │  → strip cterm/ctermfg/ctermbg → classify light/dark by median luma
  ▼
lua/theme/hl.json                         (generated, ~1.2 MB, committed)
  ▼
lua/theme/data.lua  load()  ── lazy, once per session
  │   repos     = decoded document
  │   by_name   = { colorscheme name → Colorscheme }   (first repo wins)
  ▼
┌───────────────────────────────┬────────────────────────────────────┐
│ lua/theme/ui/list.lua         │ lua/theme/picker.lua               │
│ repo rows (stars desc) +      │ flat list of rtp theme names,      │
│ colorscheme rows + swatches   │ previewed via query_hl(name,"dark")│
└───────────────┬───────────────┴────────────────┬───────────────────┘
                │ row.hlgs                        │ hlgs
                ▼                                 ▼
          lua/theme/preview.lua  fill(buf) + tint(win, hlgs)
          (window-local highlight namespace; the active
           colorscheme is never changed by a preview)
```

Note the two preview surfaces query highlights differently:

- the **panel** already holds a `Colorscheme` record from `data.repos()` and
  tints with `row.hlgs` directly;
- the **picker** only has a theme *name* from `runtimepath`, so it goes through
  `data.query_hl(name, "dark")` and the by-name index.

## Runtime flows

### Startup random apply

```
require("theme").setup(opts)
  config.setup(opts)                     -- deep-merge over defaults
  nvim_create_autocmd("VimEnter", once)
    → pool.apply_random()
        randomseed(...)                  -- reseeded per call
        pool = pool.random_pool()        -- include − exclude − current, deduped
        pool == {} → notify WARN and stop
        else cs.apply(pool[math.random(#pool)])
```

### `:Theme` dispatch

`plugin/theme.lua` defines `:Theme` with `nargs="*"` and completion for
`random`. `init.command(args)`:

| `args` | Action |
| --- | --- |
| `nil` (no argument) | `require("theme.ui").open()` |
| `{ "random" }` | `require("theme.pool").apply_random()` |
| anything else | `vim.notify(... WARN)` |

### Floating panel (`ui/init.lua` + `ui/list.lua`)

`open()` builds five floats — `backdrop`, `frame`, `repo`, `cs`, `preview` —
from a single `layout()` function (80% of the editor, two list panes on the
left, preview on the right). It then:

- renders the repo list, sorted by `stars` descending;
- wires `CursorMoved` in either list to `list.sync()` (re-render the
  colorscheme list when the selected repo changed) and to `current_cs()`;
- tints the preview through `show_preview`, which debounces `preview.tint` by
  200 ms (`vim.uv` timer, scheduled);
- maps keys on all three focusable buffers: `<Esc>`/`q` close, `<Tab>`/`<S-Tab>`
  cycle focus in the order `repo → cs → preview`;
- closes on `WinClosed` for any panel window.

A "both"-background colorscheme renders as **two** rows (dark then light); other
schemes render one row using their own `bg_type`.

## Invariants and gotchas

These are the rules that are easy to violate when editing. Break one and the
plugin usually still runs but silently misbehaves.

1. **`lua/theme/hl.json` is generated — never hand-edit it.** Rebuild with
   `python3 scripts/build_hljson.py` (writes `lua/theme/hl.json` by default; an
   optional path argument overrides the destination). The header comment in
   `scripts/build_hljson.py` and the `---@class` block in `lua/theme/data.lua`
   are the authoritative schema documentation; keep both in sync with any
   schema change.
2. **The random pool is a set.** `pool.random_pool()` is the union of every
   resolved include spec, minus `exclude`, minus the *current* colorscheme, and
   deduplicated with a `seen` table. Duplicate specs must not inflate a theme's
   probability of being picked. (The old implementation used
   `vim.tbl_extend("force", …)`, which collided on integer keys and silently
   dropped themes; `pool.lua` uses `vim.list_extend` + dedup instead.)
3. **`data.lua`'s by-name index is first-writer-wins.** `load()` does
   `by_name[name] = by_name[name] or colorscheme` while iterating
   `pairs(repos)`. When two repos ship a colorscheme with the same name, the
   winner depends on Lua's hash iteration order — arbitrary but stable for the
   duration of a session. Previews are name-keyed, so a collision picks one
   repo's colors and ignores the other.
4. **The panel previews only; it has no apply key.** This is deliberate, not an
   oversight: the README WIP list still tracks "theme switching panel". Do not
   add a select/apply mapping without updating the README and this document.
5. **`"both"` colorschemes render as two rows** in the panel (dark + light), so
   a repo's row count can exceed its colorscheme count.
6. **Dataset `hlgs` are vim highlight attrs with the cterm fields stripped**
   (`cterm`, `ctermfg`, `ctermbg`). They were sampled by a headless Neovim, and
   each sample's light/dark classification comes from a median-luma heuristic
   over its `bg` values (falling back to `fg`, then to dark). A colorscheme is
   sampled twice — once per forced `background` — and each sample is stored
   under *its own* detected background, so a scheme that reads dark under both
   runs ends up with only `hlgs.dark`; `bg_type` is derived from which keys
   exist (`"both"` iff both do).
7. **`query_hl(name, background)` falls back to the colorscheme's own
   background.** If the requested `background` key is absent it returns
   `colorscheme.hlgs[colorscheme.bg_type]`, and `nil` only when the name is not
   in the dataset.
8. **Previews never apply a colorscheme.** `preview.tint` writes into the
   dedicated `theme_preview` namespace and calls `nvim_win_set_hl_ns` on the
   target window only. Nothing in the preview path touches `vim.cmd.colorscheme`.
9. **The picker's preview is hardcoded to the `dark` background**
   (`data.query_hl(entry.value, "dark")`). The panel uses each row's real
   background.
10. **`pool.lua` splits builtin from installed by path prefix**, comparing each
    `colors/*` file against `$VIMRUNTIME`: files under that directory are
    builtin, everything else is installed. `#builtin` and `#all` depend on this.
11. **`ui/list.lua` resets `prev_repo` in `setup()`.** Without it, reopening the
    panel with the same first repo selected made `sync()` return early and left
    the colorscheme list empty.
12. **The panel is a singleton.** `ui/init.lua` keeps a module-level `active`
    and a module-level `vim.uv` timer; `open()` focuses the existing panel if
    one is valid. `M.close(p)` takes the panel table and returns immediately for
    a `nil` argument — it does **not** fall back to `active`, so `require("theme.ui").close()`
    with no argument is a no-op. The close paths that work are the buffer
    keymaps and the `WinClosed` autocmd, both of which capture the panel object.
13. **Swatch columns in `ui/list.lua` are byte offsets**, and `GLYPH` (`∙`) is
    3 bytes wide but 1 cell wide. Extmark columns must stay byte-based while
    padding stays display-width-based; mixing the two misaligns the swatches.

## Headless testing

The plugin targets Neovim 0.11+ (it uses `vim.uv`, `vim.fs`,
`vim.api.nvim_get_hl`, `nvim_win_set_hl_ns`, and `-l`). Everything below was run
against `NVIM v0.11.3`.

Two invocation shapes:

```sh
# Run Lua with the plugin on the runtimepath. -u NONE skips user config,
# so plugins are not sourced automatically; add the repo root to rtp.
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua <code>' -c 'qa!'

# Source plugin/theme.lua too when you need the :Theme command.
nvim --headless -u NONE -c 'set rtp+=.' -c 'runtime plugin/theme.lua' \
     -c 'Theme random' -c 'lua print(vim.g.colors_name)' -c 'qa!'

# Run a standalone Lua test file (this is how the build pipeline runs sample.lua).
nvim --headless -u NONE -l path/to/script.lua
```

Useful checks (run from the repo root, so `set rtp+=.` resolves):

```sh
# Load every runtime module except the telescope picker (telescope is optional).
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
for _, m in ipairs({
  "theme","theme.config","theme.pool","theme.data","theme.colorscheme",
  "theme.preview","theme.preview_code","theme.ui","theme.ui.list",
}) do require(m) end
print("modules ok")' -c 'qa!'

# Theme discovery and the default pool.
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
local p = require("theme.pool")
print("builtin", #p.builtin_themes())
print("pool #all", #p.random_pool())' -c 'qa!'

# Dataset loads and is queryable by colorscheme name.
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
local d = require("theme.data")
local n = 0; for _ in pairs(d.repos()) do n = n + 1 end
print("repos", n)
print("deeper-night/dark", d.query_hl("deeper-night", "dark") and "ok" or "nil")' -c 'qa!'

# Safe apply and the panel open/close cycle.
nvim --headless -u NONE -c 'set rtp+=.' -c 'lua
print("apply blue", require("theme.colorscheme").apply("blue"))
local ui = require("theme.ui")
ui.open(); print("windows after open", #vim.api.nvim_list_wins())   -- base + 5 floats
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)       -- WinClosed -> close
print("windows after close", #vim.api.nvim_list_wins())' -c 'qa!'
```

Expected results on a clean machine: `builtin` is 27, `repos` is 169,
`deeper-night` queries return `ok`, and the window count goes 6 → 1. `picker.lua`
requires `telescope.nvim` at the top of the file, so it can only be loaded when
telescope is on the runtimepath.

To validate the dataset independently of Neovim:

```sh
python3 -c "import json; d=json.load(open('lua/theme/hl.json')); \
print('repos', len(d)); \
r=next(iter(d.values())); print('repo fields', sorted(r)); \
print('cs fields', sorted(next(iter(r['colorschemes'].values()))))"
```
