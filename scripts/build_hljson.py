# Hl.json data layout (consumed by lua/theme/data.lua):
#
# { num_repo: int, hlg_keys: string[], repos: Repo[] }
#
# Repo = { name: "owner/repo", stars: int, description: string,
#          num_colorschemes: int, colorschemes: Colorscheme[] }
# Colorscheme = { name: string, repo: string,
#                 bg_type: "light"|"dark"|"both",
#                 hlgs_light: (Hlg?)[?], hlgs_dark: (Hlg?)[?] }
#
# Hlg arrays are positionally indexed by hlg_keys; null = unset group for
# that background. Hlg holds the attrs nvim_set_hl accepts verbatim
# (fg, bg, bold, italic, reverse, underline, sp, blend, ...) with 24-bit
# int colors. Terminal-only attrs (cterm/ctermfg/ctermbg) are stripped.

import re
import http.client
import shutil
import sys
import json
import io
import os
import subprocess
import time
import tempfile
import tarfile
from dataclasses import dataclass, field
from typing import Literal
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HighlightGroups = dict[str, dict]  # hlg_key -> attrs {fg, bg, bold, ...}

# vim.o.background
Background = Literal["light", "dark"]

@dataclass
class Colorscheme:
    name: str
    repo: str
    bg_type: Literal["light", "dark", "both"] = "dark"
    hlgs_light: HighlightGroups | None = None
    hlgs_dark: HighlightGroups | None = None


@dataclass
class ThemeRepo:
    name: str
    default_branch: str
    stars: int = 0
    description: str = ""
    num_colorschemes: int = 0
    colorschemes: list[Colorscheme] = field(default_factory=list)


TREESITTER_KEYS = [ "@boolean", "@comment", "@comment.documentation",
    "@constant", "@constant.builtin", "@constructor", "@function",
    "@function.builtin", "@function.call", "@function.method.call", "@keyword",
    "@keyword.conditional", "@keyword.function", "@keyword.operator",
    "@keyword.repeat", "@keyword.return", "@number", "@operator", "@property",
    "@punctuation.bracket", "@punctuation.delimiter", "@string", "@variable",
    "@variable.member", "@variable.parameter",
]
CHROME_KEYS = [ "Normal", "LineNr", "CursorLineNr", "CursorLine", "Visual",
    "Search", "StatusLine", "StatusLineNC", "Pmenu", "PmenuSel",
    "WinSeparator", "SignColumn", "NonText", "Title",
]
KEY_NAMES = TREESITTER_KEYS + CHROME_KEYS

# terminal-only attrs, useless for GUI rendering of list/preview
STRIP_ATTRS = {"cterm", "ctermfg", "ctermbg"}


def strip_attrs(attrs: dict) -> dict:
    return {k: v for k, v in attrs.items() if k not in STRIP_ATTRS}


QUERIES_KEYWORDS = (
    "topic:neovim-colorscheme",
    "topic:nvim-colorscheme",
    "topic:neovim-theme",
    "neovim colorscheme",
    "nvim colorscheme",
)
# maximum number of results for a single keyword search
SINGLE_KEYWORD_CUTOFF = 1000
REPO_STARS_THRESHOLD = 50
LUA_SCRIPT = Path(__file__).parent / "sample.lua"


