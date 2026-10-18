#!/usr/bin/env bash
# generate_libretrodb_if_needed.sh
#
# Generates iFly's LibretroDB metadata SQLite (libretrodb.sqlite.generated[.zip]) from the
# upstream libretro `.rdb` files. This is the side-by-side review artifact produced by
# generate_libretrodb.py — it ADDS a `crc` column and the missing query indexes that the
# shipped third-party `libretrodb.sqlite.zip` lacks.
#
# It does NOT overwrite the shipped `libretrodb.sqlite.zip`. Review the `.generated.zip`,
# then swap it in separately.
#
# Pipeline:
#   1. Acquire the source data (libretro-database):
#        a. Reuse a local checkout if one exists (env LIBRETRO_DATABASE_DIR, or a sibling clone).
#        b. Else `git clone --depth=1` from GitHub.
#        c. Else (no network) fall back to per-file `curl` of just the four Dreamcast-family
#           `.rdb` files into build-libretrodb/rdb/.
#   2. Build libretrodb_tool if not already built (prefers a local libretro-db C source tree;
#        Provenance ships one under CoresRetro/RetroArch/RetroArch/libretro-db/).
#   3. Invoke generate_libretrodb.py.
#   4. Record the source commit pin in build-libretrodb/libretro-database.pin.
#
# Usage:
#   Tools/libretrodb/generate_libretrodb_if_needed.sh
#   FORCE=1 Tools/libretrodb/generate_libretrodb_if_needed.sh   # regenerate even if present
#
# Output: .build-libretrodb/out/libretrodb.sqlite.generated[.zip]. Publish the zip as
# libretrodb-dreamcast.sqlite.zip in a new databases-YYYY-MM-DD release (see README.md).
#
# Requires: python3, a C compiler (xcrun clang / clang / cc), and either git+network or curl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVLOOKUP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# PVLookup ships no databases, so the output goes to a gitignored work dir.
RESOURCE_DIR="$PVLOOKUP_ROOT/.build-libretrodb/out"
mkdir -p "$RESOURCE_DIR"
GENERATOR="$SCRIPT_DIR/generate_libretrodb.py"
BUILD_DIR="$PVLOOKUP_ROOT/.build-libretrodb"
RDB_DIR="$BUILD_DIR/rdb"
TOOL="$BUILD_DIR/libretrodb_tool"
GENERATED_ZIP="$RESOURCE_DIR/libretrodb.sqlite.generated.zip"
PIN_FILE="$BUILD_DIR/libretro-database.pin"

# Candidate locations for a local libretro-db C source tree (to build libretrodb_tool offline).
PROVENANCE_LIBRETRO_DB="${PROVENANCE_DIR:-$HOME/Workspace/Provenance/Provenance}/CoresRetro/RetroArch/RetroArch/libretro-db"

# The four Dreamcast-family .rdb basenames upstream (note casing / Atomiswave has no "Sega - ").
RDB_BASENAMES=("Sega - Dreamcast" "Sega - Naomi" "Sega - Naomi 2" "Atomiswave")
RAW_BASE="https://raw.githubusercontent.com/libretro/libretro-database/master/rdb"

mkdir -p "$BUILD_DIR" "$RDB_DIR"

# --- Idempotency -------------------------------------------------------------------------------
if [ "${FORCE:-0}" != "1" ] && [ -f "$GENERATED_ZIP" ]; then
    SZ=$(stat -f%z "$GENERATED_ZIP" 2>/dev/null || stat -c%s "$GENERATED_ZIP" 2>/dev/null || echo 0)
    if [ "$SZ" -gt 1000 ]; then
        echo "libretrodb.sqlite.generated.zip already exists ($SZ bytes). Set FORCE=1 to regenerate."
        exit 0
    fi
fi

command -v python3 >/dev/null 2>&1 || { echo "Error: python3 required" >&2; exit 1; }

# --- Step 1: acquire libretro-database ---------------------------------------------------------
LIBRETRO_DB_ROOT=""        # repo root that contains rdb/ and metadat/ (for CRC supplement)
SOURCE_COMMIT="unknown"

url_encode() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

if [ -n "${LIBRETRO_DATABASE_DIR:-}" ] && [ -d "$LIBRETRO_DATABASE_DIR/rdb" ]; then
    echo "Using libretro-database from \$LIBRETRO_DATABASE_DIR: $LIBRETRO_DATABASE_DIR"
    LIBRETRO_DB_ROOT="$LIBRETRO_DATABASE_DIR"
elif [ -d "$BUILD_DIR/libretro-database/rdb" ]; then
    echo "Using previously-cloned libretro-database: $BUILD_DIR/libretro-database"
    LIBRETRO_DB_ROOT="$BUILD_DIR/libretro-database"
