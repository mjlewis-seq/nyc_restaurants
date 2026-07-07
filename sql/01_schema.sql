-- ============================================================
-- DOHMH Restaurant Inspection schema
-- Run this first in pgAdmin's Query Tool (against your target DB)
-- ============================================================

-- Optional but recommended: enables geospatial types/functions
-- (distance queries, joins to other geo datasets, mapping, etc.)
-- If your Postgres instance doesn't have PostGIS available, comment
-- this out and skip the `geog` column below -- everything else still works.
CREATE EXTENSION IF NOT EXISTS postgis;

-- ------------------------------------------------------------
-- 1. STAGING TABLE
-- Mirrors the raw CSV exactly (all text) so COPY never fails
-- on a bad date/number. We clean and cast when moving data
-- out of this table below.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS staging_dohmh;
CREATE TABLE staging_dohmh (
    camis               text,
    dba                 text,
    boro                text,
    building            text,
    street              text,
    zipcode             text,
    phone               text,
    cuisine_description text,
    inspection_date     text,
    action              text,
    violation_code      text,
    violation_description text,
    critical_flag       text,
    score               text,
    grade               text,
    grade_date          text,
    record_date         text,
    inspection_type      text,
    latitude            text,
    longitude           text,
    community_board     text,
    council_district     text,
    census_tract         text,
    bin                 text,
    bbl                 text,
    nta                 text,
    location            text
);

-- ------------------------------------------------------------
-- 2. RESTAURANTS (dimension table -- one row per CAMIS)
-- Holds the "current" identity/location info for each restaurant.
-- This is what you'll join to other datasets via camis / bbl / bin / zipcode / geog.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS restaurants CASCADE;
CREATE TABLE restaurants (
    camis            bigint PRIMARY KEY,
    dba              text,
    boro             text,
    building         text,
    street           text,
    zipcode          text,
    phone            text,
    latitude         double precision,
    longitude        double precision,
    community_board  text,
    council_district text,
    census_tract     text,
    bin              text,
    bbl              text,
    nta              text,
    geog             geography(Point, 4326)   -- remove this line if you skipped PostGIS
);

-- ------------------------------------------------------------
-- 3. INSPECTIONS (fact table -- one row per violation/inspection record)
-- This is the granular table: multiple rows per CAMIS over time.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS inspections;
CREATE TABLE inspections (
    id                     bigserial PRIMARY KEY,
    camis                  bigint REFERENCES restaurants(camis),
    inspection_date        date,
    action                 text,
    violation_code         text,
    violation_description text,
    critical_flag          text,
    score                  integer,
    grade                  text,
    grade_date             date,
    record_date            date,
    inspection_type        text,
    cuisine_description    text
);

-- Helpful indexes for the joins/queries you'll actually run
CREATE INDEX idx_restaurants_zipcode   ON restaurants (zipcode);
CREATE INDEX idx_restaurants_boro      ON restaurants (boro);
CREATE INDEX idx_restaurants_bbl       ON restaurants (bbl);
CREATE INDEX idx_restaurants_geog      ON restaurants USING gist (geog);

CREATE INDEX idx_inspections_camis         ON inspections (camis);
CREATE INDEX idx_inspections_date          ON inspections (inspection_date);
CREATE INDEX idx_inspections_critical_flag ON inspections (critical_flag);
CREATE INDEX idx_inspections_grade         ON inspections (grade);
