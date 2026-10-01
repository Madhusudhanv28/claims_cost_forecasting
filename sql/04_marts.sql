-- ============================================================
-- 04_marts.sql
-- Marts (Gold) layer: analysis-ready tables built on top of the
-- clean core layer (dim_calendar, dim_provider, dim_member,
-- fact_claim). This is what the Python notebook will query.
--
-- Resolves: D4 (the coverage-gap rule deferred from profiling)
-- Produces: fact_member_month, mart_claim_features,
--           mart_monthly_member_months, mart_monthly_claims,
--           mart_lag_triangle
--
-- Run with SOURCE in the MySQL Command Line Client. Raise the temp
-- table memory first -- this script does a member-level self-join
-- that benefits from it, the same lesson as the core layer build.
-- ============================================================

USE claims_forecasting;
SET SESSION tmp_table_size = 536870912;
SET SESSION max_heap_table_size = 536870912;

-- One-time index. Error 1061 on rerun is harmless -- it already exists.
ALTER TABLE fact_claim ADD INDEX idx_member_service (member_sk, service_date);


-- ============================================================
-- SECTION 1: resolve D4 -- measure gap run lengths before deciding
-- Profiling found 51% of members have at least one missing month,
-- but never measured whether those gaps are isolated single months
-- or long runs. This decides the rule with evidence, not a guess.
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_months;
CREATE TEMPORARY TABLE tmp_months AS
SELECT DISTINCT month_year, (YEAR(calendar_date) * 12 + MONTH(calendar_date)) AS month_idx
FROM dim_calendar;

-- D3: dedupe the 12,022 duplicate (member, month) pairs -- a plain
-- DISTINCT is sufficient here (unlike claims) because 8.3 already
-- confirmed every member-stable attribute never varies, so there is
-- nothing left for two copies of the same (member, month) to disagree on.
DROP TEMPORARY TABLE IF EXISTS tmp_member_actual;
CREATE TEMPORARY TABLE tmp_member_actual AS
SELECT DISTINCT member_id, month_year
FROM staging_membership_raw;

DROP TEMPORARY TABLE IF EXISTS tmp_member_span;
CREATE TEMPORARY TABLE tmp_member_span AS
SELECT a.member_id,
       MIN(m.month_idx) AS span_start_idx,
       MAX(m.month_idx) AS span_end_idx
FROM tmp_member_actual a
JOIN tmp_months m ON m.month_year = a.month_year
GROUP BY a.member_id;

-- Every month within each member's own enrollment span, flagged
-- present (1) or absent (a gap candidate, 0).
DROP TEMPORARY TABLE IF EXISTS tmp_member_month_flagged;
CREATE TEMPORARY TABLE tmp_member_month_flagged AS
SELECT
    s.member_id,
    mo.month_year,
    mo.month_idx,
    (act.member_id IS NOT NULL) AS is_present
FROM tmp_member_span s
JOIN tmp_months mo ON mo.month_idx BETWEEN s.span_start_idx AND s.span_end_idx
LEFT JOIN tmp_member_actual act
       ON act.member_id = s.member_id AND act.month_year = mo.month_year;

ALTER TABLE tmp_member_month_flagged ADD INDEX idx_mid_idx (member_id, month_idx);

-- Measure run length: is each absent month isolated (both neighbors
-- present) or part of a longer run? This is the evidence D4 needed.
DROP TEMPORARY TABLE IF EXISTS tmp_gap_evidence;
CREATE TEMPORARY TABLE tmp_gap_evidence AS
SELECT
    f.member_id, f.month_year, f.is_present,
    LAG(f.is_present)  OVER (PARTITION BY f.member_id ORDER BY f.month_idx) AS prev_present,
    LEAD(f.is_present) OVER (PARTITION BY f.member_id ORDER BY f.month_idx) AS next_present
FROM tmp_member_month_flagged f;

-- The decision in numbers: how many gap-months are isolated (fillable)
-- vs. part of a run of 2+ (a real lapse, left alone)?
SELECT
    SUM(is_present = 0 AND COALESCE(prev_present,1) = 1 AND COALESCE(next_present,1) = 1) AS isolated_single_month_gaps,
    SUM(is_present = 0) - SUM(is_present = 0 AND COALESCE(prev_present,1) = 1 AND COALESCE(next_present,1) = 1) AS longer_run_gap_months,
    SUM(is_present = 0) AS total_gap_months
FROM tmp_gap_evidence;