else
    echo "Cloning libretro-database (shallow)..."
    if git clone --depth=1 --quiet https://github.com/libretro/libretro-database.git \
        "$BUILD_DIR/libretro-database" 2>/dev/null; then
        LIBRETRO_DB_ROOT="$BUILD_DIR/libretro-database"
    else
        echo "git clone failed (offline?). Falling back to per-file curl of the .rdb files." >&2
    fi
fi

# If we have a full checkout, copy the needed .rdb files into RDB_DIR (so the generator has a
# single flat dir) and read the commit pin.
if [ -n "$LIBRETRO_DB_ROOT" ]; then
    for base in "${RDB_BASENAMES[@]}"; do
        if [ -f "$LIBRETRO_DB_ROOT/rdb/$base.rdb" ]; then
            cp -f "$LIBRETRO_DB_ROOT/rdb/$base.rdb" "$RDB_DIR/$base.rdb"
        else
            echo "  Warning: $base.rdb not present in checkout" >&2
        fi
    done
    if [ -d "$LIBRETRO_DB_ROOT/.git" ]; then
        SOURCE_COMMIT="$(git -C "$LIBRETRO_DB_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    fi
fi

# Fallback / supplement: ensure every .rdb is present; curl any that are missing.
for base in "${RDB_BASENAMES[@]}"; do
    target="$RDB_DIR/$base.rdb"
    if [ ! -s "$target" ]; then
        enc="$(url_encode "$base")"
        echo "  Downloading $base.rdb ..."
        if ! curl -sS -L --max-time 120 -o "$target" "$RAW_BASE/$enc.rdb"; then
            echo "  Warning: failed to download $base.rdb (no network?)" >&2
        fi
        # Guard against the 14-byte "404: Not Found" stub.
        SZ=$(stat -f%z "$target" 2>/dev/null || stat -c%s "$target" 2>/dev/null || echo 0)
        if [ "$SZ" -lt 64 ]; then
            echo "  Warning: $base.rdb looks like a 404 stub ($SZ bytes); removing" >&2
            rm -f "$target"
        fi
    fi
done

if ! ls "$RDB_DIR"/*.rdb >/dev/null 2>&1; then
    echo "Error: no .rdb files acquired. Provide LIBRETRO_DATABASE_DIR or restore network." >&2
    exit 1
fi

# --- Step 2: build libretrodb_tool if missing --------------------------------------------------
LIBRETRO_DB_SRC=""
if [ ! -x "$TOOL" ]; then
    if [ -f "$PROVENANCE_LIBRETRO_DB/libretrodb_tool.c" ]; then
        LIBRETRO_DB_SRC="$PROVENANCE_LIBRETRO_DB"
    elif [ -f "$LIBRETRO_DB_ROOT/../libretro-common/string/stdstring.c" 2>/dev/null ]; then
        # Some checkouts vendor the C tool too; not the common case.
        LIBRETRO_DB_SRC="$LIBRETRO_DB_ROOT"
    fi
    if [ -z "$LIBRETRO_DB_SRC" ]; then
        echo "Error: libretrodb_tool not built and no libretro-db C source tree found." >&2
        echo "       Expected at: $PROVENANCE_LIBRETRO_DB" >&2
        echo "       (Provenance ships it under CoresRetro/RetroArch/RetroArch/libretro-db/)" >&2
        exit 1
    fi
    echo "Building libretrodb_tool from $LIBRETRO_DB_SRC ..."
fi

# --- Step 3: run the generator -----------------------------------------------------------------
GEN_ARGS=(
    --rdb-dir "$RDB_DIR"
    --output "$RESOURCE_DIR/libretrodb.sqlite.generated"
    --build-dir "$BUILD_DIR"
    --source-commit "$SOURCE_COMMIT"
)
[ -x "$TOOL" ] && GEN_ARGS+=(--tool "$TOOL")
[ -n "$LIBRETRO_DB_SRC" ] && GEN_ARGS+=(--libretro-db-src "$LIBRETRO_DB_SRC")
[ -n "$LIBRETRO_DB_ROOT" ] && GEN_ARGS+=(--dat-dir "$LIBRETRO_DB_ROOT")

echo "Running generate_libretrodb.py ..."
python3 "$GENERATOR" "${GEN_ARGS[@]}"

# --- Step 4: record the pin --------------------------------------------------------------------
{
    echo "source=libretro/libretro-database"
    echo "commit=$SOURCE_COMMIT"
    echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PIN_FILE"

echo ""
echo "Done. Review artifact:"
echo "  $GENERATED_ZIP"
echo "Pin recorded: $PIN_FILE"
