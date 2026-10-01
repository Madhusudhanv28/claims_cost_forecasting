-- ============================================================
-- 03_core.sql
-- Core (Silver) layer: clean, deduplicated, typed fact and dimension
-- tables, built entirely from decisions D1-D17 in
-- docs/02_profiling_findings.md. Every choice below traces to a
-- specific profiling finding -- see the comments and the doc.
--
-- Reads from: staging_claims_raw, staging_membership_raw
-- Produces:   dim_calendar, dim_provider, dim_member, fact_claim
--
-- Run this with SOURCE in the MySQL Command Line Client (Workbench
-- has timed out on large operations for us before). Safe to rerun:
-- everything is dropped and rebuilt from staging each time, except
-- the two ADD INDEX lines in Section 0, which only need to run once
-- -- skip them if you see error 1061 on a rerun.
-- ============================================================

USE claims_forecasting;

-- ============================================================
-- PERFORMANCE SETTINGS
-- ============================================================
SET SESSION tmp_table_size = 536870912;
SET SESSION max_heap_table_size = 536870912;

-- One-time permanent indexes needed by this build.
-- If an index already exists, ERROR 1061 is harmless; continue.
ALTER TABLE staging_claims_raw
    ADD INDEX idx_original_claim_id (original_claim_id);

ALTER TABLE staging_membership_raw
    ADD INDEX idx_member_month (member_id, month_year);

ALTER TABLE staging_claims_raw
    ADD INDEX idx_member_chronic (
        member_id,
        chronic_flag_diabetes,
        chronic_flag_chf,
        chronic_flag_cancer,
        chronic_flag_copd,
        chronic_flag_esrd
    );

-- ============================================================
-- SECTION 1: dim_calendar
-- Grain: one row per calendar day across the data's actual range.
-- ============================================================
DROP TABLE IF EXISTS fact_claim;   -- drop fact first: it references the dims below
DROP TABLE IF EXISTS dim_calendar;
DROP TABLE IF EXISTS dim_provider;
DROP TABLE IF EXISTS dim_member;

CREATE TABLE dim_calendar (
    calendar_date   DATE PRIMARY KEY,
    month_year      VARCHAR(7),
    year            INT,
    month           INT,
    quarter         INT,
    is_month_end    TINYINT(1)
);

-- MySQL's recursive CTE depth defaults to 1000; our range is ~1096
-- days, so this must be raised first or the insert silently stops
-- partway through.
SET SESSION cte_max_recursion_depth = 2000;

INSERT INTO dim_calendar
WITH RECURSIVE seq AS (
    SELECT DATE('2022-01-01') AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM seq WHERE d < '2024-12-31'
)
SELECT d,
       DATE_FORMAT(d, '%Y-%m'),
       YEAR(d),
       MONTH(d),
       QUARTER(d),
       (d = LAST_DAY(d))
FROM seq;


-- ============================================================
-- SECTION 2: dim_provider
-- Grain: one row per provider_id.
-- Decision D16: profiling (8.1) found zero providers with a
-- conflicting type, specialty, network status or NPI across all
-- 3,000 -- so it is safe to collapse straight to one row per
-- provider with a simple GROUP BY. MAX() is used only because
-- MySQL's ONLY_FULL_GROUP_BY mode requires every selected column
-- to be wrapped in an aggregate; since every value in the group is
-- identical (confirmed by profiling), MAX() just returns that value.
-- Note: no region column here. Provider region exists inside the
-- generator but was never written to claims_raw.csv, so it isn't
-- something the pipeline can honestly claim to have.
-- ============================================================
CREATE TABLE dim_provider (
    provider_sk         INT AUTO_INCREMENT PRIMARY KEY,
    provider_id          VARCHAR(20) NOT NULL UNIQUE,
    provider_npi         VARCHAR(20),
    provider_type        VARCHAR(30),
    provider_specialty   VARCHAR(50),
    network_status       VARCHAR(30)
);

INSERT INTO dim_provider (provider_id, provider_npi, provider_type, provider_specialty, network_status)
SELECT provider_id,
       MAX(provider_npi),
       MAX(provider_type),
       MAX(provider_specialty),
       MAX(network_status)
