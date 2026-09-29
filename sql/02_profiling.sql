-- ============================================================
-- 02_profiling.sql
-- PROFILING: read-only questions asked of the staging tables.
--
-- Nothing here changes data. The only writes are optional indexes (Section 0).
--
-- HOW TO RUN: highlight ONE numbered query at a time and click the
-- lightning bolt. Paste (or screenshot) each result back so we can
-- fill in the findings log together.
--
-- READ THESE THREE NOTES FIRST
-- 1. Blanks in staging are EMPTY STRINGS (''), not NULL. Every
--    completeness test therefore checks NULLIF(TRIM(col),'') IS NULL.
-- 2. MySQL's default collation is case-INsensitive, so GROUP BY would
--    merge 'Paid', 'paid' and 'PAID' into one row and hide the mess.
--    Where we care about raw spelling we add  COLLATE utf8mb4_bin
--    (binary = case-sensitive) so every variant shows up separately.
-- 3. Numbers here are RAW: duplicates, adjustments and bad rows are
--    all still counted. That is the point. Cleaning comes later.
--
-- Numeric test used throughout:  col REGEXP '^-?[0-9]+([.][0-9]+)?$'
-- ============================================================

USE claims_forecasting;


-- ============================================================
-- SECTION 0. Performance indexes (run ONCE)
-- Indexes speed up joins and lookups; they do not change any data.
-- If you rerun and get error 1061 "Duplicate key name", they already
-- exist: skip this section. If you rerun 01_staging.sql (which drops
-- the tables), run this section again.
-- ============================================================
ALTER TABLE staging_claims_raw
    ADD INDEX idx_claim_id (claim_id),
    ADD INDEX idx_member_id (member_id);

ALTER TABLE staging_membership_raw
    ADD INDEX idx_member_month (member_id, month_year);


-- ============================================================
-- SECTION 1. VOLUME AND SHAPE
-- Question: does what we loaded match what we expect?
-- ============================================================

-- 1.1 Claims: size, distinct keys, date range
SELECT COUNT(*)                          AS total_rows,
       COUNT(DISTINCT claim_id)          AS distinct_claim_ids,
       COUNT(DISTINCT member_id)         AS distinct_members,
       COUNT(DISTINCT provider_id)       AS distinct_providers,
       MIN(NULLIF(service_date, ''))     AS first_service_date,
       MAX(NULLIF(service_date, ''))     AS last_service_date
FROM staging_claims_raw;

-- 1.2 Membership: size, distinct members and months
SELECT COUNT(*)                          AS total_rows,
       COUNT(DISTINCT member_id)         AS distinct_members,
       COUNT(DISTINCT month_year)        AS distinct_months,
       MIN(NULLIF(month_year, ''))       AS first_month,
       MAX(NULLIF(month_year, ''))       AS last_month
FROM staging_membership_raw;


-- ============================================================
-- SECTION 2. GRAIN AND KEYS
-- Question: what actually identifies one row? Can claim_id be a key?
-- ============================================================

-- 2.1 How many times does each claim_id appear?
-- (copies = 1 means unique; copies >= 2 means duplicated)
SELECT copies, COUNT(*) AS n_claim_ids
FROM (
    SELECT claim_id, COUNT(*) AS copies
    FROM staging_claims_raw
    GROUP BY claim_id
) t
GROUP BY copies
ORDER BY copies;

-- 2.2 For duplicated claim_ids: are the copies identical, or do they differ?
-- Each "differ_" column = number of duplicate groups where that column
-- has more than one distinct value inside the group.
SELECT COUNT(*)                     AS duplicate_groups,
       SUM(d_member  > 1)           AS differ_member_id,
       SUM(d_proc    > 1)           AS differ_procedure_code,
       SUM(d_age     > 1)           AS differ_patient_age,
       SUM(d_paid    > 1)           AS differ_paid_amount,
       SUM(d_status  > 1)           AS differ_claim_status,
       SUM(d_region  > 1)           AS differ_region,
       SUM(d_load    > 1)           AS differ_load_timestamp
