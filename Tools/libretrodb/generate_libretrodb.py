#!/usr/bin/env python3
"""
generate_libretrodb.py — Generate iFly's LibretroDB metadata SQLite from libretro `.rdb` files.

iFly currently ships a prebuilt `libretrodb.sqlite.zip` derived from the third-party
`avojak/libretrodb-sqlite` project. That build strips every checksum except md5 and ships
WITHOUT indexes — the missing indexes cause multi-second query stalls, and the missing `crc`
column means `searchByCRC` can never work.

This generator produces a schema-compatible `libretrodb.sqlite` directly from the upstream
libretro `.rdb` files, ADDING:
  (a) a `crc` column on the `roms` table (from each `.rdb`'s crc field, optionally supplemented
      from `metadat/redump/*.dat` CLRMamePro DAT files), and
  (b) the indexes the Swift query layer needs (roms.md5, roms.crc, roms.serial_id,
      games.platform_id, games.serial_id, games.display_name COLLATE NOCASE).

It mirrors the structure of Provenance's `Scripts/generate_cheatdb.py`: idempotent string→id
caches for lookup tables, a tolerant parser, ANALYZE at the end, and a `.zip` output. It is
Python-3-stdlib only (sqlite3 / subprocess / zipfile / json / re / pathlib).

Output goes to a SIDE-BY-SIDE file (`libretrodb.sqlite.generated` + `.generated.zip`) for review,
NOT over the shipped `libretrodb.sqlite.zip`.

--------------------------------------------------------------------------------------------------
CRITICAL — platform_id is hardcoded to 99 for ALL of these systems.
--------------------------------------------------------------------------------------------------
The iFly Swift layer maps `games.platform_id` via `SystemIdentifier.fromLibretroDatabaseID()`
(see Provenance-Emu/PVSystems, SystemIdentifier+LibretroDB.swift). In that mapping:

    .Dreamcast  -> 99
    .Naomi      -> 99
    .Atomiswave -> 99
    fromLibretroDatabaseID(99) -> .Dreamcast

Atomiswave's *real* upstream libretro platform id is 25, but iFly deliberately collapses all
Sega arcade/Dreamcast-family systems onto 99 (Dreamcast) because that's the SystemIdentifier the
Flycast core boots them as. If we wrote 25 (or any per-rdb `platform` value), the Swift layer
would return nil for that id and silently break ALL matching for that system. So we IGNORE the
`platform`/`platform_id` field inside each `.rdb` and force `platform_id = 99` on every game.

--------------------------------------------------------------------------------------------------
`.rdb` record format
--------------------------------------------------------------------------------------------------
`libretrodb_tool <file.rdb> list` prints one rmsgpack-DOM map per ROM, via
`rmsgpack_dom_value_print()` in libretro-db. The format is JSON-LIKE but NOT valid JSON:
  - strings are emitted as `"%s"` with NO escaping (`nil` is used for null, not `null`)
  - binary fields (crc, md5, sha1) are emitted as uppercase hex inside quotes, e.g. `"crc": "1ABDD3F0"`
  - integers/uints are bare, bools are `true`/`false`
Because the strings are unescaped, `json.loads` cannot be trusted; we use a per-field regex
extractor over each line instead (the field set is small and fixed).

Fields seen per record: name, description, crc, md5, sha1, serial, developer, publisher,
releaseyear, releasemonth, region, genre, franchise, users, rating, size, rom_name, ...
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


# ----------------------------------------------------------------------------------------------
# System configuration
# ----------------------------------------------------------------------------------------------

# All four systems map to platform_id 99 (Dreamcast) in the iFly Swift layer. See module docstring.
DREAMCAST_FAMILY_PLATFORM_ID = 99
DREAMCAST_PLATFORM_NAME = "Sega - Dreamcast"   # platforms.name for id 99 in the shipped DB
SEGA_MANUFACTURER_NAME = "Sega"

# Map a --systems key -> the upstream `.rdb` filename (basename, no extension).
# These are the exact filenames in https://github.com/libretro/libretro-database/tree/master/rdb
# NOTE the casing: upstream uses "Naomi" (not "NAOMI"), and Atomiswave has NO "Sega - " prefix.
SYSTEM_RDB_NAMES = {
    "dreamcast":  "Sega - Dreamcast",
    "naomi":      "Sega - Naomi",
    "naomi2":     "Sega - Naomi 2",
    "atomiswave": "Atomiswave",
}

DEFAULT_SYSTEMS = ["dreamcast", "naomi", "naomi2", "atomiswave"]


# ----------------------------------------------------------------------------------------------
# `.rdb` record parsing (tolerant — output is NOT valid JSON, see module docstring)
# ----------------------------------------------------------------------------------------------

# A record line looks like:
#   {"name": "Sonic Adventure (USA)", "description": "...", "rom_name": "Sonic Adventure (USA).gdi",
#    "size": 1234, "crc": "1ABDD3F0", "md5": "...", "sha1": "...", "serial": "MK-51000", ...}
#
# We extract each known field with its own regex. String/binary values are quoted; numeric
# values are bare. Binary (crc/md5/sha1) come out as uppercase hex inside quotes.

_FIELD_STR_RE_CACHE: dict[str, re.Pattern] = {}
_FIELD_INT_RE_CACHE: dict[str, re.Pattern] = {}


def _str_field(line: str, key: str) -> Optional[str]:
    """Extract a quoted string/binary field value. Returns None if absent or `nil`."""
    pat = _FIELD_STR_RE_CACHE.get(key)
    if pat is None:
        # Match `"key": "value"` — value is everything up to the closing quote that is
        # followed by a comma+space or the closing brace. Non-greedy, tolerant of unescaped
        # inner content but stops at `", ` / `"}` boundaries used by rmsgpack_dom_value_print.
        pat = re.compile(r'"' + re.escape(key) + r'"\s*:\s*"(.*?)"(?=\s*,\s*"|\s*\})')
        _FIELD_STR_RE_CACHE[key] = pat
    m = pat.search(line)
    if not m:
        # Could be present as `nil`
        return None
    val = m.group(1)
    return val if val != "" else None


def _int_field(line: str, key: str) -> Optional[int]:
    """Extract a bare integer field value. Returns None if absent or `nil`."""
    pat = _FIELD_INT_RE_CACHE.get(key)
    if pat is None:
        pat = re.compile(r'"' + re.escape(key) + r'"\s*:\s*(-?\d+)(?=\s*,\s*"|\s*\})')
        _FIELD_INT_RE_CACHE[key] = pat
    m = pat.search(line)
    if not m:
        return None
    try:
        return int(m.group(1))
    except ValueError:
        return None


def parse_rdb_record(line: str) -> Optional[dict]:
    """Parse one `libretrodb_tool list` output line into a normalized dict.

    Returns None for blank/non-record lines.
    """
    line = line.strip()
    if not line.startswith("{"):
        return None

    rec = {
        "name":         _str_field(line, "name"),
        "description":  _str_field(line, "description"),
        "rom_name":     _str_field(line, "rom_name"),
        "crc":          _str_field(line, "crc"),
        "md5":          _str_field(line, "md5"),
        "sha1":         _str_field(line, "sha1"),
        "serial":       _str_field(line, "serial"),
        "developer":    _str_field(line, "developer"),
        "publisher":    _str_field(line, "publisher"),
        "franchise":    _str_field(line, "franchise"),
        "region":       _str_field(line, "region"),
        "genre":        _str_field(line, "genre"),
        "rating":       _str_field(line, "rating"),
        "releaseyear":  _int_field(line, "releaseyear"),
        "releasemonth": _int_field(line, "releasemonth"),
        "users":        _int_field(line, "users"),
    }

    # A record with neither a name nor any rom-identifying key is useless.
    if not rec["name"] and not rec["rom_name"] and not rec["serial"] and not rec["md5"]:
        return None
    return rec


# ----------------------------------------------------------------------------------------------
# CLRMamePro DAT parsing (CRC supplement) — mirrors generate_cheatdb.py:parse_dat_file but keeps
# crc as well as md5, keyed by both rom-name-stem and md5 for cross-reference.
# ----------------------------------------------------------------------------------------------

_DAT_ROM_LINE_RE = re.compile(r"\brom\s*\(", re.IGNORECASE)
_DAT_NAME_RE = re.compile(r'\bname\s+"([^"]+)"', re.IGNORECASE)
_DAT_CRC_RE = re.compile(r"\bcrc\s+([0-9a-fA-F]{8})", re.IGNORECASE)
_DAT_MD5_RE = re.compile(r"\bmd5\s+([0-9a-fA-F]{32})", re.IGNORECASE)


def parse_dat_for_crc(dat_path: Path) -> dict:
    """Parse a CLRMamePro DAT and return crc lookups.

    Returns {"by_md5": {md5_upper: crc_upper}, "by_stem": {rom_name_stem: crc_upper}}.
    """
    by_md5: dict[str, str] = {}
    by_stem: dict[str, str] = {}
    try:
        with open(dat_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except Exception as e:
        print(f"  Warning: could not read DAT {dat_path}: {e}", file=sys.stderr)
        return {"by_md5": by_md5, "by_stem": by_stem}

    for line in content.splitlines():
        if not _DAT_ROM_LINE_RE.search(line):
            continue
        crc_m = _DAT_CRC_RE.search(line)
        if not crc_m:
            continue
        crc = crc_m.group(1).upper()
        md5_m = _DAT_MD5_RE.search(line)
        if md5_m:
            by_md5[md5_m.group(1).upper()] = crc
        name_m = _DAT_NAME_RE.search(line)
        if name_m:
            by_stem[Path(name_m.group(1)).stem] = crc
    return {"by_md5": by_md5, "by_stem": by_stem}


def build_crc_supplement(db_root: Optional[Path], rdb_basenames: list) -> dict:
    """Build a crc supplement map from metadat/redump/<system>.dat files (and dat/ fallback).

    Returns {"by_md5": {...}, "by_stem": {...}} merged across the relevant systems.
    Used only to fill crc when a `.rdb` record lacks one.
    """
    merged = {"by_md5": {}, "by_stem": {}}
    if db_root is None:
        return merged
    db_root = Path(db_root)
    search_dirs = [db_root / "metadat" / "redump", db_root / "metadat" / "no-intro", db_root / "dat"]
    wanted = set(rdb_basenames)
    for d in search_dirs:
        if not d.exists():
            continue
        for dat in sorted(d.glob("*.dat")):
            if dat.stem not in wanted:
                continue
            print(f"  CRC supplement: {dat.relative_to(db_root)}")
            sub = parse_dat_for_crc(dat)
            for k, v in sub["by_md5"].items():
                merged["by_md5"].setdefault(k, v)
            for k, v in sub["by_stem"].items():
                merged["by_stem"].setdefault(k, v)
    if merged["by_md5"] or merged["by_stem"]:
        print(f"  CRC supplement: {len(merged['by_md5'])} by-md5, {len(merged['by_stem'])} by-stem")
    return merged


# ----------------------------------------------------------------------------------------------
# libretrodb_tool discovery / build
# ----------------------------------------------------------------------------------------------

def locate_libretrodb_tool(explicit: Optional[str], build_dir: Path) -> Optional[str]:
    """Find an existing libretrodb_tool binary, or return None.

    Checks (in order): --tool arg, build_dir, PATH.
    """
    if explicit and Path(explicit).is_file() and os.access(explicit, os.X_OK):
        return explicit
    candidate = build_dir / "libretrodb_tool"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    from shutil import which
    found = which("libretrodb_tool")
    return found


# Source file lists mirror libretro-db's Makefile (RARCHDB_TOOL_C + LIBRETRO_COMMON_C).
_LIBRETRODB_SRCS = [
    "rmsgpack.c", "rmsgpack_dom.c", "libretrodb_tool.c", "bintree.c", "query.c", "libretrodb.c",
]
_LIBRETRO_COMMON_SRCS = [
    "compat/compat_fnmatch.c",
    "string/stdstring.c",
    "streams/interface_stream.c",
    "streams/memory_stream.c",
    "streams/file_stream.c",
    "compat/compat_strcasestr.c",
    "time/rtime.c",
    "file/file_path.c",
    "file/file_path_io.c",
    "vfs/vfs_implementation.c",
    "encodings/encoding_utf.c",
    "encodings/encoding_crc32.c",
    "compat/compat_strl.c",
    "compat/fopen_utf8.c",
]


def build_libretrodb_tool(libretrodb_src: Path, libretro_common: Path, out_path: Path,
                          cc: Optional[str] = None) -> str:
    """Compile libretrodb_tool from libretro-db + libretro-common source.

    Prefers `make` in the libretro-db dir; falls back to a one-shot clang/cc invocation
    (the Makefile path needs ../libretro-common to resolve next to libretrodb_src).
    Returns the path to the produced binary.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Resolve a C compiler: explicit -> CC env -> `xcrun clang` (Apple) -> cc/clang/gcc.
    def _resolve_cc() -> list:
        from shutil import which
        if cc:
            return cc.split()
        if os.environ.get("CC"):
            return os.environ["CC"].split()
        if sys.platform == "darwin" and which("xcrun"):
            return ["xcrun", "clang"]
        for c in ("clang", "cc", "gcc"):
            if which(c):
                return [c]
        raise RuntimeError("No C compiler found (tried xcrun clang, clang, cc, gcc)")

    cc_cmd = _resolve_cc()
    srcs = [str(libretrodb_src / s) for s in _LIBRETRODB_SRCS]
    srcs += [str(libretro_common / s) for s in _LIBRETRO_COMMON_SRCS]
    cmd = cc_cmd + [
        f"-I{libretrodb_src}",
        f"-I{libretro_common / 'include'}",
        "-O2", "-g", "-DNDEBUG", "-w",
        "-o", str(out_path),
    ] + srcs

    print(f"  Building libretrodb_tool: {' '.join(cc_cmd)} ... ({len(srcs)} sources)")
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stdout)
        sys.stderr.write(res.stderr)
        raise RuntimeError(f"libretrodb_tool build failed (exit {res.returncode})")
    if not out_path.is_file():
        raise RuntimeError("libretrodb_tool build reported success but binary is missing")
    print(f"  Built: {out_path}")
    return str(out_path)


