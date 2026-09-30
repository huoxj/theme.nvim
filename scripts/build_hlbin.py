# Hl.bin data layout:
#
# offset  size                  content
# 0       16                    header: magic(8) key_count(2)
#                                       colorscheme_count(2)
#                                       name_len(2) repo_name_len(2)
# 16      key_count*name_len    vocab: highlight group key names
# ...     cs_count*record       record: colorscheme records
#
# record = colorscheme_name(name_len)
#        + github_repo(repo_name_len)
#        + flags(1)
#        + highlight groups : fg_bitmap | bg_bitmap | fg_colors | bg_colors
# bitmap = ceil(key_count/8) bytes, each bit indicates whether the group
#          has fg/bg in this background
# colors = key_count×3 bytes, 3 bytes big-endian RGB.

import re
import shutil
import struct
import sys
import json
import io
import os
import subprocess
import time
import tempfile
import tarfile
from dataclasses import dataclass
from typing import Literal
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


@dataclass
class HighlightGroup:
    fg: int | None
    bg: int | None

HighlightGroups = dict[str, HighlightGroup]

@dataclass
class Colorscheme:
    name: str
    repo: str
    is_light: bool
    hlgs: dict[str, HighlightGroup]


# === Dump hl bin ===

MAGIC = b"HLBIN\x00\x00\x01"
HEADER_FORMAT = "<8sHHHH"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
NAME_LEN = 32
REPO_NAME_LEN = 144

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
KEY_COUNT = len(KEY_NAMES)
BITMAP_LEN = (KEY_COUNT + 7) // 8


def pack_name(name: str, length: int) -> bytes:
    raw = name.encode()
    if len(raw) > length:
        raise ValueError(f"Name exceeds max length {length}: {name}")
    return raw.ljust(length, b"\x00")


def resolve_colors(
    hlgs: HighlightGroups, hlg_key: str
) -> tuple[int | None, int | None]:
    if hlg_key not in hlgs:
        return None, None
    return hlgs[hlg_key].fg, hlgs[hlg_key].bg


def pack_record(cs: Colorscheme) -> bytes:
    out = bytearray()

    out += pack_name(cs.name, NAME_LEN)
    out += pack_name(cs.repo, REPO_NAME_LEN)

    # Flags
    flags = 0
    flags |= 1 if cs.is_light else 0
    out += struct.pack("<B", flags)

    # Palette: fg_bitmap | bg_bitmap | fg_colors | bg_colors
    fg_bitmap = bytearray(BITMAP_LEN)
    bg_bitmap = bytearray(BITMAP_LEN)
    fg_colors = bytearray(KEY_COUNT * 3)
    bg_colors = bytearray(KEY_COUNT * 3)

    for index, hlg_key in enumerate(KEY_NAMES):
        fg, bg = resolve_colors(cs.hlgs, hlg_key)
        byte_index, mask = index // 8, 1 << (index % 8)
        if fg is not None:
            fg_bitmap[byte_index] |= mask
            fg_colors[index * 3 : index * 3 + 3] = (fg).to_bytes(3, "big")
        if bg is not None:
            bg_bitmap[byte_index] |= mask
            bg_colors[index * 3 : index * 3 + 3] = (bg).to_bytes(3, "big")

    out += bytes(fg_bitmap) + bytes(bg_bitmap) + bytes(fg_colors) + bytes(bg_colors)

    return bytes(out)


def build_bin(colorschemes: list[Colorscheme], path: Path):
    ordered = sorted(colorschemes, key=lambda cs: cs.name.encode())

    assert KEY_COUNT <= 65535, "Too many hl groups, max 65535"
    assert len(ordered) <= 65535, "Too many themes, max 65535"
    header = bytearray(
        struct.pack(
            HEADER_FORMAT, MAGIC, KEY_COUNT, len(ordered), NAME_LEN, REPO_NAME_LEN
        )
    )
    assert len(header) == HEADER_SIZE

    vocab = bytearray()
    for hlg in KEY_NAMES:
        vocab += pack_name(hlg, NAME_LEN)

    records = bytearray()
    for cs in ordered:
        records += pack_record(cs)

    data = header + vocab + records
    Path(path).write_bytes(bytes(data))
    return len(ordered), len(data)


# === Query themes ===

@dataclass
class ThemeRepo:
    name: str
    default_branch: str


QUERIES_KEYWORDS = (
    "topic:neovim-colorscheme",
    "topic:nvim-colorscheme",
    "topic:neovim-theme",
    "neovim colorscheme",
    "nvim colorscheme",
)
# maximum number of results for a single keyword search
SINGLE_KEYWORD_CUTOFF = 1000
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


def gh_search() -> list[ThemeRepo]:
    """Search for nvim theme repos on Github"""
    repos: dict[str, ThemeRepo] = {}

    for query in QUERIES_KEYWORDS:
        page = 1
        got: dict[str, ThemeRepo] = {}
        while True:
            data = fetch(query, page)
            total = data.get("total_count", 0)
            items = data.get("items", [])[:SINGLE_KEYWORD_CUTOFF]
            if not items:
                break
            got.update(
                {
                    item["full_name"]: ThemeRepo(
                        name=item["full_name"], default_branch=item["default_branch"]
                    )
                    for item in items
                }
            )
            if len(got) >= total or len(got) >= SINGLE_KEYWORD_CUTOFF:
                break
            page += 1
            time.sleep(7)
        repos.update(got)
        print(f"Searched {query}: got {len(got)} repos, total {len(repos)}")

    return sorted(repos.values(), key=lambda r: r.name)


# === Resolve theme highlight groups ===

Background = Literal["light", "dark"]


def download(repo: str, branch: str, tempdir: Path) -> Path | None:
    dst = tempdir / repo.replace("/", "__")
    url = f"https://codeload.github.com/{repo}/tar.gz/refs/heads/{branch}"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, headers={"User-Agent": "theme.nvim"}),
            timeout=60,
        ) as r:
            data = r.read()
    except urllib.error.HTTPError:
        return None
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
        capture_output=True, text=True, env=env, timeout=60, check=True,
    )
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
        return {
            k: HighlightGroup(fg=v.get("fg"), bg=v.get("bg"))
            for k, v in raw.items()
        }
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
        lu for lu in (luma(g.bg) for g in hlgs.values()) if lu is not None
    )
    if bg_lumas:
        return "light" if bg_lumas[len(bg_lumas) // 2] > 128 else "dark"

    fg_lumas = sorted(
        lu for lu in (luma(g.fg) for g in hlgs.values()) if lu is not None
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
        p.stem for p in (repo_dir / "colors").glob("*") if p.suffix in (".vim", ".lua")
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


def resolve_theme_repos(repos: list[ThemeRepo]) -> list[Colorscheme]:
    """Resolve colorschemes from repositories
    repos: repositories, list of { name: ..., default_branch: ... }
    returns list of colorschemes { name, repo, is_light, hlgs }
    """
    result: list[Colorscheme] = []
    resolved = 0
    for repo in repos:
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
            result.append(Colorscheme(
                name=cs, repo=repo.name, is_light=bg == "light", hlgs=hlgs
            ))

    print(f"Resolved {resolved} repos, {len(result)} colorschemes")
    return result


def main():
    """Usage: python build_hlbin.py [output_path]"""
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("lua/theme/hl.bin")

    repos = gh_search()
    colorschemes = resolve_theme_repos(repos)
    count, size = build_bin(colorschemes, dst)

    print(f"Wrote {count} themes, {size} bytes to {dst}")


if __name__ == "__main__":
    main()