FROM (
    SELECT c.claim_id,
           COUNT(DISTINCT c.member_id       COLLATE utf8mb4_bin) AS d_member,
           COUNT(DISTINCT c.procedure_code  COLLATE utf8mb4_bin) AS d_proc,
           COUNT(DISTINCT c.patient_age     COLLATE utf8mb4_bin) AS d_age,
           COUNT(DISTINCT c.paid_amount     COLLATE utf8mb4_bin) AS d_paid,
           COUNT(DISTINCT c.claim_status    COLLATE utf8mb4_bin) AS d_status,
           COUNT(DISTINCT c.region          COLLATE utf8mb4_bin) AS d_region,
           COUNT(DISTINCT c.load_timestamp  COLLATE utf8mb4_bin) AS d_load
    FROM staging_claims_raw c
    JOIN (
        SELECT claim_id
        FROM staging_claims_raw
        GROUP BY claim_id
        HAVING COUNT(*) > 1
    ) d ON d.claim_id = c.claim_id
    GROUP BY c.claim_id
) t;
-- 2.3 Membership grain: is (member_id, month_year) unique?
SELECT copies, COUNT(*) AS n_member_months
FROM (
    SELECT member_id, month_year, COUNT(*) AS copies
    FROM staging_membership_raw
    GROUP BY member_id, month_year
) t
GROUP BY copies
ORDER BY copies;

-- 2.4 Membership gaps: for each member, months missing between their
-- first and last month. gaps = 0 means continuous coverage.
SELECT gaps, COUNT(*) AS n_members
FROM (
    SELECT member_id,
           (MAX(mi) - MIN(mi) + 1) - COUNT(DISTINCT mi) AS gaps
    FROM (
        SELECT member_id,
               CAST(SUBSTR(month_year, 1, 4) AS UNSIGNED) * 12
             + CAST(SUBSTR(month_year, 6, 2) AS UNSIGNED) AS mi
        FROM staging_membership_raw
    ) m
    GROUP BY member_id
) g
GROUP BY gaps
ORDER BY gaps;


-- ============================================================
-- SECTION 3. REFERENTIAL INTEGRITY
-- Question: do the two files agree about who the members are?
-- ============================================================

-- 3.1 Orphan claims: member_id not present in membership at all
SELECT COUNT(*)                      AS orphan_claim_rows,
       COUNT(DISTINCT c.member_id)   AS orphan_member_ids,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM staging_claims_raw), 2) AS pct_of_claim_rows
FROM staging_claims_raw c
WHERE NOT EXISTS (
    SELECT 1 FROM staging_membership_raw m WHERE m.member_id = c.member_id
);

-- 3.2 Members with no claims at all (normal for some members)
SELECT COUNT(DISTINCT m.member_id) AS members_without_claims,
       (SELECT COUNT(DISTINCT member_id) FROM staging_membership_raw) AS total_members
FROM staging_membership_raw m
WHERE NOT EXISTS (
    SELECT 1 FROM staging_claims_raw c WHERE c.member_id = m.member_id
);

-- 3.3 Claims for a known member in a month they were NOT enrolled.
-- HEADS-UP: I built the generator, and it did not tie claims to
-- enrollment windows, so expect this number to be large. We will decide
-- together whether that is a data-quality rule or a generator fix.
SELECT COUNT(*) AS claim_rows_outside_enrollment,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM staging_claims_raw), 2) AS pct_of_claim_rows
FROM staging_claims_raw c
WHERE EXISTS (
        SELECT 1 FROM staging_membership_raw m0 WHERE m0.member_id = c.member_id
      )
  AND NOT EXISTS (
        SELECT 1 FROM staging_membership_raw m
        WHERE m.member_id = c.member_id
          AND m.month_year = SUBSTR(c.service_date, 1, 7)
      );


-- ============================================================
-- SECTION 4. COMPLETENESS
-- Question: which fields are missing, and is the blank expected?
-- ============================================================