FROM staging_claims_raw
GROUP BY provider_id;


-- ============================================================
-- SECTION 3: dim_member
-- Grain: one row per member_id, plus one reserved "Unknown" row.
-- Decision D16: profiling (8.2, 8.3) found zero members with a
-- conflicting sex, chronic flag, plan, birth date or region, so
-- these attributes are safe to store once per member.
-- Decision D5: orphan claims (member_id not in membership at all)
-- point at this single shared "Unknown" row instead of getting an
-- invented dimension row of their own -- standard practice, and it
-- keeps the dimension from growing by 25,387 fake entities.
-- ============================================================
CREATE TABLE dim_member (
    member_sk               INT AUTO_INCREMENT PRIMARY KEY,
    member_id                VARCHAR(20) NOT NULL UNIQUE,
    birth_date                DATE NULL,
    sex                        VARCHAR(5) NULL,
    plan_type                  VARCHAR(20) NULL,
    region                      VARCHAR(20) NULL,
    chronic_flag_diabetes     TINYINT(1) NULL,
    chronic_flag_chf          TINYINT(1) NULL,
    chronic_flag_cancer       TINYINT(1) NULL,
    chronic_flag_copd         TINYINT(1) NULL,
    chronic_flag_esrd         TINYINT(1) NULL
);

-- The reserved row FIRST, so it gets member_sk = 1.
INSERT INTO dim_member (member_id, birth_date, sex, plan_type, region)
VALUES ('UNKNOWN', NULL, NULL, NULL, NULL);

-- Real members, from the membership file (the source of truth for
-- who is actually enrolled -- claims-only "members" are orphans,
-- handled separately, not given a real dim_member row).
INSERT INTO dim_member (member_id, birth_date, sex, plan_type, region)
SELECT member_id,
       MAX(STR_TO_DATE(LEFT(birth_date, 10), '%Y-%m-%d')),
       MAX(sex),
       MAX(plan_type),
       MAX(
           CASE
               WHEN LOWER(TRIM(region)) IN ('south', 's')              THEN 'South'
               WHEN LOWER(TRIM(region)) IN ('midwest', 'mw', 'mid west') THEN 'Midwest'
               WHEN LOWER(TRIM(region)) IN ('northeast', 'ne', 'north east') THEN 'Northeast'
               WHEN LOWER(TRIM(region)) IN ('west', 'w')               THEN 'West'
               ELSE NULL
           END
       )
FROM staging_membership_raw
GROUP BY member_id;

-- Chronic flags only exist in the CLAIMS file (D-SynPUF-style flags
-- were never part of membership_raw.csv), so they are added with an
-- UPDATE from an aggregated claims lookup. Members with no claims
-- simply keep NULL here -- that is correct: "unknown," not "false."
DROP TEMPORARY TABLE IF EXISTS tmp_member_chronic;

CREATE TEMPORARY TABLE tmp_member_chronic AS
SELECT
    member_id,
    MAX(chronic_flag_diabetes) AS d,
    MAX(chronic_flag_chf)      AS chf,
    MAX(chronic_flag_cancer)   AS canc,
    MAX(chronic_flag_copd)     AS copd,
    MAX(chronic_flag_esrd)     AS esrd
FROM staging_claims_raw
GROUP BY member_id;

ALTER TABLE tmp_member_chronic
    ADD PRIMARY KEY (member_id);

UPDATE dim_member dm
JOIN tmp_member_chronic c ON c.member_id = dm.member_id
SET dm.chronic_flag_diabetes = c.d,
    dm.chronic_flag_chf      = c.chf,
    dm.chronic_flag_cancer   = c.canc,
    dm.chronic_flag_copd     = c.copd,
    dm.chronic_flag_esrd     = c.esrd;


