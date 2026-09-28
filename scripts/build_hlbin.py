# Hl.bin data layout:
#
#   offset  size                  content
#   0       16                    header: magic(8) key_count(2) theme_count(2)
#                                         name_len(2) repo_name_len(2)
#   16      key_count×name_len    vocab: highlight group names
#   ...     theme_count×record    record: highlight group records
#
#   record = colorscheme_name(name_len)
#          + github_repo(repo_name_len)
#          + flags(1)
#          + palette : fg_bitmap | bg_bitmap | fg_colors | bg_colors
#   bitmap = ceil(key_count/8) bytes, each bit indicates whether the group
#            has fg/bg in this background
#   colors = key_count×3 bytes, 3 bytes big-endian RGB.

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
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# === Dump hl bin ===

MAGIC = b"HLBIN\x00\x00\x01"
HEADER_FORMAT = "<8sHHHH"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
NAME_LEN = 32
REPO_NAME_LEN = 144

TREESITTER_KEYS = [
    "@boolean", "@comment", "@comment.documentation", "@constant",
    "@constant.builtin", "@constructor", "@function", "@function.builtin",
    "@function.call", "@function.method.call", "@keyword",
    "@keyword.conditional", "@keyword.function", "@keyword.operator",
    "@keyword.repeat", "@keyword.return", "@number", "@operator",
    "@property", "@punctuation.bracket", "@punctuation.delimiter", "@string",
    "@variable", "@variable.member", "@variable.parameter",
]
CHROME_KEYS = [
    "Normal", "LineNr", "CursorLineNr", "CursorLine", "Visual", "Search",
    "StatusLine", "StatusLineNC", "Pmenu", "PmenuSel", "WinSeparator",
    "SignColumn", "NonText", "Title",
]
KEY_NAMES = TREESITTER_KEYS + CHROME_KEYS
KEY_COUNT = len(KEY_NAMES)
BITMAP_LEN = (KEY_COUNT + 7) // 8


def pack_name(name: str, length: int) -> bytes:
    raw = name.encode()
    if len(raw) > length:
        raise ValueError(f"Name exceeds max length {length}: {name}")
    return raw.ljust(length, b"\x00")

def resolve_colors(palette: dict, group: str) -> tuple[int | None, int | None]:
    """Resolve (fg, bg) colors for a highlight group, following links."""

def pack_record(entry: dict) -> bytes:
    out = bytearray()

    out += pack_name(entry["name"], NAME_LEN)
    out += pack_name(entry["repo"], REPO_NAME_LEN)

    # Flags
    flags = 0
    flags |= 1 if entry["is_light"] else 0
    out += struct.pack("<B", flags)

    # Palette: fg_bitmap | bg_bitmap | fg_colors | bg_colors
    fg_bitmap = bytearray(BITMAP_LEN)
    bg_bitmap = bytearray(BITMAP_LEN)
    fg_colors = bytearray(KEY_COUNT * 3)
    bg_colors = bytearray(KEY_COUNT * 3)

    for index, group in enumerate(KEY_NAMES):
        fg, bg = resolve_colors(entry["palette"], group)
        byte_index, mask = index // 8, 1 << (index % 8)
        if fg is not None:
            fg_bitmap[byte_index] |= mask
            fg_colors[index * 3 : index * 3 + 3] = (fg).to_bytes(3, "big")
        if bg is not None:
            bg_bitmap[byte_index] |= mask
            bg_colors[index * 3 : index * 3 + 3] = (bg).to_bytes(3, "big")

    out += bytes(fg_bitmap) + bytes(bg_bitmap) + \
           bytes(fg_colors) + bytes(bg_colors)
    
    return bytes(out)