-- 4.1 Blank count per claims column (one row; tip: in the result grid use
-- the "Form Editor" view to read it top-to-bottom instead of sideways)
SELECT
    SUM(NULLIF(TRIM(claim_id), '') IS NULL)                      AS blank_claim_id,
    SUM(NULLIF(TRIM(member_id), '') IS NULL)                     AS blank_member_id,
    SUM(NULLIF(TRIM(provider_id), '') IS NULL)                   AS blank_provider_id,
    SUM(NULLIF(TRIM(provider_npi), '') IS NULL)                  AS blank_provider_npi,
    SUM(NULLIF(TRIM(service_date), '') IS NULL)                  AS blank_service_date,
    SUM(NULLIF(TRIM(claim_submission_date), '') IS NULL)         AS blank_submission_date,
    SUM(NULLIF(TRIM(paid_date), '') IS NULL)                     AS blank_paid_date,
    SUM(NULLIF(TRIM(diagnosis_code_1), '') IS NULL)              AS blank_diagnosis_code_1,
    SUM(NULLIF(TRIM(diagnosis_code_2), '') IS NULL)              AS blank_diagnosis_code_2,
    SUM(NULLIF(TRIM(procedure_code), '') IS NULL)                AS blank_procedure_code,
    SUM(NULLIF(TRIM(revenue_code), '') IS NULL)                  AS blank_revenue_code,
    SUM(NULLIF(TRIM(claim_type), '') IS NULL)                    AS blank_claim_type,
    SUM(NULLIF(TRIM(place_of_service), '') IS NULL)              AS blank_place_of_service,
    SUM(NULLIF(TRIM(length_of_stay), '') IS NULL)                AS blank_length_of_stay,
    SUM(NULLIF(TRIM(billed_amount), '') IS NULL)                 AS blank_billed_amount,
    SUM(NULLIF(TRIM(allowed_amount), '') IS NULL)                AS blank_allowed_amount,
    SUM(NULLIF(TRIM(paid_amount), '') IS NULL)                   AS blank_paid_amount,
    SUM(NULLIF(TRIM(patient_responsibility_amount), '') IS NULL) AS blank_patient_resp,
    SUM(NULLIF(TRIM(claim_status), '') IS NULL)                  AS blank_claim_status,
    SUM(NULLIF(TRIM(denial_reason_code), '') IS NULL)            AS blank_denial_reason,
    SUM(NULLIF(TRIM(provider_type), '') IS NULL)                 AS blank_provider_type,
    SUM(NULLIF(TRIM(provider_specialty), '') IS NULL)            AS blank_provider_specialty,
    SUM(NULLIF(TRIM(network_status), '') IS NULL)                AS blank_network_status,
    SUM(NULLIF(TRIM(patient_age), '') IS NULL)                   AS blank_patient_age,
    SUM(NULLIF(TRIM(patient_sex), '') IS NULL)                   AS blank_patient_sex,
    SUM(NULLIF(TRIM(region), '') IS NULL)                        AS blank_region,
    SUM(NULLIF(TRIM(chronic_flag_diabetes), '') IS NULL)         AS blank_flag_diabetes,
    SUM(NULLIF(TRIM(chronic_flag_chf), '') IS NULL)              AS blank_flag_chf,
    SUM(NULLIF(TRIM(chronic_flag_cancer), '') IS NULL)           AS blank_flag_cancer,
    SUM(NULLIF(TRIM(chronic_flag_copd), '') IS NULL)             AS blank_flag_copd,
    SUM(NULLIF(TRIM(chronic_flag_esrd), '') IS NULL)             AS blank_flag_esrd,
    SUM(NULLIF(TRIM(adjustment_flag), '') IS NULL)               AS blank_adjustment_flag,
    SUM(NULLIF(TRIM(original_claim_id), '') IS NULL)             AS blank_original_claim_id,
    SUM(NULLIF(TRIM(record_source), '') IS NULL)                 AS blank_record_source,
    SUM(NULLIF(TRIM(load_timestamp), '') IS NULL)                AS blank_load_timestamp
FROM staging_claims_raw;

-- 4.2 "Not applicable" blanks vs "missing" blanks, by claim type.
-- A blank length_of_stay on a Pharmacy claim is expected (not applicable).
-- A blank procedure_code on any claim is a real gap.
SELECT claim_type,
       COUNT(*)                                              AS n_rows,
       SUM(NULLIF(TRIM(length_of_stay), '') IS NOT NULL)     AS has_length_of_stay,
       SUM(NULLIF(TRIM(revenue_code), '') IS NOT NULL)       AS has_revenue_code,
       SUM(NULLIF(TRIM(diagnosis_code_1), '') IS NULL)       AS missing_diagnosis_1,
       SUM(NULLIF(TRIM(diagnosis_code_2), '') IS NOT NULL)   AS has_diagnosis_2,
       SUM(NULLIF(TRIM(procedure_code), '') IS NULL)         AS missing_procedure_code
FROM staging_claims_raw
GROUP BY claim_type
ORDER BY n_rows DESC;