-- ============================================================
-- SECTION 4: deduplicate and standardize ORIGINAL claims
-- (adjustment_flag = '0', the "C..." claim_id rows)
-- Decision D1/D2: claim_id is not unique (14,775 duplicated pairs,
-- and the copies often disagree -- profiling 2.1/2.2). A plain
-- DISTINCT would keep both sides of a disagreeing pair. Instead,
-- every copy is scored on five validity checks, and only the
-- highest-scoring copy per claim_id survives (ties broken by the
-- earliest row_id).
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_claims_scored;
CREATE TEMPORARY TABLE tmp_claims_scored AS
SELECT
    c.row_id,
    c.claim_id,
    c.member_id,
    c.provider_id,
    c.service_date,
    c.claim_submission_date,
    NULLIF(TRIM(c.paid_date), '')          AS paid_date,
    c.diagnosis_code_1,
    NULLIF(TRIM(c.diagnosis_code_2), '')   AS diagnosis_code_2,
    NULLIF(TRIM(c.procedure_code), '')     AS procedure_code,
    NULLIF(TRIM(c.revenue_code), '')       AS revenue_code,
    c.claim_type,
    NULLIF(TRIM(c.length_of_stay), '')     AS length_of_stay_raw,
    CAST(NULLIF(TRIM(c.billed_amount), '')  AS DECIMAL(14,2)) AS billed_amount,
    CAST(NULLIF(TRIM(c.allowed_amount), '') AS DECIMAL(14,2)) AS allowed_amount,
    CAST(NULLIF(TRIM(c.paid_amount), '')    AS DECIMAL(14,2)) AS paid_amount_raw,
    CAST(NULLIF(TRIM(c.patient_responsibility_amount), '') AS DECIMAL(14,2)) AS patient_responsibility_amount,
    -- D12: one standardization mapping for every raw claim_status spelling
    CASE
        WHEN LOWER(TRIM(c.claim_status)) IN ('paid', 'pd') THEN 'Paid'
        WHEN LOWER(TRIM(c.claim_status)) = 'denied'        THEN 'Denied'
        WHEN LOWER(TRIM(c.claim_status)) = 'pending'       THEN 'Pending'
        ELSE NULL
    END                                     AS claim_status,
    NULLIF(TRIM(c.denial_reason_code), '') AS denial_reason_code,
    -- D9: implausible age becomes NULL + a flag, not a guess or a deletion
    CASE WHEN c.patient_age REGEXP '^-?[0-9]+([.][0-9]+)?$'
              AND CAST(c.patient_age AS DECIMAL(6,1)) BETWEEN 0 AND 110
         THEN CAST(c.patient_age AS DECIMAL(6,1)) END AS patient_age,
    CASE WHEN c.patient_age REGEXP '^-?[0-9]+([.][0-9]+)?$'
              AND CAST(c.patient_age AS DECIMAL(6,1)) BETWEEN 0 AND 110
         THEN 0 ELSE 1 END                  AS age_invalid,
    -- D11: load_timestamp arrives in two valid formats (F8) plus real
    -- malformed values -- parse both, NULL only the genuine failures.
    -- NOTE: the regex validates real month(01-12)/day(01-31) ranges, not
    -- just digit shape -- '2025-13-45' looks date-shaped but has an
    -- invalid month, and STR_TO_DATE hard-errors (not just returns NULL)
    -- on a value like that, which would otherwise crash the whole build.
    CASE
        WHEN c.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$'
            THEN STR_TO_DATE(c.load_timestamp, '%Y-%m-%d %H:%i:%s')
        WHEN c.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
            THEN STR_TO_DATE(c.load_timestamp, '%Y-%m-%d')
        ELSE NULL
    END                                     AS load_timestamp_parsed,
    CASE WHEN c.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])( ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9])?$'
         THEN 0 ELSE 1 END                  AS load_timestamp_malformed,
    c.record_source,
    -- the survivorship score: +1 for each validity signal this copy passes
    ( (CASE WHEN dm.member_id IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN NULLIF(TRIM(c.procedure_code), '') IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN c.patient_age REGEXP '^-?[0-9]+([.][0-9]+)?$'
                  AND CAST(c.patient_age AS DECIMAL(6,1)) BETWEEN 0 AND 110 THEN 1 ELSE 0 END)
    + (CASE WHEN CAST(NULLIF(TRIM(c.paid_amount), '') AS DECIMAL(14,2))
                 <= CAST(NULLIF(TRIM(c.allowed_amount), '') AS DECIMAL(14,2)) THEN 1 ELSE 0 END)
    + (CASE WHEN c.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])( ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9])?$'
             THEN 1 ELSE 0 END)
    )                                       AS validity_score
