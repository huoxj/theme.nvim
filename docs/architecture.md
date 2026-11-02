# theme.nvim architecture

Maintenance reference for the current architecture. It describes the module
boundaries, the data flow from the offline harvester to the on-screen previews,
the invariants that keep the modules consistent, and how to exercise everything
headlessly.

Read this together with the `AGENTS.md` files in `lua/` and `scripts/`, which
distill the conventions and the pipeline contract for day-to-day editing.

## What the plugin does

theme.nvim picks a random colorscheme at startup and lets you browse and preview
themes without leaving your current colorscheme:

- **Random on startup** — `setup()` registers a one-shot `VimEnter` autocmd that
  applies a random theme from a configurable pool.
- **`:Theme`** — opens a three-pane floating panel: harvested GitHub theme repos
  (by stars), their colorschemes, and a context-following preview (a repo's
  README, or the sample code tinted with the selected colorscheme).
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
| `lua/theme/install.lua` | Install/update/uninstall for theme.nvim's own pack dir: `dir`, `installed`, `status`, and the async clone jobs. |
| `lua/theme/preview.lua` | Shared preview plumbing: `fill(buf)` writes the sample source, `tint(win, hlgs)` paints a window without applying a colorscheme. |
| `lua/theme/preview_code.lua` | Pure data: the sample Lua source shown in every preview. |
| `lua/theme/picker.lua` | telescope picker over all themes on `runtimepath` (uses the shared preview). |
| `lua/theme/ui/init.lua` | Panel lifecycle: layout, open/close, the focus model, keymaps, and preview wiring. |
| `lua/theme/ui/render.lua` | Generic float-pane plumbing: the `Line` builder, painting, hand-drawn selection/segment extmarks, and the per-render swatch groups. |
| `lua/theme/ui/chrome.lua` | Panel chrome: highlight groups (palette mined from the active colorscheme) and the `winhighlight` mapping per pane/focus. |
| `lua/theme/ui/list.lua` | Panel content: repo rows, managed-theme rows, colorscheme rows (one per variant), the preview bodies, and the hint bar. |
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
│ lua/theme/ui/                 │ lua/theme/picker.lua               │
│  list.lua  repo rows (stars   │ flat list of rtp theme names,      │
│    desc) + colorscheme rows   │ previewed via query_hl(name,"dark")│
│  render.lua  paint + swatches │                                    │
└───────────────┬───────────────┴────────────────┬───────────────────┘
                │ row.hlgs                        │ hlgs
                ▼                                 ▼
          lua/theme/preview.lua  fill(buf) + tint(win, hlgs)
          (window-local highlight namespace; the active
           colorscheme is never changed by a preview)
