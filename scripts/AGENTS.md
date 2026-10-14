# AGENTS.md — `scripts/`

The dataset pipeline. `scripts/build_hljson.py` harvests highlight groups from
GitHub theme repositories and writes `lua/theme/hl.json`; `scripts/sample.lua`
is the script it runs *inside* headless Neovim. See `docs/architecture.md` for
the flow diagram and how the runtime consumes the result.

## Rebuilding the dataset

```sh
# From the repo root (the default output path is relative):
python3 scripts/build_hljson.py                 # writes lua/theme/hl.json
python3 scripts/build_hljson.py /tmp/out.json   # optional explicit destination
```

Requirements: Python 3.10+ (the code uses `X | None` annotations), `nvim` on
`PATH`, and network access. It is a long, network-bound run: unauthenticated
GitHub search is rate-limited, and every colorscheme is sampled twice in a
separate headless Neovim process.

`lua/theme/hl.json` is **generated and committed**. Never hand-edit it. If you
change what is sampled (the key lists, the attribute stripping, the background
heuristic), you must rebuild the whole dataset — partial edits will disagree
with the sampler and are not reproducible.

## Pipeline contract

`main()` runs three stages: `gh_search()` → `resolve_theme_repos()` →
`build_json()`.

### 1. Search (`gh_search`)

- Five keyword queries (`QUERIES_KEYWORDS`), sorted by stars, `per_page=100`.
- Only repos with `stargazers_count >= REPO_STARS_THRESHOLD` (50) are kept.
- Paginates up to `SINGLE_KEYWORD_CUTOFF` (1000) results per keyword, sleeping
  7 s between pages.
- On HTTP 403 (rate limit) it sleeps until `X-RateLimit-Reset`, then retries;
  on transient network errors it retries after 5 s; HTTP 422 breaks out of the
  current keyword. There is **no token** — treat the run as
  rate-limit-bound, not CPU-bound.

### 2. Resolve (`resolve_theme_repos`)

- Downloads each repo's tarball from `codeload.github.com` into a temp dir
  (network errors retry every 5 s; an HTTP error such as 404 skips the repo).
- Colorscheme names come from `colors/*.{vim,lua}` (basename, no extension).
- Each name is sampled once per forced background (`light`, `dark`).
- A colorscheme that fails to sample (non-zero exit, missing markers, bad JSON)
  is skipped with a printed message and does not abort the repo.

### 3. Build (`build_json`)

- Repos with no successfully sampled colorschemes are omitted entirely.
- Output is compact JSON (`separators=(",", ":")`, `ensure_ascii=False`), one
  document mapping `repo → Repo`, matching the schema documented in the header
  comments of this file and of `lua/theme/data.lua`.

## Sampling contract (`sample.lua`)

Invoked as:

```sh
CS_DIR=<repo checkout> CS_NAME=<colorscheme> HLG_KEYS='["Normal", …]' \
  nvim --headless -u NONE -i NONE -c 'set background=<bg>' -l scripts/sample.lua
```

What it guarantees:

- Prepends `CS_DIR` to `runtimepath`, runs `highlight clear`, then applies
  `CS_NAME`. If the colorscheme did not actually take effect it exits 1.
- Reads the key list from `HLG_KEYS` (a JSON array) and collects each group that
  has `fg`, `bg`, or `link`, following `:hi` links with a seen-set to avoid
  cycles.
- Copies **only scalar attributes** (`number`, `boolean`, `string`). This is
  load-bearing: `nvim_get_hl` returns `vim.NIL` for missing fields, which
  JSON-encodes as `0` and would corrupt colours to `0x000000`.
- Writes the JSON payload to **stderr** wrapped in the markers
  `[[[THEME.NVIM SAMPLING START]]]` and `[[[THEME.NVIM SAMPLING END]]]`. The
  Python side extracts the payload with a regex between those exact markers —
  keep them byte-for-byte if you edit either side. Do not write other output to
  stderr without adjusting the parser.

## Attribute and background rules

- `KEY_NAMES` = `TREESITTER_KEYS` (`@boolean`, `@comment`, …) + `CHROME_KEYS`
  (`Normal`, `LineNr`, `Visual`, `Search`, `StatusLine`, `Pmenu`, …).
- `STRIP_ATTRS` (`cterm`, `ctermfg`, `ctermbg`) are removed — the dataset is for
  GUI rendering of the list and preview, where terminal-only attrs are noise.
- `detect_background` classifies each sample by the median luma of its `bg`
  values, falling back to `fg`, then to `dark`. Because each colorscheme is
  sampled under both forced backgrounds and each sample is stored under its own
  detected background, a scheme that reads dark in both runs keeps only
  `hlgs.dark`. `bg_type` is then derived in `Colorscheme.__post_init__`:
  `"both"` iff both `light` and `dark` are present, else whichever exists
  (`"dark"` as the final default).
