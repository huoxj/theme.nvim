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

import struct
import sys
from pathlib import Path

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


def gh_search() -> list[str]:
    """Search for nvim theme repos on Github
    returns list of "owner/repo"
    """

    return []

def resolve_theme_repos(repos: list[str]) -> dict[str, dict]:
    return {}

def main():
    """Usage: python build_hlbin.py [output_path]
    """
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("lua/theme/hl.bin")

    repos = gh_search()
    themes = resolve_theme_repos(repos)
    count, size = build_bin(themes, dst)

    print(f"Wrote {count} themes, {size} bytes to {dst}")