-- D4, decided: an absent month with a present month immediately
-- before AND after it (within the member's own span) is treated as
-- a load miss and filled. A gap with no present neighbor on at
-- least one side is part of a longer run and is treated as a real
-- coverage lapse -- left absent, not filled.
DROP TEMPORARY TABLE IF EXISTS tmp_gap_fill_decision;
CREATE TEMPORARY TABLE tmp_gap_fill_decision AS
SELECT member_id, month_year,
       (is_present = 0 AND COALESCE(prev_present,1) = 1 AND COALESCE(next_present,1) = 1) AS fill_this_gap
FROM tmp_gap_evidence
WHERE is_present = 1
   OR (is_present = 0 AND COALESCE(prev_present,1) = 1 AND COALESCE(next_present,1) = 1);


-- ============================================================
-- SECTION 2: fact_member_month -- the exposure table
-- Grain: one row per member per month they are considered covered,
-- including filled single-month gaps (flagged), excluding real lapses.
-- ============================================================
DROP TABLE IF EXISTS fact_member_month;
CREATE TABLE fact_member_month (
    member_sk       INT NOT NULL,
    month_year      VARCHAR(7) NOT NULL,
    is_filled_gap   TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (member_sk, month_year),
    CONSTRAINT fk_fmm_member FOREIGN KEY (member_sk) REFERENCES dim_member(member_sk)
);

INSERT INTO fact_member_month (member_sk, month_year, is_filled_gap)
SELECT dm.member_sk, g.month_year, g.fill_this_gap
FROM tmp_gap_fill_decision g
JOIN dim_member dm ON dm.member_id = g.member_id;

-- Reconciliation: how much exposure did filling actually add?
SELECT
    SUM(is_filled_gap = 0) AS actually_reported_member_months,
    SUM(is_filled_gap = 1) AS filled_gap_member_months,
    COUNT(*) AS total_member_months_in_fact
FROM fact_member_month;


-- ============================================================
-- SECTION 3: mart_claim_features
-- Grain: one row per claim (mirrors fact_claim), with point-in-time
-- safe engineered features added. "Point-in-time safe" means every
-- feature for a claim uses only that member's EARLIER claims --
-- never a future claim -- which is what a leakage-safe feature
-- requires for forecasting.
-- ============================================================
DROP TABLE IF EXISTS mart_claim_features;
CREATE TABLE mart_claim_features (
    claim_sk            INT PRIMARY KEY,
    member_sk             INT NOT NULL,
    service_date            DATE NOT NULL,
    prior_claims_12mo         INT NOT NULL,
    days_since_last_claim      INT NULL,
    patient_age                  DECIMAL(6,1) NULL,
    chronic_flag_diabetes          TINYINT NULL,
    chronic_flag_chf                 TINYINT NULL,
    chronic_flag_cancer                TINYINT NULL,
    chronic_flag_copd                    TINYINT NULL,
    chronic_flag_esrd                      TINYINT NULL,
    claim_type                               VARCHAR(30),
    network_status                             VARCHAR(30),
    region                                        VARCHAR(20),
    paid_amount                                     DECIMAL(14,2),
    CONSTRAINT fk_mcf_claim  FOREIGN KEY (claim_sk)  REFERENCES fact_claim(claim_sk),
    CONSTRAINT fk_mcf_member FOREIGN KEY (member_sk) REFERENCES dim_member(member_sk)
);

-- days_since_last_claim: a simple ordered window function, cheap.
DROP TEMPORARY TABLE IF EXISTS tmp_last_claim;
CREATE TEMPORARY TABLE tmp_last_claim AS
SELECT claim_sk, member_sk, service_date,
       DATEDIFF(service_date, LAG(service_date) OVER (PARTITION BY member_sk ORDER BY service_date, claim_sk)) AS days_since_last_claim
FROM fact_claim;

-- prior_claims_12mo: for each claim, count that SAME member's claims
-- in the 12 months strictly BEFORE this claim's service_date. A
-- self-join, not a correlated subquery -- with the index from
-- Section 0, MySQL can satisfy this with an indexed range scan per
-- member rather than a full table scan per row. This is the
-- heaviest query in this script; expect it to take a few minutes.
DROP TEMPORARY TABLE IF EXISTS tmp_prior_claims;
CREATE TEMPORARY TABLE tmp_prior_claims AS
SELECT a.claim_sk, COUNT(b.claim_sk) AS prior_claims_12mo
FROM fact_claim a
LEFT JOIN fact_claim b
       ON b.member_sk = a.member_sk
      AND b.service_date <  a.service_date
      AND b.service_date >= a.service_date - INTERVAL 12 MONTH
GROUP BY a.claim_sk;

INSERT INTO mart_claim_features (
    claim_sk, member_sk, service_date, prior_claims_12mo, days_since_last_claim,
    patient_age, chronic_flag_diabetes, chronic_flag_chf, chronic_flag_cancer,
    chronic_flag_copd, chronic_flag_esrd, claim_type, network_status, region, paid_amount
)
SELECT
    f.claim_sk, f.member_sk, f.service_date,
    pc.prior_claims_12mo,
    lc.days_since_last_claim,
    f.patient_age,
    dm.chronic_flag_diabetes, dm.chronic_flag_chf, dm.chronic_flag_cancer,
    dm.chronic_flag_copd, dm.chronic_flag_esrd,
    f.claim_type,
    dp.network_status,
    dm.region,
    f.paid_amount
FROM fact_claim f
JOIN tmp_prior_claims pc ON pc.claim_sk = f.claim_sk
JOIN tmp_last_claim    lc ON lc.claim_sk = f.claim_sk
JOIN dim_member  dm ON dm.member_sk   = f.member_sk
JOIN dim_provider dp ON dp.provider_sk = f.provider_sk;


-- ============================================================
-- SECTION 4: monthly exposure and claims -- the PMPM building blocks
-- Stored as two separate aggregate tables rather than one pre-divided
-- PMPM number: the ratio is computed in a VIEW instead, so it is
-- always consistent with the underlying counts rather than a stale
-- stored value if either side changes later.
-- ============================================================
DROP TABLE IF EXISTS mart_monthly_member_months;
CREATE TABLE mart_monthly_member_months (
    month_year      VARCHAR(7) PRIMARY KEY,
    member_months    INT NOT NULL
);
INSERT INTO mart_monthly_member_months
SELECT month_year, COUNT(*) FROM fact_member_month GROUP BY month_year;

DROP TABLE IF EXISTS mart_monthly_claims;
CREATE TABLE mart_monthly_claims (
    month_year      VARCHAR(7) NOT NULL,
    claim_type       VARCHAR(30) NOT NULL,
    claim_count       INT NOT NULL,
    total_paid         DECIMAL(16,2) NOT NULL,
    PRIMARY KEY (month_year, claim_type)
);
INSERT INTO mart_monthly_claims
SELECT DATE_FORMAT(service_date, '%Y-%m'), claim_type, COUNT(*), SUM(paid_amount)
FROM fact_claim
WHERE claim_status = 'Paid'
GROUP BY DATE_FORMAT(service_date, '%Y-%m'), claim_type;

DROP VIEW IF EXISTS mart_pmpm;
CREATE VIEW mart_pmpm AS
SELECT c.month_year, c.claim_type, c.claim_count, c.total_paid,
       mm.member_months,
       ROUND(c.total_paid / mm.member_months, 2) AS pmpm
FROM mart_monthly_claims c
JOIN mart_monthly_member_months mm ON mm.month_year = c.month_year;


-- ============================================================
-- SECTION 5: mart_lag_triangle -- the input to completion factors / IBNR
-- Grain: one row per (service month, lag in months). Built only from
-- Paid claims with a real paid_date (Denied has no payment event to
-- lag; Pending has not completed yet).
-- ============================================================
DROP TABLE IF EXISTS mart_lag_triangle;
CREATE TABLE mart_lag_triangle (
    service_month    VARCHAR(7) NOT NULL,
    lag_months        INT NOT NULL,
    claim_count         INT NOT NULL,
    incremental_paid      DECIMAL(16,2) NOT NULL,
    PRIMARY KEY (service_month, lag_months)
);
INSERT INTO mart_lag_triangle
SELECT
    DATE_FORMAT(service_date, '%Y-%m'),
    (YEAR(paid_date) - YEAR(service_date)) * 12 + (MONTH(paid_date) - MONTH(service_date)),
    COUNT(*),
    SUM(paid_amount)
FROM fact_claim
WHERE claim_status = 'Paid' AND paid_date IS NOT NULL
GROUP BY DATE_FORMAT(service_date, '%Y-%m'),
         (YEAR(paid_date) - YEAR(service_date)) * 12 + (MONTH(paid_date) - MONTH(service_date));


-- ============================================================
-- SECTION 6: sanity checks
-- ============================================================
SELECT COUNT(*) AS rows_in_mart_claim_features, (SELECT COUNT(*) FROM fact_claim) AS rows_in_fact_claim;
-- Expect equal.

SELECT * FROM mart_pmpm ORDER BY month_year, claim_type LIMIT 15;

SELECT service_month, SUM(claim_count) AS claims, SUM(incremental_paid) AS paid
FROM mart_lag_triangle GROUP BY service_month ORDER BY service_month LIMIT 12;

SELECT * FROM mart_claim_features LIMIT 10;
