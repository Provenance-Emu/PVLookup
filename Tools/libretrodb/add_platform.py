#!/usr/bin/env python3
"""
add_platform.py: add one platform's games to the full libretrodb.sqlite, from a
libretro-database clrmamepro dat, without changing a row that is already there.

The full libretrodb.sqlite on the `databases-*` releases is an old build of the third-party
avojak/libretrodb-sqlite project. Rebuilding it from today's libretro-database would give the
platforms new ids, and PVSystems maps every system to its `platforms.id`
(`SystemIdentifier.libretroDatabaseID`). So a platform libretro-database gained later is
appended: one new `platforms` row with the next free id, and its games and roms after the
existing ones. Nothing else is touched, and the script proves it by comparing every table of
the output against the input.

How a dat becomes rows (the schema joins `games` to `roms` on `serial_id`):

  - one `games` row per dat game; `full_name` is the dat name, `display_name` the name before
    its first parenthesis, `region_id` the dat region when `regions` has that exact name;
  - one `roms` row per dat rom that has an md5, with the game's `serial_id`;
  - `serial_id` is the game's serial, uppercased, as uppercase hex of its bytes (the form the
    rest of the database uses). A game with no serial, or whose serial another game already
    has, gets the key `md5-<MD5 of its first rom>` instead. The key only joins the two tables:
    PVLookup never reports `serial_id` as a serial, and no real one can look like it.

Usage:
  add_platform.py --input libretrodb.sqlite --output out/libretrodb.sqlite \\
      --dat "Atari - Jaguar CD.dat" --platform "Jaguar CD" --manufacturer Atari [--platform-id 120]

Python 3 standard library only. Exit code 0 when the platform was added and verified.
"""

import argparse
import re
import shutil
import sqlite3
import sys
from pathlib import Path

