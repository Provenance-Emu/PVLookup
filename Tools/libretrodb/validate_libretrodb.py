#!/usr/bin/env python3
"""
validate_libretrodb.py — Validate a generated libretrodb.sqlite.generated against the task's
acceptance criteria. Run after generate_libretrodb.py.

Checks:
  1. `roms` has a populated `crc` column (count of non-null crc > 0).
  2. The required indexes exist on games/roms.
  3. `platforms` contains id 99 = "Sega - Dreamcast" and every game uses platform_id 99
     (parity with how the iFly Swift layer maps Dreamcast/Naomi/Atomiswave).
  4. Spot-check Sonic Adventure (USA): serial MK-51000, title "Sonic Adventure".
  5. Run a representative Swift-layer query (serial + md5 join) and confirm it returns.

Usage:
  python3 validate_libretrodb.py [path/to/libretrodb.sqlite.generated]
Exit code 0 = all required checks passed; 1 = a required check failed.
"""

import sqlite3
import sys
from pathlib import Path

REQUIRED_INDEXES = {
    "idx_roms_md5", "idx_roms_crc", "idx_roms_serial_id",
    "idx_games_platform_id", "idx_games_serial_id", "idx_games_display_name",
}

# Standard-metadata-style query the Swift layer runs (serial + md5 join across lookup tables).
SWIFT_STYLE_QUERY = """
SELECT games.serial_id, games.platform_id, games.display_name, games.full_name,
       developers.name AS developer_name, publishers.name AS publisher_name,
       regions.name AS region_name, roms.name AS rom_name, roms.md5 AS rom_md5,
       roms.crc AS rom_crc, platforms.name AS platform_name, manufacturers.name AS manufacturer_name
FROM games
    LEFT JOIN developers   ON games.developer_id  = developers.id
    LEFT JOIN publishers   ON games.publisher_id  = publishers.id
    LEFT JOIN regions      ON games.region_id     = regions.id
    LEFT JOIN platforms    ON games.platform_id   = platforms.id
    LEFT JOIN manufacturers ON platforms.manufacturer_id = manufacturers.id
    INNER JOIN roms        ON games.serial_id     = roms.serial_id
WHERE games.serial_id LIKE ?
"""


def main():
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent.parent
        / "Sources" / "libretrodb" / "Resources" / "libretrodb.sqlite.generated"
    )
    if not db_path.is_file():
        print(f"FAIL: DB not found at {db_path}")
        sys.exit(1)

    print(f"Validating {db_path}\n")
    c = sqlite3.connect(str(db_path))
    failures = []

    # 1. crc populated
    games = c.execute("SELECT COUNT(*) FROM games").fetchone()[0]
    roms = c.execute("SELECT COUNT(*) FROM roms").fetchone()[0]
    crc_pop = c.execute("SELECT COUNT(*) FROM roms WHERE crc IS NOT NULL AND crc != ''").fetchone()[0]
    md5_pop = c.execute("SELECT COUNT(*) FROM roms WHERE md5 IS NOT NULL AND md5 != ''").fetchone()[0]
    print(f"[1] rows: games={games} roms={roms}  crc_populated={crc_pop}  md5_populated={md5_pop}")
    if crc_pop == 0:
        failures.append("roms.crc is entirely empty")

    # roms must actually have the crc column
    cols = {r[1] for r in c.execute("PRAGMA table_info(roms)")}
    print(f"    roms columns: {sorted(cols)}")
    if "crc" not in cols:
        failures.append("roms table has no crc column")

    # 2. indexes
    idx = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='index'")}
    print(f"[2] indexes present: {sorted(idx)}")
    missing = REQUIRED_INDEXES - idx
    if missing:
        failures.append(f"missing indexes: {sorted(missing)}")

    # 3. platform_id parity
    plat = c.execute("SELECT id, name FROM platforms ORDER BY id").fetchall()
    print(f"[3] platforms: {plat}")
    if (99, "Sega - Dreamcast") not in plat:
        failures.append("platforms missing (99, 'Sega - Dreamcast')")
    distinct_pids = [r[0] for r in c.execute("SELECT DISTINCT platform_id FROM games")]
    print(f"    distinct games.platform_id: {distinct_pids}")
    if distinct_pids != [99]:
        failures.append(f"games.platform_id should be exactly [99], got {distinct_pids}")

    # 4. Sonic Adventure spot-check. serial_id is stored as plaintext from .rdb
    # (e.g. "MK-51000"), matching generate_libretrodb.py output.
    serial = "MK-51000"
    rows = c.execute(
        "SELECT serial_id, display_name FROM games WHERE serial_id LIKE ?",
        (f"%{serial}%",)
    ).fetchall()
    print(f"[4] Sonic Adventure (serial {serial}) games rows: {rows}")
    if not any("Sonic Adventure" in (r[1] or "") for r in rows):
        failures.append("Sonic Adventure (MK-51000) not found / title mismatch")

    # 5. Swift-style serial query returns
    res = c.execute(SWIFT_STYLE_QUERY, (f"%{serial}%",)).fetchall()
    print(f"[5] Swift-style serial+md5 join returned {len(res)} row(s)")
    if res:
        r = res[0]
        print(f"    sample: serial={r[0]} platform_id={r[1]} title={r[2]!r} "
              f"md5={r[8]} crc={r[9]} platform={r[10]} mfr={r[11]}")
    if not res:
        failures.append("Swift-style serial query returned no rows for MK-51000")

    # Bonus: an md5 round-trip if Sonic Adventure has one.
    if res and res[0][8]:
        md5 = res[0][8]
        md5_rows = c.execute(
            "SELECT g.display_name FROM roms r JOIN games g ON g.serial_id = r.serial_id "
            "WHERE r.md5 = ?", (md5,)).fetchall()
        print(f"    md5 round-trip ({md5}) -> {len(md5_rows)} row(s)")

    print()
    if failures:
        print("VALIDATION FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("VALIDATION PASSED: all required checks OK.")


if __name__ == "__main__":
    main()