-- 4.3 Blank count per membership column
SELECT
    SUM(NULLIF(TRIM(member_id), '') IS NULL)          AS blank_member_id,
    SUM(NULLIF(TRIM(month_year), '') IS NULL)         AS blank_month_year,
    SUM(NULLIF(TRIM(plan_type), '') IS NULL)          AS blank_plan_type,
    SUM(NULLIF(TRIM(region), '') IS NULL)             AS blank_region,
    SUM(NULLIF(TRIM(enrollment_status), '') IS NULL)  AS blank_enrollment_status,
    SUM(NULLIF(TRIM(birth_date), '') IS NULL)         AS blank_birth_date,
    SUM(NULLIF(TRIM(sex), '') IS NULL)                AS blank_sex
FROM staging_membership_raw;


-- ============================================================
-- SECTION 5. VALIDITY
-- Question: are the values that ARE present possible?
-- ============================================================

-- 5.1 Patient age: non-numeric, negative, or implausibly high
SELECT COUNT(*) AS total_rows,
       SUM(patient_age NOT REGEXP '^-?[0-9]+([.][0-9]+)?$')  AS non_numeric_age,
       SUM(patient_age REGEXP '^-?[0-9]+([.][0-9]+)?$'
           AND CAST(patient_age AS DECIMAL(8,1)) < 0)        AS negative_age,
       SUM(patient_age REGEXP '^-?[0-9]+([.][0-9]+)?$'
           AND CAST(patient_age AS DECIMAL(8,1)) > 120)      AS age_over_120,
       MIN(CASE WHEN patient_age REGEXP '^[0-9]+([.][0-9]+)?$'
                THEN CAST(patient_age AS DECIMAL(8,1)) END)  AS min_plausible_age,
       MAX(CASE WHEN patient_age REGEXP '^[0-9]+([.][0-9]+)?$'
                     AND CAST(patient_age AS DECIMAL(8,1)) <= 120
                THEN CAST(patient_age AS DECIMAL(8,1)) END)  AS max_plausible_age
FROM staging_claims_raw;

-- 5.2 Money fields: non-numeric, negative, and impossible relationships
-- (paid should not exceed allowed, and allowed should not exceed billed)
SELECT
    SUM(paid_amount    <> '' AND paid_amount    NOT REGEXP '^-?[0-9]+([.][0-9]+)?$') AS paid_non_numeric,
    SUM(billed_amount  <> '' AND billed_amount  NOT REGEXP '^-?[0-9]+([.][0-9]+)?$') AS billed_non_numeric,
    SUM(paid_amount    REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND CAST(paid_amount AS DECIMAL(14,2)) < 0)                                  AS paid_negative,
    SUM(paid_amount    REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND billed_amount REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND CAST(paid_amount AS DECIMAL(14,2)) > CAST(billed_amount AS DECIMAL(14,2)))  AS paid_gt_billed,
    SUM(paid_amount    REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND allowed_amount REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND CAST(paid_amount AS DECIMAL(14,2)) > CAST(allowed_amount AS DECIMAL(14,2))) AS paid_gt_allowed,
    SUM(allowed_amount REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND billed_amount REGEXP '^-?[0-9]+([.][0-9]+)?$'
        AND CAST(allowed_amount AS DECIMAL(14,2)) > CAST(billed_amount AS DECIMAL(14,2))) AS allowed_gt_billed
FROM staging_claims_raw;

