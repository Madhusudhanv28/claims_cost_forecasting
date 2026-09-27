-- ============================================================
-- 01_staging.sql
-- Staging (Bronze) layer: land the raw CSVs exactly as received.
-- Every column is VARCHAR on purpose -- staging must never reject
-- or silently alter dirty data. Type-casting and cleaning happen
-- in the next layer (02_core.sql), not here.
-- ============================================================

USE claims_forecasting;

-- ---------- Drop and recreate for idempotent reruns ----------
DROP TABLE IF EXISTS staging_claims_raw;
DROP TABLE IF EXISTS staging_membership_raw;

-- ---------- staging_claims_raw ----------
-- Grain: one row per claim record as it appears in the source file
-- (duplicates, adjustments, and dirty values included on purpose).
CREATE TABLE staging_claims_raw (
    row_id                          INT AUTO_INCREMENT PRIMARY KEY,  -- surrogate row id, not a business key
    claim_id                        VARCHAR(20),
    member_id                       VARCHAR(20),
    provider_id                     VARCHAR(20),
    provider_npi                    VARCHAR(20),
    service_date                    VARCHAR(20),
    claim_submission_date           VARCHAR(20),
    paid_date                       VARCHAR(20),
    diagnosis_code_1                VARCHAR(20),
    diagnosis_code_2                VARCHAR(20),
    procedure_code                  VARCHAR(20),
    revenue_code                    VARCHAR(20),
    claim_type                      VARCHAR(30),
    place_of_service                VARCHAR(50),
    length_of_stay                  VARCHAR(20),
    billed_amount                   VARCHAR(20),
    allowed_amount                  VARCHAR(20),
    paid_amount                     VARCHAR(20),
    patient_responsibility_amount   VARCHAR(20),
    claim_status                    VARCHAR(20),
    denial_reason_code              VARCHAR(30),
    provider_type                   VARCHAR(30),
    provider_specialty              VARCHAR(50),
    network_status                  VARCHAR(30),
    patient_age                     VARCHAR(20),
    patient_sex                     VARCHAR(5),
    region                          VARCHAR(30),
    chronic_flag_diabetes           VARCHAR(5),
    chronic_flag_chf                VARCHAR(5),
    chronic_flag_cancer             VARCHAR(5),
    chronic_flag_copd               VARCHAR(5),
    chronic_flag_esrd               VARCHAR(5),
    adjustment_flag                 VARCHAR(5),
    original_claim_id               VARCHAR(20),
    record_source                   VARCHAR(30),
    load_timestamp                  VARCHAR(30),
    _loaded_at                      TIMESTAMP DEFAULT CURRENT_TIMESTAMP  -- when THIS load ran, for our own tracking
);

-- ---------- staging_membership_raw ----------
-- Grain: one row per member per enrolled month, as reported.
CREATE TABLE staging_membership_raw (
    row_id                          INT AUTO_INCREMENT PRIMARY KEY,
    member_id                       VARCHAR(20),
    month_year                      VARCHAR(10),
    plan_type                       VARCHAR(20),
    region                          VARCHAR(30),
    enrollment_status               VARCHAR(20),
    birth_date                      VARCHAR(40),   -- widened: source values include a full timestamp, not just a date
    sex                             VARCHAR(5),
    _loaded_at                      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- LOAD DATA -- adjust the file paths below to wherever your
-- CSVs sit in MySQL's secure_file_priv folder on YOUR machine.
-- Use forward slashes even on Windows (C:/... not C:\...).
-- ============================================================

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/claims_raw.csv'
INTO TABLE staging_claims_raw
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(claim_id, member_id, provider_id, provider_npi, service_date, claim_submission_date,
 paid_date, diagnosis_code_1, diagnosis_code_2, procedure_code, revenue_code, claim_type,
 place_of_service, length_of_stay, billed_amount, allowed_amount, paid_amount,
 patient_responsibility_amount, claim_status, denial_reason_code, provider_type,
 provider_specialty, network_status, patient_age, patient_sex, region,
 chronic_flag_diabetes, chronic_flag_chf, chronic_flag_cancer, chronic_flag_copd,
 chronic_flag_esrd, adjustment_flag, original_claim_id, record_source, load_timestamp);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/membership_raw.csv'
INTO TABLE staging_membership_raw
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(member_id, month_year, plan_type, region, enrollment_status, birth_date, sex);

-- ============================================================
-- Sanity check: row counts should roughly match what generate.py
-- printed when it ran (~1,014,550 claims / ~1,214,303 membership rows,
-- give or take -- your own run used a fresh random seed, so exact
-- counts may differ slightly).
-- ============================================================
SELECT 'staging_claims_raw' AS table_name, COUNT(*) AS row_count FROM staging_claims_raw
UNION ALL
SELECT 'staging_membership_raw', COUNT(*) FROM staging_membership_raw;