def build_bin(entries: dict[str, dict], path: Path):
    ordered = sorted(entries.items(), key=lambda x: x[0].encode())

    assert KEY_COUNT <= 65535, "Too many hl groups, max 65535"
    assert len(ordered) <= 65535, "Too many themes, max 65535"
    header = bytearray(struct.pack(HEADER_FORMAT,
        MAGIC, KEY_COUNT, len(ordered), NAME_LEN, REPO_NAME_LEN
    ))
    assert len(header) == HEADER_SIZE

    vocab = bytearray()
    for hlg in KEY_NAMES:
        vocab += pack_name(hlg, NAME_LEN)

    records = bytearray()
    for name, entry in ordered:
        records += pack_record(entry)

    data = header + vocab + records
    Path(path).write_bytes(bytes(data))
    return len(ordered), len(data)

# === Query themes ===

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

def _fetch(query: str, page: int) -> dict:
    url = ("https://api.github.com/search/repositories?q="
           + urllib.parse.quote(query)
           + f"&sort=stars&order=desc&per_page=100&page={page}")
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

def gh_search() -> list[dict]:
    """Search for nvim theme repos on Github
    returns list of dict:
    - name: "owner/repo"
    - default_branch: default branch name
    """
    repos: dict[str, dict] = {}

    for query in QUERIES_KEYWORDS:
        page, got = 1, {}
        while True:
            data = _fetch(query, page)
            total = data.get("total_count", 0)
            items = data.get("items", [])
            if not items:
                break
            got.update({
                item["full_name"]: {
                    "name": item["full_name"],
                    "default_branch": item["default_branch"]
                } for item in items
            })
            if len(got) >= total or len(got) >= SINGLE_KEYWORD_CUTOFF:
                break
            page += 1
            time.sleep(7)
        repos.update(got)
        print(f"Searched {query}: got {len(got)} repos, total {len(repos)}")

    return sorted(repos.values(), key=lambda x: x["name"])

# === Resolve theme highlight groups ===

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

def extract_colorschmes(repo_dir: Path) -> dict[str, dict] | None:
    # extract colorscheme names under colors/
    cs_names = sorted(
        p.stem 
        for p in (repo_dir / "colors").glob("*")
        if p.suffix in (".vim", ".lua")
    )
    # extract
    def extract_hlgs(theme: str) -> dict | None:
        env = {
            **os.environ,
            "THEME_DIR": str(repo_dir),
            "THEME_NAME": theme,
            "THEME_KEYS": json.dumps(KEY_NAMES),
        }
        p = subprocess.run(
            ["nvim", "--headless", "-l", LUA_SCRIPT],
            capture_output=True, text=True, env=env, timeout=60,
        )
        try:
            return json.loads(p.stdout)
        except json.JSONDecodeError:
            print(f"  nvim output error: {p.stderr.strip()[:200]}")
        return None

    result: dict[str, dict] = {}
    for theme in cs_names:
        hlgs = extract_hlgs(theme)
        if hlgs:
            result[theme] = hlgs
    return result
    

def resolve_theme_repos(repos: list[dict]) -> dict[str, dict]:
    result: dict[str, dict] = {}
    resolved = set()
    for repo in repos:
        repo_name = repo["name"]
        branch = repo["default_branch"]
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_dir = download(repo_name, branch, Path(tmpdir))
            if repo_dir is None:
                continue
            colorschemes = extract_colorschmes(repo_dir)
        if colorschemes:
            result.update(colorschemes)
            resolved.add(repo)
    print(f"Resolved {len(resolved)} repos, {len(result)} colorschemes")
    all_names = {item["name"] for item in repos}
    failed = all_names - resolved
    if failed:
        print(f"Failed to resolve {len(failed)} repos:")
        for repo in sorted(failed):
            print(f"  {repo}")
    return result


def main():
    """Usage: python build_hlbin.py [output_path]
    """
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("lua/theme/hl.bin")

    repos = gh_search()
    themes = resolve_theme_repos(repos)
    count, size = build_bin(themes, dst)

    print(f"Wrote {count} themes, {size} bytes to {dst}")