FROM staging_claims_raw c
LEFT JOIN dim_member dm
       ON dm.member_id = c.member_id AND dm.member_id <> 'UNKNOWN'
WHERE c.adjustment_flag = '0';

-- Pick the highest validity_score per claim_id without sorting the
-- entire wide ~1M-row temporary table with ROW_NUMBER().
DROP TEMPORARY TABLE IF EXISTS tmp_claim_best_score;
CREATE TEMPORARY TABLE tmp_claim_best_score AS
SELECT claim_id, MAX(validity_score) AS validity_score
FROM tmp_claims_scored
GROUP BY claim_id;

ALTER TABLE tmp_claim_best_score
    ADD PRIMARY KEY (claim_id);

-- On a score tie, the earliest row_id wins, matching the original rule.
DROP TEMPORARY TABLE IF EXISTS tmp_claim_best_row;
CREATE TEMPORARY TABLE tmp_claim_best_row AS
SELECT s.claim_id, MIN(s.row_id) AS row_id
FROM tmp_claims_scored s
JOIN tmp_claim_best_score k
  ON k.claim_id = s.claim_id
 AND k.validity_score = s.validity_score
GROUP BY s.claim_id;

ALTER TABLE tmp_claim_best_row
    ADD PRIMARY KEY (claim_id);

-- Recover the complete winning row.
DROP TEMPORARY TABLE IF EXISTS tmp_claims_best;
CREATE TEMPORARY TABLE tmp_claims_best AS
SELECT s.*
FROM tmp_claims_scored s
JOIN tmp_claim_best_row k
  ON k.claim_id = s.claim_id
 AND k.row_id = s.row_id;


-- ============================================================
-- SECTION 5: pick the latest adjustment per original claim
-- Decision D15: an adjustment record supersedes its original's
-- paid_amount. Profiling (7.2) confirmed every adjustment names a
-- real original, with 100% referential integrity. Where more than
-- one adjustment row exists for the same original (from the
-- duplicate-injection step catching an adjustment row too, F12),
-- the most recently loaded one wins.
-- ============================================================
-- Adjustment population is much smaller, so retain ROW_NUMBER() here.
DROP TEMPORARY TABLE IF EXISTS tmp_adjustments_best;
CREATE TEMPORARY TABLE tmp_adjustments_best AS
SELECT original_claim_id, adjustment_claim_id, adj_paid_amount
FROM (
    SELECT
        a.original_claim_id,
        a.claim_id AS adjustment_claim_id,
        CAST(NULLIF(TRIM(a.paid_amount), '') AS DECIMAL(14,2)) AS adj_paid_amount,
        ROW_NUMBER() OVER (
            PARTITION BY a.original_claim_id
            ORDER BY
                CASE
                    WHEN a.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$'
                        THEN STR_TO_DATE(a.load_timestamp, '%Y-%m-%d %H:%i:%s')
                    WHEN a.load_timestamp REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
                        THEN STR_TO_DATE(a.load_timestamp, '%Y-%m-%d')
                END DESC,
                a.row_id DESC
        ) AS rn
    FROM staging_claims_raw a
    WHERE a.adjustment_flag = '1'
) y
WHERE rn = 1;


