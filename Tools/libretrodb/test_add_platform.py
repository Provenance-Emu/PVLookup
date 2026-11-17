#!/usr/bin/env python3
"""Tests for add_platform.py. Run: python3 Tools/libretrodb/test_add_platform.py"""

import shutil
import sqlite3
import tempfile
import unittest
from pathlib import Path

import add_platform

SCHEMA = """
CREATE TABLE games (id INTEGER PRIMARY KEY, serial_id TEXT, developer_id INTEGER, publisher_id INTEGER,
    rating_id INTEGER, users INTEGER, franchise_id INTEGER, release_year INTEGER, release_month INTEGER,
    region_id INTEGER, genre_id INTEGER, display_name TEXT, full_name TEXT, platform_id INTEGER);
CREATE TABLE roms (id INTEGER PRIMARY KEY, serial_id TEXT, name TEXT, md5 TEXT);
CREATE TABLE developers (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE ratings (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE franchises (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE regions (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE genres (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE platforms (id INTEGER PRIMARY KEY, name TEXT, manufacturer_id INTEGER);
CREATE TABLE manufacturers (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO manufacturers VALUES (9, 'Atari');
INSERT INTO platforms VALUES (29, 'Jaguar', 9), (119, 'Plus-4', NULL);
INSERT INTO regions VALUES (4, 'Europe'), (5, 'USA');
-- A cartridge that has the serial one of the discs below also carries.
INSERT INTO games (id, serial_id, display_name, full_name, platform_id)
    VALUES (700, '4A41393130', 'Iron Soldier 2', 'Iron Soldier 2 (USA, Europe)', 29);
INSERT INTO roms VALUES (900, '4A41393130', 'Iron Soldier 2 (USA, Europe).j64', '35EF8CEDBFAB697E380170E438858D4C');
INSERT INTO roms VALUES (901, NULL, 'Orphan.bin', '00000000000000000000000000000000');
"""

MD5 = {name: f"{index:032X}" for index, name in enumerate(["morph", "songbird", "elansar", "iron", "multi1", "multi2"], start=1)}

DAT = f"""
clrmamepro (
	name "Atari - Jaguar CD"
	version "2026.11.14"
)

game (
	name "Battle Morph (USA)"
	region "USA"
	serial "j9017e"
	rom ( name "Battle Morph (USA) (Track 02).bin" size 1 crc 936E7A8C md5 {MD5['morph'].lower()} serial "J9017E" )
)
game (
	name "Battle Morph (USA) (Songbird)"
	region "USA"
	serial "J9017E"
	rom ( name "Battle Morph (USA) (Songbird) (Track 02).bin" size 1 md5 {MD5['songbird']} )
)
game (
	name "Elansar (Europe) (En,Fr,De,Es)"
	region "Europe"
	rom ( name "Elansar (Europe) (En,Fr,De,Es) (Unl) (Track 2).bin" size 1 md5 {MD5['elansar']} )
)
game (
	name "Iron Soldier 2 (USA) (Songbird)"
	region "USA, Europe"
	serial "JA910"
	rom ( name "Iron Soldier 2 (USA) (Songbird) (Track 12).bin" size 1 md5 {MD5['iron']} )
)
game (
	name "Two \\"Discs\\" (USA)"
	rom ( name "Two Discs (USA) (Disc 1).bin" size 1 md5 {MD5['multi1']} )
	rom ( name "Two Discs (USA) (Disc 2).bin" size 1 md5 {MD5['multi2']} )
)
game (
	name "No Hash (USA)"
	rom ( name "No Hash (USA).bin" size 1 crc 12345678 )
)
"""


