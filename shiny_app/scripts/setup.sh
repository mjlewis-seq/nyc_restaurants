#!/usr/bin/env bash
# ============================================================
# One-command local setup for the DOHMH hackathon database.
# Each teammate runs this on their own machine after cloning
# the repo. It never touches any shared/production server.
#
# Prerequisites:
#   - PostgreSQL installed locally (createdb/psql on PATH)
#   - A local Postgres server running (e.g. `pg_ctl start`,
#     Postgres.app, or `brew services start postgresql`)
# ============================================================
set -euo pipefail
DB_NAME="${DB_NAME:-dohmh_hackathon}"
DB_PORT="${DB_PORT:-5432}"
CSV_PATH="${CSV_PATH:-./data/DOHMH_Restaurant_Inspections.csv}"
CSV_URL="https://data.cityofnewyork.us/api/views/43nn-pn8j/rows.csv?accessType=DOWNLOAD"
echo "==> Target database: ${DB_NAME} (port ${DB_PORT})"
# --- 1. Create the database if it doesn't already exist ---
if psql -p "$DB_PORT" -lqt | cut -d '|' -f 1 | grep -qw "$DB_NAME"; then
    echo "==> Database '${DB_NAME}' already exists, skipping creation."
else
    echo "==> Creating database '${DB_NAME}'..."
    createdb -p "$DB_PORT" "$DB_NAME"
fi
# --- 2. Download the CSV if not already present ---
mkdir -p "$(dirname "$CSV_PATH")"
if [ -f "$CSV_PATH" ]; then
    echo "==> CSV already present at ${CSV_PATH}, skipping download."
else
    echo "==> Downloading dataset from NYC Open Data..."
    curl -L "$CSV_URL" -o "$CSV_PATH"
fi
# --- 3. Apply schema ---
echo "==> Applying schema..."
psql -p "$DB_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f sql/01_schema.sql
# --- 4. Load raw CSV into staging ---
echo "==> Loading CSV into staging table..."
psql -p "$DB_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "\\copy staging_dohmh FROM '${CSV_PATH}' WITH (FORMAT csv, HEADER true)"
# --- 5. Clean + transform into restaurants / inspections ---
echo "==> Transforming staging data into restaurants/inspections..."
psql -p "$DB_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f sql/02_load_and_transform.sql
echo "==> Done. Connect with: psql -p ${DB_PORT} -d ${DB_NAME}"
echo "==> Or in pgAdmin: register a server on localhost:${DB_PORT}, then select the '${DB_NAME}' database (NOT template1/postgres)."