def run_libretrodb_tool_list(tool: str, rdb_path: Path) -> list:
    """Run `libretrodb_tool <rdb> list` and return parsed records."""
    res = subprocess.run([tool, str(rdb_path), "list"], capture_output=True, text=True,
                         errors="replace")
    # The tool returns 1 even on success (see libretrodb_tool.c main()), so don't gate on rc.
    records = []
    for line in res.stdout.splitlines():
        rec = parse_rdb_record(line)
        if rec:
            records.append(rec)
    if not records and res.stderr.strip():
        print(f"  Warning: no records parsed from {rdb_path.name}; stderr:\n{res.stderr}",
              file=sys.stderr)
    return records


# ----------------------------------------------------------------------------------------------
# Database build
# ----------------------------------------------------------------------------------------------

SCHEMA = """
DROP TABLE IF EXISTS developers;
DROP TABLE IF EXISTS franchises;
DROP TABLE IF EXISTS games;
DROP TABLE IF EXISTS genres;
DROP TABLE IF EXISTS manufacturers;
DROP TABLE IF EXISTS platforms;
DROP TABLE IF EXISTS publishers;
DROP TABLE IF EXISTS ratings;
DROP TABLE IF EXISTS regions;
DROP TABLE IF EXISTS roms;
DROP TABLE IF EXISTS artwork;
DROP TABLE IF EXISTS meta;

CREATE TABLE developers   ( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE franchises   ( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE genres       ( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE manufacturers( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE publishers   ( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE ratings      ( id INTEGER PRIMARY KEY, name TEXT );
CREATE TABLE regions      ( id INTEGER PRIMARY KEY, name TEXT );

CREATE TABLE platforms (
    id INTEGER PRIMARY KEY,
    name TEXT,
    manufacturer_id INTEGER
);

CREATE TABLE games (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    developer_id INTEGER,
    publisher_id INTEGER,
    rating_id INTEGER,
    users INTEGER,
    franchise_id INTEGER,
    release_year INTEGER,
    release_month INTEGER,
    region_id INTEGER,
    genre_id INTEGER,
    display_name TEXT,
    full_name TEXT,
    platform_id INTEGER
);

-- NOTE: `crc TEXT` is the iFly addition vs the shipped third-party schema.
CREATE TABLE roms (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    name TEXT,
    md5 TEXT,
    crc TEXT
);

CREATE TABLE artwork (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    type TEXT,
    url TEXT,
    FOREIGN KEY(serial_id) REFERENCES games(serial_id)
);

CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

# Indexes — the whole point of (b). The shipped DB has NONE of these on games/roms, which is why
# md5/serial/crc lookups do full table scans (~24s stalls).
INDEXES = """
CREATE INDEX idx_roms_md5         ON roms(md5);
CREATE INDEX idx_roms_crc         ON roms(crc);
CREATE INDEX idx_roms_serial_id   ON roms(serial_id);
CREATE INDEX idx_games_platform_id ON games(platform_id);
CREATE INDEX idx_games_serial_id  ON games(serial_id);
CREATE INDEX idx_games_display_name ON games(display_name COLLATE NOCASE);
CREATE INDEX idx_artwork_serial_id ON artwork(serial_id);
CREATE INDEX idx_artwork_type     ON artwork(type);
"""


class LookupCache:
    """Insert-or-reuse string->id cache for a single lookup table (mirrors generate_cheatdb.py)."""

    def __init__(self, conn: sqlite3.Connection, table: str):
        self.conn = conn
        self.table = table
        self.cache: dict[str, int] = {}
        self._next_id = 1

    def id_for(self, name: Optional[str]) -> Optional[int]:
        if not name:
            return None
        key = name
        if key in self.cache:
            return self.cache[key]
        rid = self._next_id
        self._next_id += 1
        self.conn.execute(f"INSERT INTO {self.table} (id, name) VALUES (?, ?)", (rid, name))
        self.cache[key] = rid
        return rid


def normalize_crc(raw: Optional[str]) -> Optional[str]:
    """Normalize a crc to 8-char uppercase hex, or None."""
    if not raw:
        return None
    s = raw.strip().upper().removeprefix("0X")
    if not re.fullmatch(r"[0-9A-F]+", s):
        return None
    # libretrodb stores crc as 4 bytes; pad/keep 8 hex chars.
    return s.zfill(8)[-8:]


def generate(rdb_files: list, tool: str, output: Path, crc_supplement: dict,
             source_commit: str) -> dict:
    """Build the SQLite DB from the given list of (system_key, rdb_path) and return stats."""
    if output.exists():
        output.unlink()
    conn = sqlite3.connect(str(output))
    conn.executescript(SCHEMA)

    # Seed the single platform + manufacturer rows. platform id 99 = Sega - Dreamcast.
    conn.execute("INSERT INTO manufacturers (id, name) VALUES (1, ?)", (SEGA_MANUFACTURER_NAME,))
    conn.execute(
        "INSERT INTO platforms (id, name, manufacturer_id) VALUES (?, ?, 1)",
        (DREAMCAST_FAMILY_PLATFORM_ID, DREAMCAST_PLATFORM_NAME),
    )

    developers = LookupCache(conn, "developers")
    publishers = LookupCache(conn, "publishers")
    franchises = LookupCache(conn, "franchises")
    genres = LookupCache(conn, "genres")
    ratings = LookupCache(conn, "ratings")
    regions = LookupCache(conn, "regions")

    game_id = 0
    rom_id = 0
    crc_from_rdb = 0
    crc_from_dat = 0
    per_system = {}

    for system_key, rdb_path in rdb_files:
        records = run_libretrodb_tool_list(tool, rdb_path)
        sys_games = 0
        for rec in records:
            display_name = rec["name"] or (Path(rec["rom_name"]).stem if rec["rom_name"] else None)
            serial = rec["serial"]
            # Serial is the join key between games and roms in this schema. When a record has no
            # serial we synthesize a stable one from md5 (preferred) or the rom name so the
            # game<->rom INNER JOIN still works. (Upstream Dreamcast records almost always have a
            # serial; arcade Naomi/Atomiswave sometimes don't.)
            if not serial:
                if rec["md5"]:
                    serial = "MD5:" + rec["md5"].upper()
                elif rec["rom_name"]:
                    serial = "ROM:" + rec["rom_name"]
                elif display_name:
                    serial = "NAME:" + display_name
                else:
                    continue

            game_id += 1
            conn.execute(
                """INSERT INTO games
                   (id, serial_id, developer_id, publisher_id, rating_id, users, franchise_id,
                    release_year, release_month, region_id, genre_id, display_name, full_name,
                    platform_id)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    game_id,
                    serial,
                    developers.id_for(rec["developer"]),
                    publishers.id_for(rec["publisher"]),
                    ratings.id_for(rec["rating"]),
                    rec["users"],
                    franchises.id_for(rec["franchise"]),
                    rec["releaseyear"],
                    rec["releasemonth"],
                    regions.id_for(rec["region"]),
                    genres.id_for(rec["genre"]),
                    display_name,
                    rec["description"] or display_name,
                    DREAMCAST_FAMILY_PLATFORM_ID,
                ),
            )

            # Resolve crc: prefer the .rdb crc, else supplement from DAT (by md5, then by stem).
            crc = normalize_crc(rec["crc"])
            md5 = rec["md5"].upper() if rec["md5"] else None
            if crc:
                crc_from_rdb += 1
            else:
                if md5 and md5 in crc_supplement["by_md5"]:
                    crc = crc_supplement["by_md5"][md5]
                    crc_from_dat += 1
                elif rec["rom_name"]:
                    stem = Path(rec["rom_name"]).stem
                    if stem in crc_supplement["by_stem"]:
                        crc = crc_supplement["by_stem"][stem]
                        crc_from_dat += 1

            rom_id += 1
            conn.execute(
                "INSERT INTO roms (id, serial_id, name, md5, crc) VALUES (?,?,?,?,?)",
                (rom_id, serial, rec["rom_name"] or display_name, md5, crc),
            )
            sys_games += 1

        per_system[system_key] = {"records": len(records), "games": sys_games}
        print(f"  {system_key}: {sys_games} games from {rdb_path.name}")

    conn.executescript(INDEXES)

    # meta table for refresh tracking.
    conn.execute("INSERT INTO meta (key, value) VALUES ('source_commit', ?)", (source_commit,))
    conn.execute("INSERT INTO meta (key, value) VALUES ('generated_at', ?)",
                 (datetime.now(timezone.utc).isoformat(),))
    conn.execute("INSERT INTO meta (key, value) VALUES ('generator', 'generate_libretrodb.py')")

    conn.execute("ANALYZE")
    conn.commit()
    conn.close()

    return {
        "games": game_id,
        "roms": rom_id,
        "crc_from_rdb": crc_from_rdb,
        "crc_from_dat": crc_from_dat,
        "per_system": per_system,
    }