class AddPlatformTests(unittest.TestCase):

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.base = self.folder / "base.sqlite"
        db = sqlite3.connect(self.base)
        db.executescript(SCHEMA)
        db.commit()
        db.close()

    def build(self, dat=DAT, **options):
        output = self.folder / "out.sqlite"
        shutil.copyfile(self.base, output)
        db = sqlite3.connect(output)
        with db:
            summary = add_platform.add_platform(db, dat, "Jaguar CD", options.pop("manufacturer", "Atari"), **options)
        return db, output, summary

    def test_platform_takes_the_next_free_id(self):
        db, _, summary = self.build()
        self.assertEqual(summary["platform_id"], 120)
        self.assertEqual(db.execute("SELECT name, manufacturer_id FROM platforms WHERE id = 120").fetchone(), ("Jaguar CD", 9))

    def test_games_and_roms_follow_the_existing_ids(self):
        db, _, summary = self.build()
        self.assertEqual((summary["games"], summary["roms"]), (5, 6))
        self.assertEqual(db.execute("SELECT MIN(id), MAX(id) FROM games WHERE platform_id = 120").fetchone(), (701, 705))
        self.assertEqual(db.execute("SELECT MIN(id), MAX(id) FROM roms WHERE id > 901").fetchone(), (902, 907))

    def test_serial_is_stored_as_uppercase_hex(self):
        db, _, _ = self.build()
        row = db.execute("SELECT serial_id, display_name, region_id FROM games WHERE full_name = 'Battle Morph (USA)'").fetchone()
        self.assertEqual(row, ("4A3930313745", "Battle Morph", 5))

    def test_games_without_a_free_serial_are_keyed_by_md5(self):
        db, _, summary = self.build()
        keys = dict(db.execute("SELECT full_name, serial_id FROM games WHERE platform_id = 120"))
        self.assertEqual(keys["Battle Morph (USA) (Songbird)"], "md5-" + MD5["songbird"])
        self.assertEqual(keys["Elansar (Europe) (En,Fr,De,Es)"], "md5-" + MD5["elansar"])
        # JA910 belongs to a cartridge on platform 29: the disc must not join its rom.
        self.assertEqual(keys["Iron Soldier 2 (USA) (Songbird)"], "md5-" + MD5["iron"])
        self.assertEqual(summary["md5_keyed"], 4)

    def test_each_md5_finds_its_own_game(self):
        db, _, _ = self.build()
        query = "SELECT games.full_name, games.platform_id FROM roms JOIN games ON games.serial_id = roms.serial_id WHERE roms.md5 = ?"
        self.assertEqual(db.execute(query, (MD5["songbird"],)).fetchall(), [("Battle Morph (USA) (Songbird)", 120)])
        self.assertEqual(db.execute(query, (MD5["multi2"],)).fetchall(), [('Two "Discs" (USA)', 120)])
        self.assertEqual(db.execute(query, ("35EF8CEDBFAB697E380170E438858D4C",)).fetchall(), [("Iron Soldier 2 (USA, Europe)", 29)])

    def test_unknown_region_and_missing_md5(self):
        db, _, summary = self.build()
        self.assertIsNone(db.execute("SELECT region_id FROM games WHERE full_name LIKE 'Iron Soldier 2 (USA) (Songbird)'").fetchone()[0])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM games WHERE full_name = 'No Hash (USA)'").fetchone()[0], 0)
        self.assertTrue(any("No Hash (USA)" in note for note in summary["notes"]))

    def test_output_is_the_input_plus_the_platform(self):
        db, output, summary = self.build()
        db.close()
        self.assertEqual(add_platform.verify(output, self.base, summary["platform_id"], summary), [])

    def test_verify_reports_a_changed_row(self):
        db, output, summary = self.build()
        with db:
            db.execute("UPDATE games SET display_name = 'changed' WHERE id = 700")
        db.close()
        problems = add_platform.verify(output, self.base, summary["platform_id"], summary)
        self.assertTrue(any(problem.startswith("games:") for problem in problems))

    def test_existing_platform_name_or_id_is_refused(self):
        with self.assertRaises(add_platform.DatError):
            self.build(platform_id=29)
        shutil.copyfile(self.base, self.folder / "again.sqlite")
        db = sqlite3.connect(self.folder / "again.sqlite")
        with self.assertRaises(add_platform.DatError):
            add_platform.add_platform(db, DAT, "jaguar", "Atari")

    def test_new_manufacturer_is_added(self):
        db, output, summary = self.build(manufacturer="Songbird")
        self.assertEqual(db.execute("SELECT name FROM manufacturers WHERE id = ?", (summary["manufacturer_id"],)).fetchone(), ("Songbird",))
        db.close()
        self.assertEqual(add_platform.verify(output, self.base, summary["platform_id"], summary), [])


if __name__ == "__main__":
    unittest.main()