def fetch(query: str, page: int) -> dict:
    url = (
        "https://api.github.com/search/repositories?q="
        + urllib.parse.quote(query)
        + f"&sort=stars&order=desc&per_page=100&page={page}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "theme.nvim"})
    while True:
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code != 403:
                raise
            reset = int(e.headers.get("X-RateLimit-Reset", time.time() + 60))
            wait = max(reset - time.time() + 1, 5)
            print(f"Rate limit. Retrying at {wait:.0f}s")
            time.sleep(wait)
        except (http.client.HTTPException, urllib.error.URLError, 
                TimeoutError, OSError) as e:
            print(f"Network error: {e}. Retrying in 5s")
            time.sleep(5)


def gh_search() -> list[ThemeRepo]:
    """Search for nvim theme repos on Github"""
    repos: dict[str, ThemeRepo] = {}

    for query in QUERIES_KEYWORDS:
        page = 1
        got: dict[str, ThemeRepo] = {}
        while True:
            try:
                data = fetch(query, page)
            except urllib.error.HTTPError as e:
                if e.code == 422:
                    break
                raise
            total = data.get("total_count", 0)
            items = data.get("items", [])[:SINGLE_KEYWORD_CUTOFF]
            if not items:
                break
            got.update({
                item["full_name"]: ThemeRepo(
                    name=item["full_name"],
                    default_branch=item["default_branch"],
                    stars=item.get("stargazers_count", 0),
                    description=item.get("description") or "",
                )
                for item in items 
                if item.get("stargazers_count", 0) >= REPO_STARS_THRESHOLD
            })
            if len(got) >= total or len(got) >= SINGLE_KEYWORD_CUTOFF:
                break
            page += 1

            print(
                f"Searching {query} "
                f"[{len(got)}/{SINGLE_KEYWORD_CUTOFF}]\r",
                end=""
            )
            time.sleep(7)
        repos.update(got)
        print(f"\nSearched {query}: got {len(got)} repos, total {len(repos)}")

    return sorted(repos.values(), key=lambda r: r.name)


def download(repo: str, branch: str, tempdir: Path) -> Path | None:
    dst = tempdir / repo.replace("/", "__")
    url = f"https://codeload.github.com/{repo}/tar.gz/refs/heads/{branch}"
    data = None
    while True:
        try:
            with urllib.request.urlopen(
                urllib.request.Request(
                    url, headers={"User-Agent": "theme.nvim"}
                ),
                timeout=60,
            ) as r:
                data = r.read()
            break
        except urllib.error.HTTPError:
            return None
        except (http.client.HTTPException, urllib.error.URLError,
                TimeoutError, OSError) as e:
            print(f"Network error downloading {repo}: {e}. Retrying...")
            time.sleep(5)
    if not data:
        return None
    shutil.rmtree(dst, ignore_errors=True)
    tmp = tempdir / f"{dst.name}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        tf.extractall(tmp)
    next(tmp.iterdir()).rename(dst)  # tarball top-level is repo-branch/
    tmp.rmdir()
    return dst


def extract_cs_hlgs(
    repo_dir: str, colorscheme: str, bg: Background
) -> HighlightGroups:
    """Given colorscheme, extract and return its highlight group"""
    env = {
        **os.environ,
        "CS_DIR": repo_dir,
        "CS_NAME": colorscheme,
        "HLG_KEYS": json.dumps(KEY_NAMES),
    }
    p = subprocess.run(
        [ "nvim", "--headless", "-u", "NONE", "-i", "NONE",
          "-c", f"set background={bg}", "-l", str(LUA_SCRIPT) ],
        capture_output=True, text=True, env=env, timeout=60, check=False,
    )
    if p.returncode != 0:
        raise RuntimeError(f"Nvim output error: {p.stderr.strip()[:200]}")
    sample = re.search(
        r"\[\[\[THEME\.NVIM SAMPLING START\]\]\]\n"
        r"(.*?)"
        r"\[\[\[THEME\.NVIM SAMPLING END\]\]\]\n",
        p.stderr, re.DOTALL
    )
    if sample is None:
        raise RuntimeError("No sampling output")
    raw = json.loads(sample.group(1))
    return {k: strip_attrs(v) for k, v in raw.items() if v}


def detect_background(hlgs: HighlightGroups) -> Background:
    """Detect whether the colorscheme is light or dark
    Based on the median luma of all highlight groups
    """

    def luma(color: int | None) -> float | None:
        if color is None:
            return None
        return (
            0.2126 * ((color >> 16) & 0xFF)
            + 0.7152 * ((color >> 8) & 0xFF)
            + 0.0722 * (color & 0xFF)
        )

    bg_lumas = sorted(
        lu for lu in (luma(g.get("bg")) for g in hlgs.values()) if lu is not None
    )
    if bg_lumas:
        return "light" if bg_lumas[len(bg_lumas) // 2] > 128 else "dark"

    fg_lumas = sorted(
        lu for lu in (luma(g.get("fg")) for g in hlgs.values()) if lu is not None
    )
    if fg_lumas:
        return "dark" if fg_lumas[len(fg_lumas) // 2] > 128 else "light"

    # Fallback to dark
    return "dark"


def extract_colorschmes(
    repo_dir: Path,
) -> list[Colorscheme]:
    """Given theme repo, extract all colorschemes and their highlight groups
    returns list of Colorschemes
    """
    # 1. extract colorscheme names under colors/
    cs_names = sorted(
        p.stem for p in (repo_dir / "colors").glob("*")
        if p.suffix in (".vim", ".lua")
    )

    def set_hlgs_by_bg(cs: Colorscheme, bg: Background, hlgs: HighlightGroups):
        if bg == "light":
            cs.hlgs_light = hlgs
        else:
            cs.hlgs_dark = hlgs

    result: list[Colorscheme] = []
    for name in cs_names:
        try:
            cs = Colorscheme(name=name, repo=str(repo_dir), bg_type="both")
            for bg in ("light", "dark"):
                hlgs = extract_cs_hlgs(str(repo_dir), name, bg)
                detect_bg = detect_background(hlgs)
                if detect_bg == "light":
                    cs.hlgs_light = hlgs
                else:
                    cs.hlgs_dark = hlgs
            if cs.hlgs_light is not None and cs.hlgs_dark is not None:
                cs.bg_type = "both"
            elif cs.hlgs_light is not None:
                cs.bg_type = "light"
            elif cs.hlgs_dark is not None:
                cs.bg_type = "dark"
                
        except Exception as e:
            print(f"Fail on colorscheme {repo_dir.name}/{name}: {e}")
            continue

    return result


def resolve_theme_repos(repos: list[ThemeRepo]):
    """Resolve colorschemes from repositories
    repos: repositories, list of { name, default_branch, stars, description }
    returns repo name -> its colorschemes
    """
    resolved = 0
    total_colorschemes = 0
    for repo in repos:
        print(
            f"Resolving progress: "
            f"{resolved}/{len(repos)} repos, "
            f"{total_colorschemes} colorschemes\r",
            end=""
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                repo_dir = download(repo.name, repo.default_branch, Path(tmpdir))
                if repo_dir is None:
                    continue
                colorschemes = extract_colorschmes(repo_dir)
                resolved += 1
                total_colorschemes += len(colorschemes)
            except Exception as e:
                print(f"Fail on {repo.name}: {e}")
                continue
        repo.num_colorschemes = len(colorschemes)
        repo.colorschemes = colorschemes

    print(f"\nResolved {resolved} repos, {total_colorschemes} colorschemes")


def build_json(
    repos: list[ThemeRepo], path: Path
) -> tuple[int, int]:
    """Build the hl.json document"""
    doc = {
        "num_repo": len(repos),
        "hlg_keys": KEY_NAMES,
        "repos": repos
    }
    text = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    Path(path).write_text(text)
    return len(repos), len(text)


def main():
    """Usage: python build_hljson.py [output_path]"""
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("lua/theme/hl.json")

    print(f"Building hl.json to {dst}")

    print("Searching for theme repos on Github...")
    repos = gh_search()
    print("Resolving colorschemes from repos...")
    resolve_theme_repos(repos)
    print("Building hl.json...")
    count, size = build_json(repos, dst)

    print(f"Finish! Wrote {count} repos, {size} bytes to {dst}")


if __name__ == "__main__":
    main()