-- 5.3 Dates: format problems and impossible ordering
-- Dates are ISO text (YYYY-MM-DD), so plain text comparison orders them correctly.
SELECT
    SUM(service_date          NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')               AS service_date_bad_format,
    SUM(claim_submission_date NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')               AS submission_date_bad_format,
    SUM(paid_date <> '' AND paid_date NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')       AS paid_date_bad_format,
    SUM(claim_submission_date < service_date)                                          AS submitted_before_service,
    SUM(paid_date <> '' AND paid_date < claim_submission_date)                         AS paid_before_submission,
    SUM(paid_date <> '' AND paid_date < service_date)                                  AS paid_before_service
FROM staging_claims_raw;

-- 5.4 load_timestamp: well-formed vs malformed, and every malformed value
SELECT SUM(load_timestamp REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') AS well_formed,
       SUM(load_timestamp NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') AS malformed
FROM staging_claims_raw;

SELECT load_timestamp COLLATE utf8mb4_bin AS malformed_value, COUNT(*) AS n_rows
FROM staging_claims_raw
WHERE load_timestamp NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
GROUP BY load_timestamp COLLATE utf8mb4_bin
ORDER BY n_rows DESC;

-- 5.5 Does a record claim to be loaded BEFORE the claim was paid?
-- (impossible in a real feed; would be an artifact of how the data was built)
SELECT COUNT(*) AS loaded_before_paid
FROM staging_claims_raw
WHERE load_timestamp REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
  AND paid_date <> ''
  AND LEFT(load_timestamp, 10) < paid_date;

-- 5.6 Flag columns should only contain 0 or 1
SELECT
    SUM(chronic_flag_diabetes NOT IN ('0','1')) AS bad_diabetes,
    SUM(chronic_flag_chf      NOT IN ('0','1')) AS bad_chf,
    SUM(chronic_flag_cancer   NOT IN ('0','1')) AS bad_cancer,
    SUM(chronic_flag_copd     NOT IN ('0','1')) AS bad_copd,
    SUM(chronic_flag_esrd     NOT IN ('0','1')) AS bad_esrd,
    SUM(adjustment_flag       NOT IN ('0','1')) AS bad_adjustment_flag
FROM staging_claims_raw;


-- ============================================================
-- SECTION 6. CONSISTENCY
-- Question: is the same thing always spelled the same way?
-- COLLATE utf8mb4_bin makes every raw spelling show as its own row.
-- ============================================================

-- 6.1 Every distinct raw value of the low-cardinality claims columns
SELECT 'claim_status' AS column_name, claim_status COLLATE utf8mb4_bin AS raw_value, COUNT(*) AS n_rows
FROM staging_claims_raw GROUP BY claim_status COLLATE utf8mb4_bin
UNION ALL
SELECT 'region', region COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY region COLLATE utf8mb4_bin
UNION ALL
SELECT 'claim_type', claim_type COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY claim_type COLLATE utf8mb4_bin
UNION ALL
SELECT 'network_status', network_status COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY network_status COLLATE utf8mb4_bin
UNION ALL
SELECT 'provider_type', provider_type COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY provider_type COLLATE utf8mb4_bin
UNION ALL
SELECT 'patient_sex', patient_sex COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY patient_sex COLLATE utf8mb4_bin
UNION ALL
SELECT 'record_source', record_source COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY record_source COLLATE utf8mb4_bin
UNION ALL
SELECT 'denial_reason_code', denial_reason_code COLLATE utf8mb4_bin, COUNT(*)
FROM staging_claims_raw GROUP BY denial_reason_code COLLATE utf8mb4_bin
ORDER BY 1, 3 DESC;

-- 6.2 Is place_of_service just a relabelling of claim_type?
-- (if each claim_type maps to exactly one place_of_service, the column
--  carries no new information)
SELECT claim_type, place_of_service, COUNT(*) AS n_rows
FROM staging_claims_raw
GROUP BY claim_type, place_of_service
ORDER BY claim_type, n_rows DESC;

-- 6.3 Does claim status agree with the payment fields?
-- Expectation: PAID has a paid date and an amount; DENIED has a reason and
-- zero paid; PENDING has no paid date and no amount.
SELECT CASE WHEN LOWER(claim_status) IN ('paid', 'pd') THEN 'PAID'
            WHEN LOWER(claim_status) = 'denied'        THEN 'DENIED'
            WHEN LOWER(claim_status) = 'pending'       THEN 'PENDING'
            ELSE 'OTHER' END                                              AS status_normalized,
       COUNT(*)                                                           AS n_rows,
       SUM(paid_date = '')                                                AS no_paid_date,
       SUM(paid_amount = '')                                              AS paid_amount_blank,
       SUM(paid_amount REGEXP '^-?[0-9]+([.][0-9]+)?$'
           AND CAST(paid_amount AS DECIMAL(14,2)) = 0)                    AS paid_amount_zero,
       SUM(denial_reason_code <> '')                                      AS has_denial_reason
FROM staging_claims_raw
GROUP BY status_normalized
ORDER BY n_rows DESC;

-- 6.4 Membership: distinct raw values of its low-cardinality columns
SELECT 'plan_type' AS column_name, plan_type COLLATE utf8mb4_bin AS raw_value, COUNT(*) AS n_rows
FROM staging_membership_raw GROUP BY plan_type COLLATE utf8mb4_bin
UNION ALL
SELECT 'region', region COLLATE utf8mb4_bin, COUNT(*)
FROM staging_membership_raw GROUP BY region COLLATE utf8mb4_bin
UNION ALL
SELECT 'enrollment_status', enrollment_status COLLATE utf8mb4_bin, COUNT(*)
FROM staging_membership_raw GROUP BY enrollment_status COLLATE utf8mb4_bin
UNION ALL
SELECT 'sex', sex COLLATE utf8mb4_bin, COUNT(*)
FROM staging_membership_raw GROUP BY sex COLLATE utf8mb4_bin
ORDER BY 1, 3 DESC;


-- ============================================================
-- SECTION 7. ADJUSTMENTS AND DUPLICATES
-- Question: how do corrections relate to the claims they correct?
-- ============================================================

-- 7.1 Claim id prefix vs adjustment flag
SELECT LEFT(claim_id, 1)  AS id_prefix,
       adjustment_flag,
       COUNT(*)           AS n_rows,
       SUM(NULLIF(TRIM(original_claim_id), '') IS NOT NULL) AS has_original_claim_id
FROM staging_claims_raw
GROUP BY LEFT(claim_id, 1), adjustment_flag;

-- 7.2 Do adjustment rows point at a claim that exists in the file?
SELECT COUNT(*)                            AS adjustment_rows,
       COUNT(DISTINCT a.original_claim_id) AS distinct_originals_adjusted,
       SUM(EXISTS (SELECT 1 FROM staging_claims_raw o
                   WHERE o.claim_id = a.original_claim_id)) AS original_found_in_file
FROM staging_claims_raw a
WHERE a.adjustment_flag = '1';

-- 7.3 What status do adjustment rows carry?
SELECT LOWER(claim_status) AS status_lower, COUNT(*) AS n_rows
FROM staging_claims_raw
WHERE adjustment_flag = '1'
GROUP BY LOWER(claim_status)
ORDER BY n_rows DESC;


-- ============================================================
-- SECTION 8. DIMENSION CANDIDATES (the main ER-design evidence)
-- Rule of thumb: if an attribute never varies for the same entity,
-- it describes that entity and belongs in its dimension table.
-- ============================================================

-- 8.1 Providers: is each provider_id always the same type, specialty,
-- network status and NPI?
SELECT COUNT(*)                AS providers,
       SUM(n_type > 1)         AS providers_with_varying_type,
       SUM(n_specialty > 1)    AS providers_with_varying_specialty,
       SUM(n_network > 1)      AS providers_with_varying_network,
       SUM(n_npi > 1)          AS providers_with_varying_npi
FROM (
    SELECT provider_id,
           COUNT(DISTINCT provider_type      COLLATE utf8mb4_bin) AS n_type,
           COUNT(DISTINCT provider_specialty COLLATE utf8mb4_bin) AS n_specialty,
           COUNT(DISTINCT network_status     COLLATE utf8mb4_bin) AS n_network,
           COUNT(DISTINCT provider_npi)                           AS n_npi
    FROM staging_claims_raw
    GROUP BY provider_id
) t;

-- 8.2 Members as seen in the CLAIMS file: sex, chronic flags and region constant?
-- (region is compared by its first letter after trimming, which collapses
--  NE / North East / northeast into one key)
SELECT COUNT(*) AS members_with_claims,
       SUM(d_sex > 1) AS members_with_varying_sex,
       SUM(d_diab > 1 OR d_chf > 1 OR d_cancer > 1 OR d_copd > 1 OR d_esrd > 1) AS members_with_varying_chronic_flags,
       SUM(d_region > 1) AS members_with_varying_region
FROM (
    SELECT member_id,
           COUNT(DISTINCT patient_sex)                           AS d_sex,
           COUNT(DISTINCT chronic_flag_diabetes)                 AS d_diab,
           COUNT(DISTINCT chronic_flag_chf)                      AS d_chf,
           COUNT(DISTINCT chronic_flag_cancer)                   AS d_cancer,
           COUNT(DISTINCT chronic_flag_copd)                     AS d_copd,
           COUNT(DISTINCT chronic_flag_esrd)                     AS d_esrd,
           COUNT(DISTINCT UPPER(LEFT(TRIM(region), 1)))          AS d_region
    FROM staging_claims_raw
    GROUP BY member_id
) t;

-- 8.3 Members as seen in the MEMBERSHIP file: plan, birth date, sex, region constant?
SELECT COUNT(*) AS members,
       SUM(d_plan   > 1) AS members_with_varying_plan,
       SUM(d_birth  > 1) AS members_with_varying_birth_date,
       SUM(d_sex    > 1) AS members_with_varying_sex,
       SUM(d_region > 1) AS members_with_varying_region
FROM (
    SELECT member_id,
           COUNT(DISTINCT plan_type)                      AS d_plan,
           COUNT(DISTINCT birth_date)                     AS d_birth,
           COUNT(DISTINCT sex)                            AS d_sex,
           COUNT(DISTINCT UPPER(LEFT(TRIM(region), 1)))   AS d_region
    FROM staging_membership_raw
    GROUP BY member_id
) t;


-- ============================================================
-- SECTION 9. BUSINESS SHAPE
-- Question: did the skew, concentration, seasonality and lag we
-- designed survive the load? (RAW numbers: duplicates and errors included)
-- ============================================================

-- 9.1 Claim-type mix: share of rows vs share of paid dollars (paid claims only)
SELECT claim_type,
       COUNT(*) AS n_rows,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_rows,
       ROUND(SUM(CAST(paid_amount AS DECIMAL(14,2))), 0) AS total_paid,
       ROUND(100 * SUM(CAST(paid_amount AS DECIMAL(14,2)))
             / SUM(SUM(CAST(paid_amount AS DECIMAL(14,2)))) OVER (), 1) AS pct_of_dollars
FROM staging_claims_raw
WHERE LOWER(claim_status) IN ('paid', 'pd')
  AND paid_amount REGEXP '^[0-9]+([.][0-9]+)?$'
GROUP BY claim_type
ORDER BY total_paid DESC;

-- 9.2 Monthly volume and paid dollars (by service month): trend and seasonality
SELECT SUBSTR(service_date, 1, 7) AS service_month,
       COUNT(*)                   AS n_rows,
       ROUND(SUM(CASE WHEN LOWER(claim_status) IN ('paid', 'pd')
                       AND paid_amount REGEXP '^[0-9]+([.][0-9]+)?$'
                      THEN CAST(paid_amount AS DECIMAL(14,2)) END), 0) AS total_paid
FROM staging_claims_raw
GROUP BY SUBSTR(service_date, 1, 7)
ORDER BY service_month;

-- 9.3 Skew and dollar concentration of paid amounts
WITH paid AS (
    SELECT CAST(paid_amount AS DECIMAL(14,2)) AS amt
    FROM staging_claims_raw
    WHERE LOWER(claim_status) IN ('paid', 'pd')
      AND paid_amount REGEXP '^[0-9]+([.][0-9]+)?$'
),
ranked AS (
    SELECT amt, NTILE(100) OVER (ORDER BY amt) AS pctile
    FROM paid
)
SELECT COUNT(*)                                                        AS n_paid_rows,
       ROUND(AVG(amt), 0)                                              AS mean_paid,
       MAX(CASE WHEN pctile = 50 THEN amt END)                         AS approx_median,
       MAX(CASE WHEN pctile = 99 THEN amt END)                         AS approx_p99,
       MAX(amt)                                                        AS max_paid,
       ROUND(100 * SUM(CASE WHEN pctile = 100 THEN amt ELSE 0 END) / SUM(amt), 1) AS top_1pct_share_of_dollars,
       ROUND(100 * SUM(CASE WHEN pctile > 90  THEN amt ELSE 0 END) / SUM(amt), 1) AS top_10pct_share_of_dollars
FROM ranked;

-- 9.4 Claim lag by type: days from service to submission, and to payment
SELECT claim_type,
       COUNT(*) AS n_rows,
       ROUND(AVG(DATEDIFF(claim_submission_date, service_date)), 1) AS avg_days_to_submit,
       ROUND(AVG(CASE WHEN paid_date <> ''
                      THEN DATEDIFF(paid_date, service_date) END), 1) AS avg_days_to_paid,
       MAX(CASE WHEN paid_date <> ''
                THEN DATEDIFF(paid_date, service_date) END)            AS max_days_to_paid
FROM staging_claims_raw
GROUP BY claim_type
ORDER BY avg_days_to_paid;