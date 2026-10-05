# Hl.json data layout (consumed by lua/theme/data.lua):
#
# { num_repo: int, hlg_keys: string[], repos: Repo[] }
#
# Repo = { name: "owner/repo", stars: int, description: string,
#          num_colorschemes: int, colorschemes: Colorscheme[] }
# Colorscheme = { name: string, bg_type: "light"|"dark"|"both",
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
from collections import defaultdict
from dataclasses import dataclass
from typing import Literal
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HighlightGroups = dict[str, dict]  # hlg_key -> attrs {fg, bg, bold, ...}

@dataclass
class Colorscheme:
    name: str
    repo: str
    is_light: bool
    hlgs: HighlightGroups


# === Highlight group keys ===

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


# === Query themes ===

@dataclass
class ThemeRepo:
    name: str
    default_branch: str
    stars: int = 0
    description: str = ""


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


# === Resolve theme highlight groups ===

Background = Literal["light", "dark"]


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
) -> HighlightGroups | None:
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
        print(f"Nvim output error: {p.stderr.strip()[:200]}")
        return None
    try:
        sample = re.search(
            r"\[\[\[THEME\.NVIM SAMPLING START\]\]\]\n"
            r"(.*?)"
            r"\[\[\[THEME\.NVIM SAMPLING END\]\]\]\n",
            p.stderr, re.S
        )
        if sample is None:
            raise RuntimeError("No sampling output")
        raw = json.loads(sample.group(1))
        return {k: strip_attrs(v) for k, v in raw.items() if v}
    except Exception:
        print(f"Nvim output error: {p.stderr.strip()[:200]}")
    return None


def check_background(hlgs: HighlightGroups | None) -> Background | None:
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

    if not hlgs:
        return None

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

    return None


def extract_colorschmes(
    repo_dir: Path,
) -> dict[tuple[str, Background], HighlightGroups]:
    """Given theme repo, extract all colorschemes and their highlight groups
    returns list of dict: { (colorscheme, background): hlgs }
    """
    # 1. extract colorscheme names under colors/
    cs_names = sorted(
        p.stem for p in (repo_dir / "colors").glob("*")
        if p.suffix in (".vim", ".lua")
    )

    result: dict[tuple[str, Background], HighlightGroups] = {}
    for cs in cs_names:
        # 2. extract hlgs on both light and dark backgrounds
        light_hlgs = extract_cs_hlgs(str(repo_dir), cs, "light")
        dark_hlgs = extract_cs_hlgs(str(repo_dir), cs, "dark")

        # 3. detect colorscheme's background type
        bg_l, bg_d = check_background(light_hlgs), check_background(dark_hlgs)

        if bg_d is not None and dark_hlgs is not None:
            result.setdefault((cs, bg_d), dark_hlgs)
        if bg_l is not None and light_hlgs is not None:
            result.setdefault((cs, bg_l), light_hlgs)

    return result


def resolve_theme_repos(repos: list[ThemeRepo]) -> dict[str, list[Colorscheme]]:
    """Resolve colorschemes from repositories
    repos: repositories, list of { name, default_branch, stars, description }
    returns repo name -> its colorschemes (deduped across repos by stars)
    """
    # (colorscheme_name, bg) -> (Colorscheme, stars)
    result: dict[tuple[str, Background], tuple[Colorscheme, int]] = {}
    resolved = 0
    for repo in repos:
        print(
            f"Resolving progress: "
            f"{resolved}/{len(repos)} repos, "
            f"{len(result)} colorschemes\r",
            end=""
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_dir = download(repo.name, repo.default_branch, Path(tmpdir))
            if repo_dir is None:
                continue
            try:
                colorschemes = extract_colorschmes(repo_dir)
                resolved += 1
            except Exception as e:
                print(f"Fail on {repo.name}: {e}")
                continue
        for (cs, bg), hlgs in colorschemes.items():
            # Save same colorschemes with highest stars
            if (cs, bg) in result and repo.stars <= result[(cs, bg)][1]:
                continue
            result[(cs, bg)] = (
                Colorscheme(name=cs, repo=repo.name, is_light=bg == "light",
                            hlgs=hlgs),
                repo.stars
        )

    print(f"\nResolved {resolved} repos, {len(result)} colorschemes")
    grouped: dict[str, list[Colorscheme]] = defaultdict(list)
    for cs, _ in result.values():
        grouped[cs.repo].append(cs)
    return grouped


def build_json(
    grouped: dict[str, list[Colorscheme]], repos: list[ThemeRepo], path: Path
) -> tuple[int, int]:
    """Build the hl.json document"""
    meta = {r.name: r for r in repos}

    json_repos = []
    for repo_name in sorted(grouped, key=lambda n: -meta[n].stars):
        cs_map: dict[str, dict[str, HighlightGroups]] = defaultdict(dict)
        for cs in grouped[repo_name]:
            cs_map[cs.name]["light" if cs.is_light else "dark"] = cs.hlgs

        colorschemes = []
        for cs_name in sorted(cs_map):
            bgs = cs_map[cs_name]
            bg_type = "both" if len(bgs) == 2 else next(iter(bgs))
            cs_json = {"name": cs_name, "bg_type": bg_type}
            for bg in ("light", "dark"):
                if bg in bgs:
                    cs_json[f"hlgs_{bg}"] = [
                        bgs[bg].get(key) for key in KEY_NAMES
                    ]
            colorschemes.append(cs_json)

        r = meta[repo_name]
        json_repos.append({
            "name": r.name,
            "stars": r.stars,
            "description": r.description,
            "num_colorschemes": len(colorschemes),
            "colorschemes": colorschemes,
        })

    doc = {"num_repo": len(json_repos), "hlg_keys": KEY_NAMES, "repos": json_repos}
    text = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    Path(path).write_text(text)
    return len(json_repos), len(text)


def main():
    """Usage: python build_hljson.py [output_path]"""
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("lua/theme/hl.json")

    print(f"Building hl.json to {dst}")

    print("Searching for theme repos on Github...")
    repos = gh_search()
    print("Resolving colorschemes from repos...")
    grouped = resolve_theme_repos(repos)
    n_cs = sum(len(v) for v in grouped.values())
    print(f"Found {n_cs} colorschemes in {len(grouped)} repos, building hl.json...")
    count, size = build_json(grouped, repos, dst)

    print(f"Finish! Wrote {count} repos, {size} bytes to {dst}")


if __name__ == "__main__":
    main()
