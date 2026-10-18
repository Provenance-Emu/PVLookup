

CREATE TABLE developers (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE franchises (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE games (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    -- rom_id INTEGER,
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
    -- boxart_url TEXT,
    platform_id INTEGER
);


CREATE TABLE genres (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE manufacturers (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE platforms (
    id INTEGER PRIMARY KEY,
    name TEXT,
    manufacturer_id INTEGER
);


CREATE TABLE publishers (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE ratings (
    id INTEGER PRIMARY KEY,
    name TEXT
);


CREATE TABLE regions (
    id INTEGER PRIMARY KEY,
    name TEXT
);


-- NOTE: `crc TEXT` is an iFly addition vs the original third-party schema. The
-- shipped DB is now generated in-repo by Scripts/generate_libretrodb.py, which
-- populates crc (so searchByCRC can work) and creates the query indexes below.
CREATE TABLE roms (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    name TEXT,
    md5 TEXT,
    crc TEXT
);


-- Add artwork table
CREATE TABLE artwork (
    id INTEGER PRIMARY KEY,
    serial_id TEXT,
    type TEXT,      -- boxart, screenshot, titlescreen, etc.
    url TEXT,       -- URL to the artwork
    FOREIGN KEY(serial_id) REFERENCES games(serial_id)
);


-- Create index for faster artwork lookups
CREATE INDEX idx_artwork_serial_id ON artwork(serial_id);
CREATE INDEX idx_artwork_type ON artwork(type);

-- Query indexes added by the in-repo generator (the original third-party DB had
-- NONE on games/roms — md5/serial/crc lookups did full table scans → multi-second
-- stalls). LibretroDBManager.ensureIndexes() also creates the roms/games subset
-- defensively on the writable Caches copy in case an older DB is in place.
CREATE INDEX idx_roms_md5          ON roms(md5);
CREATE INDEX idx_roms_crc          ON roms(crc);
CREATE INDEX idx_roms_serial_id    ON roms(serial_id);
CREATE INDEX idx_games_platform_id ON games(platform_id);
CREATE INDEX idx_games_serial_id   ON games(serial_id);
CREATE INDEX idx_games_display_name ON games(display_name COLLATE NOCASE);