-- ============================================================
-- SECTION 6: fact_claim
-- Grain: one row per real, deduplicated claim, showing its current
-- (post-adjustment) state. The pre-adjustment amount is preserved
-- in original_paid_amount for audit, per D15.
--
-- Columns deliberately NOT included, and why:
--   region, patient_sex          -> stable per member (8.2/8.3),
--                                    now live only in dim_member
--   provider_type/specialty/
--   network_status                -> stable per provider (8.1),
--                                    now live only in dim_provider
--   place_of_service              -> D13: proven redundant with
--                                    claim_type (100% 1:1, F10)
--   chronic_flag_*                -> moved to dim_member
-- patient_age stays here: it is the patient's age AT THIS CLAIM,
-- which genuinely changes claim to claim, unlike the dimension
-- attributes above.
-- ============================================================
CREATE TABLE fact_claim (
    claim_sk                       INT AUTO_INCREMENT PRIMARY KEY,
    claim_id                        VARCHAR(20) NOT NULL,
    member_sk                        INT NOT NULL,
    provider_sk                       INT NOT NULL,
    service_date                       DATE NOT NULL,
    claim_submission_date               DATE NOT NULL,
    paid_date                            DATE NULL,
    claim_type                            VARCHAR(30),
    diagnosis_code_1                       VARCHAR(20),
    diagnosis_code_2                        VARCHAR(20) NULL,
    procedure_code                           VARCHAR(20) NULL,
    procedure_code_missing                    TINYINT(1) NOT NULL DEFAULT 0,
    revenue_code                               VARCHAR(20) NULL,
    length_of_stay                              DECIMAL(6,1) NULL,
    billed_amount                                DECIMAL(14,2),
    allowed_amount                                DECIMAL(14,2),
    paid_amount                                    DECIMAL(14,2) NULL,
    original_paid_amount                            DECIMAL(14,2) NULL,
    paid_amount_capped                               TINYINT(1) NOT NULL DEFAULT 0,
    patient_responsibility_amount                     DECIMAL(14,2),
    claim_status                                       VARCHAR(10),
    denial_reason_code                                  VARCHAR(30) NULL,
    patient_age                                          DECIMAL(6,1) NULL,
    age_invalid                                           TINYINT(1) NOT NULL DEFAULT 0,
    has_adjustment                                         TINYINT(1) NOT NULL DEFAULT 0,
    adjustment_claim_id                                     VARCHAR(20) NULL,
    unmatched_member                                         TINYINT(1) NOT NULL DEFAULT 0,
    outside_enrollment                                        TINYINT(1) NOT NULL DEFAULT 0,
    record_source                                              VARCHAR(30),
    load_timestamp                                              DATETIME NULL,
    load_timestamp_malformed                                     TINYINT(1) NOT NULL DEFAULT 0,
    _core_built_at                                                TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_member_sk (member_sk),
    INDEX idx_provider_sk (provider_sk),
    INDEX idx_service_date (service_date),
    INDEX idx_claim_id (claim_id),
    CONSTRAINT fk_fact_member   FOREIGN KEY (member_sk)   REFERENCES dim_member(member_sk),
    CONSTRAINT fk_fact_provider FOREIGN KEY (provider_sk) REFERENCES dim_provider(provider_sk),
    CONSTRAINT fk_fact_calendar FOREIGN KEY (service_date) REFERENCES dim_calendar(calendar_date)
);

INSERT INTO fact_claim (
    claim_id, member_sk, provider_sk, service_date, claim_submission_date, paid_date,
    claim_type, diagnosis_code_1, diagnosis_code_2, procedure_code, procedure_code_missing,
    revenue_code, length_of_stay, billed_amount, allowed_amount, paid_amount, original_paid_amount,
    paid_amount_capped, patient_responsibility_amount, claim_status, denial_reason_code,
    patient_age, age_invalid, has_adjustment, adjustment_claim_id, unmatched_member,
    outside_enrollment, record_source, load_timestamp, load_timestamp_malformed
)
SELECT
    b.claim_id,
    COALESCE(dm.member_sk, unk.member_sk),
    dp.provider_sk,
    b.service_date,
    b.claim_submission_date,
    b.paid_date,
    b.claim_type,
    b.diagnosis_code_1,
    b.diagnosis_code_2,
    b.procedure_code,
    (b.procedure_code IS NULL),
    b.revenue_code,
    CAST(b.length_of_stay_raw AS DECIMAL(6,1)),
    b.billed_amount,
    b.allowed_amount,
    -- D10: apply the adjustment if one exists, then cap at allowed_amount
    LEAST(COALESCE(adj.adj_paid_amount, b.paid_amount_raw), b.allowed_amount),
    b.paid_amount_raw,
    COALESCE((COALESCE(adj.adj_paid_amount, b.paid_amount_raw) > b.allowed_amount), 0),
    b.patient_responsibility_amount,
    b.claim_status,
    b.denial_reason_code,
    b.patient_age,
    b.age_invalid,
    (adj.adjustment_claim_id IS NOT NULL),
    adj.adjustment_claim_id,
    -- D5: unmatched_member = this member_id doesn't exist in membership at all
    (dm.member_sk IS NULL),
    -- D6: outside_enrollment = no membership row for this member in this month
    -- (also 1 whenever unmatched_member is 1, since no membership row can exist either)
    CASE
        WHEN dm.member_sk IS NULL THEN 1
        WHEN NOT EXISTS (
            SELECT 1 FROM staging_membership_raw ms
            WHERE ms.member_id = b.member_id
              AND ms.month_year = LEFT(b.service_date, 7)
        ) THEN 1
        ELSE 0
    END,
    b.record_source,
    b.load_timestamp_parsed,
    b.load_timestamp_malformed