TABLES = [
    "games", "roms", "developers", "publishers", "ratings", "franchises",
    "regions", "genres", "platforms", "manufacturers",
]
MD5_KEY_PREFIX = "md5-"
TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|([()])|([^\s()"]+)')


class DatError(Exception):
    pass


def tokens(text):
    for match in TOKEN.finditer(text):
        quoted, paren, bare = match.groups()
        if paren:
            yield paren, None
        else:
            yield "value", re.sub(r"\\(.)", r"\1", quoted) if quoted is not None else bare


def parse_block(stream):
    """The fields of one `( ... )` block, after its opening parenthesis. A field met more
    than once (a game's `rom`) keeps every value, in order."""
    fields = {}
    for kind, value in stream:
        if kind == ")":
            return fields
        if kind != "value":
            raise DatError("expected a field name")
        key = value
        kind, value = next(stream, (None, None))
        if kind == "(":
            value = parse_block(stream)
        elif kind != "value":
            raise DatError(f"field {key!r} has no value")
        fields.setdefault(key, []).append(value)
    raise DatError("a block is not closed")


def parse_dat(text):
    """The `game ( ... )` blocks of a clrmamepro dat, as dicts of value lists."""
    games = []
    stream = tokens(text)
    for kind, value in stream:
        if kind != "value":
            raise DatError("expected a block name at the top level")
        if next(stream, (None, None))[0] != "(":
            raise DatError(f"{value!r} is not followed by a block")
        block = parse_block(stream)
        if value == "game":
            games.append(block)
    return games


def first(fields, key):
    values = fields.get(key)
    return values[0] if values and isinstance(values[0], str) else None


def hex_serial(serial):
    return serial.upper().encode("utf-8").hex().upper()


def display_name(full_name):
    return full_name.split(" (", 1)[0].strip()


def rows_for(games, taken_keys, region_ids):
    """(game rows, rom rows) without ids. `taken_keys` are the serial_ids already in use."""
    taken = set(taken_keys)
    game_rows, rom_rows, notes = [], [], []
    for game in games:
        name = first(game, "name")
        roms = [
            (first(rom, "name"), (first(rom, "md5") or "").upper())
            for rom in game.get("rom", []) if isinstance(rom, dict)
        ]
        roms = [(rom_name, md5) for rom_name, md5 in roms if rom_name and re.fullmatch(r"[0-9A-F]{32}", md5)]
        if not name or not roms:
            notes.append(f"skipped {name or '(unnamed game)'}: no rom with an md5")
            continue
        serial = first(game, "serial")
        key = hex_serial(serial) if serial else None
        if key is None or key in taken:
            if key is not None:
                notes.append(f"{name}: serial {serial} is already used, keyed by md5")
            key = MD5_KEY_PREFIX + roms[0][1]
        if key in taken:
            notes.append(f"skipped {name}: its first rom's md5 is already used by another game")
            continue
        taken.add(key)
        game_rows.append((key, region_ids.get(first(game, "region")), display_name(name), name))
        rom_rows.extend((key, rom_name, md5) for rom_name, md5 in roms)
    return game_rows, rom_rows, notes


def scalar(db, sql, parameters=()):
    return db.execute(sql, parameters).fetchone()[0]


def add_platform(db, dat_text, platform, manufacturer, platform_id=None):
    """Adds the platform inside the caller's transaction. Returns a summary dict."""
    games = parse_dat(dat_text)
    if not games:
        raise DatError("the dat has no games")
    if scalar(db, "SELECT COUNT(*) FROM platforms WHERE name = ? COLLATE NOCASE", (platform,)):
        raise DatError(f"the database already has a platform named {platform!r}")
    if platform_id is None:
        platform_id = scalar(db, "SELECT COALESCE(MAX(id), 0) + 1 FROM platforms")
    elif scalar(db, "SELECT COUNT(*) FROM platforms WHERE id = ?", (platform_id,)):
        raise DatError(f"platform id {platform_id} is already used")

    row = db.execute("SELECT id FROM manufacturers WHERE name = ? COLLATE NOCASE", (manufacturer,)).fetchone()
    if row:
        manufacturer_id = row[0]
    else:
        manufacturer_id = scalar(db, "SELECT COALESCE(MAX(id), 0) + 1 FROM manufacturers")
        db.execute("INSERT INTO manufacturers (id, name) VALUES (?, ?)", (manufacturer_id, manufacturer))

    taken = {key for (key,) in db.execute("SELECT serial_id FROM games WHERE serial_id IS NOT NULL")}
    region_ids = {name: region_id for region_id, name in db.execute("SELECT id, name FROM regions")}
    game_rows, rom_rows, notes = rows_for(games, taken, region_ids)
    if not game_rows:
        raise DatError("no game in the dat has a rom with an md5")

    db.execute("INSERT INTO platforms (id, name, manufacturer_id) VALUES (?, ?, ?)",
               (platform_id, platform, manufacturer_id))
    next_game = scalar(db, "SELECT COALESCE(MAX(id), 0) + 1 FROM games")
    db.executemany(
        "INSERT INTO games (id, serial_id, region_id, display_name, full_name, platform_id) VALUES (?, ?, ?, ?, ?, ?)",
        [(next_game + index, key, region_id, short, full, platform_id)
         for index, (key, region_id, short, full) in enumerate(game_rows)])
    next_rom = scalar(db, "SELECT COALESCE(MAX(id), 0) + 1 FROM roms")
    db.executemany(
        "INSERT INTO roms (id, serial_id, name, md5) VALUES (?, ?, ?, ?)",
        [(next_rom + index, key, name, md5) for index, (key, name, md5) in enumerate(rom_rows)])
    return {
        "platform_id": platform_id,
        "manufacturer_id": manufacturer_id,
        "games": len(game_rows),
        "roms": len(rom_rows),
        "md5_keyed": sum(1 for row in game_rows if row[0].startswith(MD5_KEY_PREFIX)),
        "notes": notes,
    }


def verify(output_path, input_path, platform_id, summary):
    """Problems found in the output, as text. Empty when it is the input plus the platform."""
    problems = []
    db = sqlite3.connect(output_path)
    try:
        db.execute("ATTACH DATABASE ? AS base", (str(Path(input_path).resolve()),))
        if scalar(db, "PRAGMA main.integrity_check") != "ok":
            problems.append("integrity_check failed")
        for table in TABLES:
            missing = scalar(db, f"SELECT COUNT(*) FROM (SELECT * FROM base.{table} EXCEPT SELECT * FROM main.{table})")
            if missing:
                problems.append(f"{table}: {missing} row(s) of the input changed or are gone")
        expected_new = {
            "games": summary["games"], "roms": summary["roms"], "platforms": 1,
            "manufacturers": scalar(db, "SELECT COUNT(*) FROM main.manufacturers") - scalar(db, "SELECT COUNT(*) FROM base.manufacturers"),
        }
        for table in TABLES:
            added = scalar(db, f"SELECT COUNT(*) FROM main.{table}") - scalar(db, f"SELECT COUNT(*) FROM base.{table}")
            if added != expected_new.get(table, 0):
                problems.append(f"{table}: {added} row(s) added, expected {expected_new.get(table, 0)}")
        if expected_new["manufacturers"] not in (0, 1):
            problems.append("more than one manufacturer was added")
        joined = scalar(db, """
            SELECT COUNT(*) FROM main.games JOIN main.roms ON games.serial_id = roms.serial_id
            WHERE games.platform_id = ?""", (platform_id,))
        if joined != summary["roms"]:
            problems.append(f"{joined} game-rom pairs join on the platform, expected {summary['roms']}")
        stray = scalar(db, """
            SELECT COUNT(*) FROM main.games JOIN main.roms ON games.serial_id = roms.serial_id
            WHERE games.platform_id != ? AND roms.id > (SELECT MAX(id) FROM base.roms)""", (platform_id,))
        if stray:
            problems.append(f"{stray} new rom(s) join a game of another platform")
    finally:
        db.close()
    return problems


def main():
    parser = argparse.ArgumentParser(description="Append one platform to the full libretrodb.sqlite from a clrmamepro dat.")
    parser.add_argument("--input", required=True, type=Path, help="libretrodb.sqlite to start from (never modified)")
    parser.add_argument("--output", required=True, type=Path, help="where to write the new libretrodb.sqlite")
    parser.add_argument("--dat", required=True, type=Path, help="clrmamepro dat from libretro-database")
    parser.add_argument("--platform", required=True, help='platform name as the database spells them, e.g. "Jaguar CD"')
    parser.add_argument("--manufacturer", required=True, help='manufacturer name, e.g. "Atari"')
    parser.add_argument("--platform-id", type=int, help="platform id to use (default: the next free one)")
    args = parser.parse_args()

    if args.output.resolve() == args.input.resolve():
        sys.exit("error: --output must not be the input file")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.input, args.output)
    db = sqlite3.connect(args.output)
    try:
        with db:
            summary = add_platform(db, args.dat.read_text(encoding="utf-8"), args.platform, args.manufacturer, args.platform_id)
    except (DatError, sqlite3.Error) as error:
        db.close()
        args.output.unlink(missing_ok=True)
        sys.exit(f"error: {error}")
    db.close()

    problems = verify(args.output, args.input, summary["platform_id"], summary)
    for note in summary["notes"]:
        print(f"note: {note}")
    print(f"platform {summary['platform_id']} \"{args.platform}\": {summary['games']} games "
          f"({summary['md5_keyed']} keyed by md5), {summary['roms']} roms")
    if problems:
        args.output.unlink(missing_ok=True)
        sys.exit("error: " + "; ".join(problems))
    print(f"verified: every row of {args.input.name} is unchanged in {args.output}")


if __name__ == "__main__":
    main()