```

Both preview surfaces resolve a colorscheme's highlights through
`data.query_hl(name, background)` and the by-name index; the panel builds its
rows with the lookup already applied, so `row.hlgs` is the resolved table.

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

### Managing installed themes (`install.lua`)

theme.nvim owns exactly one tree, its own pack dir
`stdpath("data")/site/pack/theme/start`, and installs there as
`<repo-basename>`. An install is atomic: `git clone --depth 1` into a sibling
`<dir>.tmp-<pid>`, verify the clone ships a `colors/` directory, `fs_rename`
it into place, then `:packadd` it, which puts the clone on `runtimepath` for the
running editor. Any failure removes the temp dir, so a failed install leaves
nothing behind. Persistence is free — `pack/*/start` is on `runtimepath` at
every start, so no `:packadd` is needed after a restart. Update is `rm` +
re-clone (a shallow pull would miss a deleted or renamed colors file);
uninstall removes only our own directory. `installed()` is the read side: it
lists what our pack dir holds, as `{ name, dir }`, skipping clone temp dirs.

`status(repo)` reports how a repo is currently provided, in the precedence
`shadow` > `ours` > `elsewhere` > `none`: `ours` (our dir exists), `shadow`
(ours *and* a non-manager runtimepath entry provides the same basename),
`elsewhere` (only the user's config provides it), `none`. The check ignores
paths under our pack dir and under `$VIMRUNTIME`. This is **detection, not
adjudication**: a `shadow` theme is surfaced once per panel open and otherwise
left alone; the panel refuses to install over `elsewhere`, and uninstalling our
copy never touches the user's own.

### Floating panel (`ui/`)

`open()` builds five floats — `backdrop`, `repos`, `cs`, `preview`, `hint` —
from `init.layout()`. The panel is 80% x 80% of the editor, centered; a
full-screen backdrop (winblend 60, not focusable, no border) sits behind it.
The left column (40% of the panel; on small panels it may sit up to 10 columns
below its widest row, truncating names with an ellipsis) holds the two bordered
lists with a shared border row; the preview is a
bordered pane on the right; an unbordered hint bar takes the panel's bottom
inside row. Each bordered title carries its pane number: ` [1] Repos `,
` [2] Colorschemes `, ` [3] Preview `.

Focus model:

- `<Tab>`/`<S-Tab>` cycle through all three panes: Tab moves 1 → 2 → 3 → 1 and
  S-Tab the reverse. `1`/`2`/`3` jump straight to a pane. Focusing `3` is
  **read mode**: it leaves the preview's content untouched; `j`/`k` then scroll
  it.
- `<CR>` on a repo row moves focus to the colorscheme list; it installs and
  applies nothing.
- `j`/`k` (and arrows) move the focused list's hand-drawn selection, or scroll
  the preview when it is focused.
- `<Esc>`/`q` close. A `WinEnter` autocmd keeps the focus model (and the
  preview) in sync when focus arrives from elsewhere (mouse, `C-w`); a
  `WinClosed` autocmd tears the panel down if any of its windows is closed.
- The focused pane's border and title use the accent groups; the others the dim
  pair, so a focus change visibly repaints all three frames.

Preview (context-following):

- Repos selection → the repo's README, verbatim (raw markdown, inline code
  dimmed, window `wrap` on). Datasets without a `readme` fall back to the
  wrapped `description`.
- Colorschemes selection → the sample source (`preview.fill`) tinted with the
  selected row's `hlgs` through `preview.tint` (window-local highlight
  namespace; `wrap` off). The window's `Normal` is left unmapped in
  `winhighlight` while tinted so the previewed theme's own colors show.

A "both"-background colorscheme renders as **two** rows (dark then light); other
schemes render one row using their own `bg_type`. Moving in the repo list
re-renders the colorscheme list through `list.sync()` (the `prev_repo` guard;
`list.reset()` runs on every open so a reopened panel is never left with an
empty colorscheme list).

#### Filtering and sorting the lists

The repos pane has one list. `f` cycles its filter: **all** (the default, the
harvested catalogue with install chips), **installed** (dataset repos whose
status is not `none`), and **managed** (what our own pack dir holds,
`install.installed()`). A managed directory whose name matches a dataset repo is
shown under that repo's name and keeps its stars; a theme we only have on disk
is shown by directory name alone. `s` cycles its sort: **stars** (the default,
descending), **name**, and **owner** (ascending). The filter picks the item set
and the sort orders it.

Selecting a managed row renders the dataset's colorscheme rows when the dataset
knows the theme, and otherwise one row per `colors/*.vim|lua` in our clone —
without swatches, because an unharvested theme has no stored highlights and
showing another repo's same-named colorscheme would be a guess. An empty filter
renders a filter-specific note instead of rows, and the preview says the same.

The colorscheme list has its own filter (`f`: all → light → dark, by `row.bg`)
and one sort (`s`: name ascending).

Managing themes happens on the two lists, through buffer-local keys:

- Repos list: `i` installs the selected repo, `x` uninstalls our copy, `u`
  updates it. Each job runs async; further `i`/`x`/`u` for the same repo are
  ignored until it finishes, and the rows are re-rendered (with fresh status
  chips) when it does. `u` needs the theme's repo URL, which we only know for
  themes the dataset carries; on a managed theme we cannot place it says so
  instead of guessing.
- Repos list: `<CR>` moves focus to the colorscheme list; it installs and
  applies nothing.
- Colorschemes list: `<CR>` applies the selected colorscheme. An installed theme
  (`ours`/`shadow`/`elsewhere`) applies immediately — `elsewhere` is provided by
  the user's own config, so it is already on `runtimepath`. A theme with status
  `none` is installed first, and the same selected row is applied only when the
  install reports success; a failed install leaves the current colorscheme
  alone.

A repos filter change and every finished job call `list.forget()`, which forces
`list.sync()` to rebuild the colorscheme pane even when the selected item looks
unchanged; a finished job also calls `list.refresh()` (fresh statuses and pack
dir scan) and drops the preview's cache key.

Repo rows carry an install chip before the stars: `✓` (ours, accent), `≡`
(elsewhere, dim), `⚠` (shadow, warn), blank for `none`. Statuses are probed
once per open (`list.statuses()`, keyed by repo name) and re-probed after each
job, so the panel never stats the filesystem per frame.

Chrome groups (`ThemeUI*`) are (re)defined on each open from the user's active
colorscheme (`Normal`, `Title`, `LineNr`, `CursorLine`, `StatusLine`, `Pmenu`,
`NonText`), so the panel blends into the current editor; the preview is the only
surface that borrows another theme's colors.

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
   duration of a session. Every colorscheme surface (panel rows and previews,
   picker previews) is name-keyed through `query_hl`, so a collision picks one
   repo's colors and ignores the other.
4. **The panel's only apply path is `<CR>` on a colorscheme row.** Previews
   still never apply anything (invariant 8). A repo with status
   `ours`/`shadow`/`elsewhere` applies immediately; status `none` installs the
   repo first and applies the same selected row only if the install succeeds.
   `<CR>` on a repo row only moves focus to the colorscheme list.
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
   `preview.fill` is the only writer of the *sample* buffer; the panel's readme
   view writes its own lines into the same pane buffer (and stops the lua
   treesitter highlighter first, or it would color the markdown as code).
9. **The picker's preview is hardcoded to the `dark` background**
   (`data.query_hl(entry.value, "dark")`). The panel uses each row's real
   background.
10. **`pool.lua` splits builtin from installed by path prefix**, comparing each
    `colors/*` file against `$VIMRUNTIME`: files under that directory are
    builtin, everything else is installed. `#builtin` and `#all` depend on this.
11. **`ui/list.lua` resets `prev_repo` in `reset()`, called from `open()`.** The
    `sync(repo)` guard re-renders the colorscheme list only when the selected
    repo changed; without the reset, reopening the panel with the same first
    repo selected made `sync()` return early and left the colorscheme list
    empty.
12. **The panel is a singleton.** `ui/init.lua` keeps a module-level `active`
    panel; `open()` focuses the existing panel if one is valid. `M.close(p)`
    takes the panel table and returns immediately for a `nil` argument — it does
    **not** fall back to `active`, so `require("theme.ui").close()` with no
    argument is a no-op. The close paths that work are the buffer keymaps and
    the `WinClosed` autocmd, both of which capture the panel object. The panel
    state holds the three panes in `state.panes` plus `state.hint` and
    `state.backdrop`; there is no frame window and no debounce timer.
13. **Swatch columns in `ui/render.lua` are byte offsets**, and the glyph
    (`∙`, U+2219) is 3 bytes wide but 1 cell wide. Extmark columns must stay
    byte-based while padding stays display-width-based; mixing the two misaligns
    the swatches.
14. **The focus model is explicit.** `<Tab>`/`<S-Tab>` cycle through all three
    panes, wrapping (Tab: `1` → `2` → `3` → `1`; S-Tab the reverse);
    `1`/`2`/`3` jump by number. Focusing the preview is *read mode*: `M.follow`
    only re-evaluates the preview when the focused pane is a list, so focusing
    the preview must not change its content or title.
15. **Swatch groups are minted per render, inside the pane's namespace**, with
    the dataset's stored fg/bg; a group with neither is skipped. The window is
    pointed at that namespace (`nvim_win_set_hl_ns`) after the render, so the
    chips resolve to the dataset's colors and never to a stale global group.
16. **The chrome palette comes from the active colorscheme.** `ui/chrome.lua`
    mines `Normal`/`Title`/`LineNr`/`CursorLine`/`StatusLine`/`Pmenu`/`NonText`
    on every open and defines the `ThemeUI*` groups globally. The preview pane
    is the only surface that borrows another theme's colors (through
    `preview.tint`), and its `Normal` is deliberately left out of its
    `winhighlight` while tinted so the previewed theme's `Normal` shows.
17. **`repo.readme` is optional.** The harvester stores a repo's README text
    (capped at 8000 chars) in `repo.readme`; datasets built before the field
    existed omit it. The panel falls back to the wrapped `description`, so both
    shapes must keep working.
18. **The installer writes to its own pack dir and nothing else.**
    `install.dir(repo)` is `stdpath("data")/site/pack/theme/start/<basename>`;
    `install.uninstall` removes only that directory, and no code path ever
    writes to a path the user's own config owns.
19. **Installs are atomic and self-cleaning.** Clone into `<dir>.tmp-<pid>`,
    verify `colors/`, then `fs_rename` into place; every failure path removes
    the temp dir, so a failed install leaves neither a partial clone nor a
    stray temp dir. The clone is async (`vim.system`); the callback runs in a
    fast event context and does its `vim.*` work after `vim.schedule`.
20. **`status` precedence is `shadow` > `ours` > `elsewhere` > `none`**, and
    "provided elsewhere" ignores runtimepath entries under our pack dir and
    under `$VIMRUNTIME`. The panel only ever detects a conflict: `elsewhere`
    blocks `i`, `shadow` is notified once per open, and `x` removes our copy
    only.
21. **`<CR>` on a colorscheme row applies it when the repo is installed**
    (`ours`/`shadow`/`elsewhere`); a `none` repo is installed first and applied
    only on success. `<CR>` on a repo row only focuses the colorscheme list.
22. **The lists are filter + sort views.** The repos pane's `state.filter` is
    `"all"` (the dataset, with chips), `"installed"`, or `"managed"` (our pack
    dir, from `install.installed()`); `f` cycles it. Its `state.sort_repo` is
    `"stars"`, `"name"`, or `"owner"`; `s` cycles it. The colorscheme pane has
    its own `state.filter_cs` (`"all"`/`"light"`/`"dark"`, by `row.bg`) and a
    single name sort. A managed row is ours already, so `i` is refused through
    the normal status check rather than the filter. Any trigger that changes the
    rows drops the preview's cache key.
23. **A Managed row is `{ name, dir, repo }`.** `name` is the dataset repo name
    when the dataset knows a repo of that directory name (joined on the
    basename, first dataset match wins) and the directory name otherwise;
    `repo = nil` marks a theme we only have on disk. Such a theme's colorscheme
    rows come from its own `colors/` and carry no `hlgs` — never borrow another
    repo's same-named colorscheme — and `u` refuses, because the repo URL it
    would re-clone from is exactly what is missing.
24. **`list.forget()` is how the colorscheme pane is forced to re-render.**
    `sync()` normally skips when the selected item is unchanged (the
    `prev_repo` guard); `forget()` sets a one-shot `forced` flag that makes the
    next `sync()` rebuild anyway. A repos filter change and every finished job
    call it, and `refresh()` (statuses + the pack dir scan) must be cleared by
    anything that changes the filesystem.

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
  "theme.preview","theme.preview_code","theme.ui","theme.ui.render",
  "theme.ui.chrome","theme.ui.list","theme.install",
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