def compress(db_path: Path) -> Path:
    zip_path = db_path.with_suffix(db_path.suffix + ".zip")
    # The shipped artifact is `libretrodb.sqlite.zip` containing a member named `libretrodb.sqlite`.
    # Keep the SAME inner member name so the Swift unzip path is identical.
    member_name = "libretrodb.sqlite"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        zf.write(db_path, member_name)
    return zip_path


# ----------------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description="Generate iFly LibretroDB metadata SQLite from .rdb files")
    p.add_argument("--rdb-dir", required=True,
                   help="Directory containing the libretro `.rdb` files (e.g. libretro-database/rdb/)")
    p.add_argument("--systems", nargs="*", default=DEFAULT_SYSTEMS,
                   choices=list(SYSTEM_RDB_NAMES.keys()),
                   help="Which systems to include (default: all Dreamcast-family)")
    p.add_argument("--output", default=None,
                   help="Output .generated SQLite path "
                        "(default: <PVLookup>/.build-libretrodb/out/"
                        "libretrodb.sqlite.generated)")
    p.add_argument("--tool", default=None, help="Path to a prebuilt libretrodb_tool binary")
    p.add_argument("--libretro-db-src", default=None,
                   help="libretro-db C source dir (to build libretrodb_tool if --tool missing)")
    p.add_argument("--libretro-common-src", default=None,
                   help="libretro-common source dir (sibling of --libretro-db-src by default)")
    p.add_argument("--build-dir", default=None,
                   help="Where to place a built libretrodb_tool (default: <repo>/build-libretrodb)")
    p.add_argument("--dat-dir", default=None,
                   help="libretro-database root (for metadat/redump/*.dat CRC supplement)")
    p.add_argument("--source-commit", default="unknown",
                   help="libretro-database commit SHA to record in the meta table")
    p.add_argument("--no-compress", action="store_true")
    args = p.parse_args()

    # Resolve repo-relative defaults.
    script_dir = Path(__file__).resolve().parent
    pvlookup_root = script_dir.parent.parent                # PVLookup repo root (Tools/libretrodb/..)
    work = pvlookup_root / ".build-libretrodb"

    output = Path(args.output) if args.output else work / "out" / "libretrodb.sqlite.generated"
    build_dir = Path(args.build_dir) if args.build_dir else work

    rdb_dir = Path(args.rdb_dir)
    if not rdb_dir.is_dir():
        print(f"Error: --rdb-dir '{rdb_dir}' is not a directory", file=sys.stderr)
        sys.exit(1)

    # Map requested systems -> existing .rdb files.
    rdb_files = []
    missing = []
    for key in args.systems:
        name = SYSTEM_RDB_NAMES[key]
        path = rdb_dir / f"{name}.rdb"
        if path.is_file() and path.stat().st_size > 64:
            rdb_files.append((key, path))
        else:
            missing.append((key, str(path)))
    if missing:
        for key, path in missing:
            print(f"  Warning: skipping '{key}' — missing/empty {path}", file=sys.stderr)
    if not rdb_files:
        print("Error: no usable .rdb files found", file=sys.stderr)
        sys.exit(1)

    # Locate or build libretrodb_tool.
    tool = locate_libretrodb_tool(args.tool, build_dir)
    if not tool:
        src = Path(args.libretro_db_src) if args.libretro_db_src else None
        if not src or not src.is_dir():
            print("Error: libretrodb_tool not found and --libretro-db-src not provided/invalid",
                  file=sys.stderr)
            sys.exit(1)
        common = (Path(args.libretro_common_src) if args.libretro_common_src
                  else src.parent / "libretro-common")
        if not common.is_dir():
            print(f"Error: libretro-common src not found at {common}", file=sys.stderr)
            sys.exit(1)
        tool = build_libretrodb_tool(src, common, build_dir / "libretrodb_tool")

    print(f"Using libretrodb_tool: {tool}")
    print(f"Output: {output}")

    crc_supplement = build_crc_supplement(
        Path(args.dat_dir) if args.dat_dir else None,
        [SYSTEM_RDB_NAMES[k] for k in args.systems],
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    stats = generate(rdb_files, tool, output, crc_supplement, args.source_commit)

    db_mb = output.stat().st_size / 1024 / 1024
    print(f"\nGenerated {output} ({db_mb:.1f} MB)")
    print(f"  games: {stats['games']}, roms: {stats['roms']}")
    print(f"  crc populated: {stats['crc_from_rdb']} from .rdb + {stats['crc_from_dat']} from DAT "
          f"= {stats['crc_from_rdb'] + stats['crc_from_dat']}")

    if not args.no_compress:
        zip_path = compress(output)
        zip_mb = zip_path.stat().st_size / 1024 / 1024
        print(f"  compressed: {zip_path} ({zip_mb:.1f} MB)")

    if stats["roms"] == 0:
        print("Error: no roms were written!", file=sys.stderr)
        sys.exit(1)
    print("\nDone.")


if __name__ == "__main__":
    main()
