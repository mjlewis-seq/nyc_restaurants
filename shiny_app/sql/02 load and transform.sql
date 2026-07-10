-- ============================================================
-- STEP A: Get the CSV into staging_dohmh
-- ============================================================
-- If you ran scripts/setup.sh, this step is already done for you.
--
-- To do it manually instead:
-- Option 1 (easiest in pgAdmin): right-click staging_dohmh in the
-- browser tree -> Import/Export Data... -> point it at your CSV,
-- format=csv, header=yes, delimiter=",".
--
-- Option 2 (psql command line, fastest for 296k rows):
--   \copy staging_dohmh FROM '/path/to/DOHMH_New_York_City_Restaurant_Inspection_Results.csv' WITH (FORMAT csv, HEADER true)
--
-- Either way, load the RAW csv into staging_dohmh first, then run
-- everything below in pgAdmin's Query Tool.


-- ============================================================
-- STEP B: Populate restaurants (dimension, deduped by CAMIS)
-- We take the most recent row per CAMIS (by record_date) as the
-- "current" snapshot of that restaurant's identity/location.
-- ============================================================
INSERT INTO restaurants (
    camis, dba, boro, building, street, zipcode, phone,
    latitude, longitude, community_board, council_district,
    census_tract, bin, bbl, nta, geog
)
SELECT DISTINCT ON (camis::bigint)
    camis::bigint,
    dba,
    NULLIF(boro, '0'),
    building,
    street,
    NULLIF(zipcode, ''),
    NULLIF(phone, ''),
    NULLIF(latitude, '0')::double precision,
    NULLIF(longitude, '0')::double precision,
    NULLIF(community_board, ''),
    NULLIF(council_district, ''),
    NULLIF(census_tract, ''),
    NULLIF(bin, ''),
    NULLIF(bbl, ''),
    NULLIF(nta, ''),
    CASE
        WHEN NULLIF(latitude, '0') IS NOT NULL AND NULLIF(longitude, '0') IS NOT NULL
        THEN ST_SetSRID(ST_MakePoint(longitude::double precision, latitude::double precision), 4326)::geography
        ELSE NULL
    END
FROM staging_dohmh
WHERE camis ~ '^\d+$'                -- guard against any malformed rows
ORDER BY camis::bigint, record_date DESC;


-- ============================================================
-- STEP C: Populate inspections (fact table, every row)
-- ============================================================
INSERT INTO inspections (
    camis, inspection_date, action, violation_code, violation_description,
    critical_flag, score, grade, grade_date, record_date, inspection_type,
    cuisine_description
)
SELECT
    camis::bigint,
    CASE WHEN inspection_date = '01/01/1900' OR inspection_date = '' THEN NULL
         ELSE to_date(inspection_date, 'MM/DD/YYYY') END,
    NULLIF(action, ''),
    NULLIF(violation_code, ''),
    NULLIF(violation_description, ''),
    NULLIF(critical_flag, 'Not Applicable'),
    NULLIF(score, '')::integer,
    NULLIF(grade, ''),
    CASE WHEN grade_date = '' THEN NULL ELSE to_date(grade_date, 'MM/DD/YYYY') END,
    CASE WHEN record_date = '' THEN NULL ELSE to_date(record_date, 'MM/DD/YYYY') END,
    NULLIF(inspection_type, ''),
    NULLIF(cuisine_description, '')
FROM staging_dohmh
WHERE camis ~ '^\d+$';


-- ============================================================
-- STEP D: Sanity checks
-- ============================================================
SELECT count(*) AS restaurant_count FROM restaurants;
SELECT count(*) AS inspection_row_count FROM inspections;

-- Example queries you'll likely want for the hackathon:

-- Current letter grade per restaurant (most recent graded inspection)
-- SELECT DISTINCT ON (camis) camis, grade, grade_date
-- FROM inspections
-- WHERE grade IS NOT NULL
-- ORDER BY camis, grade_date DESC;

-- Restaurants within 500m of a point (needs PostGIS)
-- SELECT dba, street, boro
-- FROM restaurants
-- WHERE ST_DWithin(geog, ST_MakePoint(-73.9857, 40.7484)::geography, 500);

-- Critical violation rate by cuisine
-- SELECT cuisine_description,
--        count(*) FILTER (WHERE critical_flag = 'Critical') AS critical_count,
--        count(*) AS total
-- FROM inspections
-- WHERE cuisine_description IS NOT NULL
-- GROUP BY cuisine_description
-- ORDER BY critical_count DESC;