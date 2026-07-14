-- Reference table for NYC DOHMH violation codes.
-- Source: https://github.com/nychealth/Food-Safety-Health-Code-Reference
--   (main branch, file: Violation-Health-Code-Mapping.csv)
--
-- Confirmed real header row (10 columns):
--   Violation_Code, Health_Code, Violation_Summary, Category_Description,
--   Violation_Template, Condition I, Condition II, Condition III,
--   Condition IV, Condition V

DROP TABLE IF EXISTS staging_violation_codebook CASCADE;
DROP TABLE IF EXISTS violation_health_code_mapping CASCADE;

-- Step 1: staging table matching the CSV's actual shape exactly.
CREATE TABLE staging_violation_codebook (
    violation_code        text,
    health_code            text,
    violation_summary      text,
    category_description   text,
    violation_template      text,
    condition_i             text,
    condition_ii            text,
    condition_iii           text,
    condition_iv             text,
    condition_v              text
);

-- Loads the CSV into staging. Path is relative to wherever you invoke
-- psql from (run this script from your project root).
\copy staging_violation_codebook FROM 'data/Violation-Health-Code-Mapping.csv' WITH (FORMAT csv, HEADER true)

-- Step 2: clean reference table with just the columns app.R needs.
CREATE TABLE violation_health_code_mapping (
    violation_code       varchar(10) PRIMARY KEY,
    health_code_citation text,
    description           text,
    category               text
);

INSERT INTO violation_health_code_mapping (violation_code, health_code_citation, description, category)
SELECT DISTINCT ON (violation_code)
    violation_code,
    health_code,
    violation_summary,
    category_description
FROM staging_violation_codebook
WHERE violation_code IS NOT NULL AND violation_code <> ''
ORDER BY violation_code;

-- Sanity checks after loading:
-- SELECT * FROM violation_health_code_mapping WHERE category ILIKE '%refrigeration%';
-- SELECT COUNT(*) FROM violation_health_code_mapping;  -- should be > 0

-- Cross-check against codes that actually appear in your loaded inspections data:
-- SELECT DISTINCT i.violation_code
-- FROM inspections i
-- LEFT JOIN violation_health_code_mapping v ON v.violation_code = i.violation_code
-- WHERE v.violation_code IS NULL;