FROM tmp_claims_best b
LEFT JOIN dim_member   dm  ON dm.member_id = b.member_id
LEFT JOIN dim_provider dp  ON dp.provider_id = b.provider_id
LEFT JOIN tmp_adjustments_best adj ON adj.original_claim_id = b.claim_id
CROSS JOIN (SELECT member_sk FROM dim_member WHERE member_id = 'UNKNOWN') unk;


-- ============================================================
-- SECTION 7: RECONCILIATION
-- Proof that nothing was silently lost or duplicated. Dollar totals
-- are NOT expected to match staging exactly -- dedup, adjustments
-- and capping all deliberately change the total. Row-count logic is
-- what must tie out.
-- ============================================================

-- 7.1 Every distinct original claim_id survived exactly once
SELECT
    (SELECT COUNT(DISTINCT claim_id) FROM staging_claims_raw WHERE adjustment_flag = '0') AS distinct_original_claim_ids,
    (SELECT COUNT(*) FROM fact_claim) AS fact_claim_rows,
    (SELECT COUNT(DISTINCT claim_id) FROM fact_claim) AS distinct_claim_ids_in_fact;
-- Expect all three numbers equal.

-- 7.2 Every real member is accounted for (Unknown row excluded from the count)
SELECT
    (SELECT COUNT(DISTINCT member_id) FROM staging_membership_raw) AS distinct_members_in_membership,
    (SELECT COUNT(*) - 1 FROM dim_member) AS real_members_in_dim_member; -- minus 1 for the UNKNOWN row
-- Expect these two counts equal.

-- 7.3 Every provider survived
SELECT
    (SELECT COUNT(DISTINCT provider_id) FROM staging_claims_raw) AS distinct_providers_in_staging,
    (SELECT COUNT(*) FROM dim_provider) AS providers_in_dim_provider;
-- Expect these equal.

-- 7.4 Flag rates: should be close to the profiling findings, not identical
-- (dedup changes which specific rows survive)
SELECT
    SUM(unmatched_member)      AS unmatched_member_rows,
    ROUND(100*AVG(unmatched_member),2)   AS pct_unmatched_member,
    SUM(outside_enrollment)    AS outside_enrollment_rows,
    ROUND(100*AVG(outside_enrollment),2) AS pct_outside_enrollment,
    SUM(has_adjustment)        AS rows_with_adjustment_applied,
    SUM(paid_amount_capped)    AS rows_capped_at_allowed,
    SUM(age_invalid)           AS rows_with_invalid_age,
    SUM(procedure_code_missing) AS rows_missing_procedure_code
FROM fact_claim;

-- 7.5 Dollar totals, for context only (not a pass/fail check)
SELECT
    (SELECT ROUND(SUM(CAST(NULLIF(TRIM(paid_amount),'') AS DECIMAL(14,2))),0)
     FROM staging_claims_raw WHERE adjustment_flag='0') AS staging_originals_total_paid,
    (SELECT ROUND(SUM(paid_amount),0) FROM fact_claim) AS fact_claim_total_paid;

-- 7.6 Sample the fact table
SELECT * FROM fact_claim LIMIT 10;
