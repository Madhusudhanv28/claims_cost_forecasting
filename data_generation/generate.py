"""
generate.py -- Raw, dirty claims + membership data generator.
Follows the locked methodology in Data_Generation_Methodology.pdf.
Outputs: claims_raw.csv, membership_raw.csv  (flat, undirected, dirty on purpose)
No fact/dim normalization here -- that happens later in SQL.
"""
import numpy as np
import pandas as pd

rng = np.random.default_rng(42)

N_MEMBERS = 50_000
N_MONTHS = 36
START_PERIOD = pd.Period('2022-01', freq='M')
months = pd.period_range(START_PERIOD, periods=N_MONTHS, freq='M')
month_start_ts = pd.to_datetime([m.start_time for m in months])

REGIONS = np.array(['Northeast', 'Midwest', 'South', 'West'])
REGION_WEIGHTS = [0.22, 0.24, 0.32, 0.22]
REGION_VARIANTS = {
    'Northeast': ['Northeast', 'NE', 'North East', 'northeast'],
    'Midwest':   ['Midwest', 'MW', 'Mid West', 'midwest'],
    'South':     ['South', 'S', 'south', 'SOUTH'],
    'West':      ['West', 'W', 'west', 'WEST'],
}

def dirty_region(canon_array, dirty_frac=0.15):
    out = canon_array.copy().astype(object)
    n = len(out)
    mask = rng.random(n) < dirty_frac
    idx = np.where(mask)[0]
    for i in idx:
        variants = REGION_VARIANTS[out[i]]
        out[i] = rng.choice(variants)
    return out

# ============================================================
# 1. MEMBERSHIP
# ============================================================
print("Generating membership base...")

member_ids = np.array([f"M{str(i).zfill(6)}" for i in range(1, N_MEMBERS + 1)])

age_mix = rng.choice(['infant', 'child', 'adult', 'senior'], size=N_MEMBERS, p=[0.02, 0.18, 0.55, 0.25])
age_years = np.empty(N_MEMBERS)
m = age_mix == 'infant'; age_years[m] = rng.uniform(0, 2, m.sum())
m = age_mix == 'child';  age_years[m] = rng.uniform(2, 18, m.sum())
m = age_mix == 'adult';  age_years[m] = rng.uniform(18, 65, m.sum())
m = age_mix == 'senior'; age_years[m] = rng.uniform(65, 90, m.sum())
birth_dates = pd.Timestamp('2022-01-01') - pd.to_timedelta(age_years * 365.25, unit='D')

member_sex = rng.choice(['M', 'F'], size=N_MEMBERS)
member_plan = rng.choice(['HMO', 'PPO', 'HDHP', 'EPO'], size=N_MEMBERS, p=[0.35, 0.30, 0.25, 0.10])
member_region_canon = rng.choice(REGIONS, size=N_MEMBERS, p=REGION_WEIGHTS)

# most members start at month 0, a declining share join later
start_weights = np.array([0.55] + [0.45 / (N_MONTHS - 1)] * (N_MONTHS - 1))
start_weights = start_weights / start_weights.sum()
enroll_start = rng.choice(N_MONTHS, size=N_MEMBERS, p=start_weights)
churn = rng.random(N_MEMBERS) < 0.25
enroll_len = np.where(
    churn,
    rng.integers(3, np.maximum(N_MONTHS - enroll_start, 4)),
    N_MONTHS - enroll_start
)
enroll_end = np.minimum(enroll_start + enroll_len, N_MONTHS - 1)
n_rows_per_member = (enroll_end - enroll_start + 1).astype(int)

member_id_rows = np.repeat(member_ids, n_rows_per_member)
start_rows = np.repeat(enroll_start, n_rows_per_member)
end_rows = np.repeat(enroll_end, n_rows_per_member)
churn_rows = np.repeat(churn, n_rows_per_member)
offsets = np.concatenate([np.arange(n) for n in n_rows_per_member])
month_idx_rows = start_rows + offsets

membership_df = pd.DataFrame({
    'member_id': member_id_rows,
    'year_month': months[month_idx_rows].astype(str),
    'plan_type': np.repeat(member_plan, n_rows_per_member),
    'region': dirty_region(np.repeat(member_region_canon, n_rows_per_member)),
    'enrollment_status': np.where(
        (month_idx_rows == end_rows) & churn_rows, 'Termed', 'Active'
    ),
    'birth_date': np.repeat(birth_dates.astype(str), n_rows_per_member),
    'sex': np.repeat(member_sex, n_rows_per_member),
})

# dirty: drop ~3.5% of rows (coverage gaps / load misses -- ambiguous by design)
keep_mask = rng.random(len(membership_df)) > 0.035
membership_df = membership_df[keep_mask].reset_index(drop=True)

# dirty: duplicate ~1% of rows
dup_idx = rng.choice(len(membership_df), size=int(len(membership_df) * 0.01), replace=False)
membership_df = pd.concat([membership_df, membership_df.iloc[dup_idx]], ignore_index=True)

membership_df = membership_df.sample(frac=1, random_state=1).reset_index(drop=True)
print(f"membership_raw rows: {len(membership_df):,}")

# member -> (region_canon, plan, birth_date) lookup for claim generation
member_lookup = pd.DataFrame({
    'member_id': member_ids,
    'region_canon': member_region_canon,
    'plan_type': member_plan,
    'birth_date': birth_dates,
    'sex': member_sex,
})
# per-member utilization propensity (drives realistic high-utilizer skew)
member_lookup['utilization_weight'] = rng.lognormal(mean=0.0, sigma=0.9, size=N_MEMBERS)
# per-member chronic disease propensity increases with age
age_now = (pd.Timestamp('2023-06-01') - member_lookup['birth_date']).dt.days / 365.25
chronic_base_p = np.clip(0.02 + age_now / 400, 0.02, 0.55)
for flag in ['diabetes', 'chf', 'cancer', 'copd', 'esrd']:
    member_lookup[f'chronic_{flag}'] = rng.random(N_MEMBERS) < chronic_base_p * rng.uniform(0.4, 1.3, N_MEMBERS)

print("Membership done.\n")

# ============================================================
# 2. PROVIDERS (in-memory pool, denormalized onto claims)
# ============================================================
print("Generating provider pool...")
N_PROVIDERS = 3000
provider_ids = np.array([f"P{str(i).zfill(5)}" for i in range(1, N_PROVIDERS + 1)])
provider_npi = rng.integers(1_000_000_000, 1_999_999_999, size=N_PROVIDERS)

CLAIM_TYPES = np.array(['Inpatient', 'Outpatient', 'Emergency', 'Pharmacy', 'Preventive'])
provider_primary_type = rng.choice(
    ['Hospital', 'Physician Group', 'Clinic', 'Pharmacy', 'Urgent Care'],
    size=N_PROVIDERS, p=[0.12, 0.35, 0.28, 0.15, 0.10]
)
PROVIDER_TO_CLAIMTYPE = {
    'Hospital': ['Inpatient', 'Emergency', 'Outpatient'],
    'Physician Group': ['Outpatient', 'Preventive'],
    'Clinic': ['Outpatient', 'Preventive'],
    'Pharmacy': ['Pharmacy'],
    'Urgent Care': ['Emergency', 'Outpatient'],
}
provider_specialty = rng.choice(
    ['Cardiology', 'Internal Medicine', 'Orthopedics', 'Pediatrics', 'General Surgery',
     'Family Medicine', 'Oncology', 'Radiology', 'Pharmacy Services', 'Emergency Medicine'],
    size=N_PROVIDERS
)
provider_network = rng.random(N_PROVIDERS) < 0.85  # 85% in-network
provider_region = rng.choice(REGIONS, size=N_PROVIDERS, p=REGION_WEIGHTS)
provider_cost_multiplier = rng.lognormal(mean=0.0, sigma=0.25, size=N_PROVIDERS)

provider_lookup = pd.DataFrame({
    'provider_id': provider_ids, 'provider_npi': provider_npi,
    'provider_type': provider_primary_type, 'provider_specialty': provider_specialty,
    'network_status': np.where(provider_network, 'In-Network', 'Out-of-Network'),
    'region_canon': provider_region, 'cost_multiplier': provider_cost_multiplier,
})
provider_idx_by_claimtype = {
    ct: np.where([ct in PROVIDER_TO_CLAIMTYPE[t] for t in provider_primary_type])[0]
    for ct in CLAIM_TYPES
}
print("Providers done.\n")

# ============================================================
# 3. PROCEDURE / DIAGNOSIS CODE POOLS (internal, drives cost; not separate raw files)
# ============================================================
N_PROC_CODES = 80
proc_codes = np.array([f"{rng.integers(10000, 99999)}" for _ in range(N_PROC_CODES)])
proc_complexity = rng.uniform(1, 10, N_PROC_CODES)  # hidden RVU-like weight
proc_claimtype_bias = rng.choice(CLAIM_TYPES, size=N_PROC_CODES)

N_DIAG_CODES = 120
diag_letters = rng.choice(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), size=N_DIAG_CODES)
diag_codes = np.array([f"{l}{rng.integers(10,99)}.{rng.integers(0,9)}" for l in diag_letters])

REV_CODES = np.array(['0120', '0150', '0200', '0450', '0710', '0730'])

print("Code pools done.\n")

# ============================================================
# 4. CLAIMS
# ============================================================
N_CLAIMS_BASE = 985_000
print(f"Generating {N_CLAIMS_BASE:,} base claims...")

# ---- member assignment, weighted by utilization propensity ----
mem_p = member_lookup['utilization_weight'].to_numpy()
mem_p = mem_p / mem_p.sum()
mem_row_idx = rng.choice(N_MEMBERS, size=N_CLAIMS_BASE, p=mem_p)
claim_member_id = member_lookup['member_id'].to_numpy()[mem_row_idx]
claim_member_region_canon = member_lookup['region_canon'].to_numpy()[mem_row_idx]
claim_member_birth = member_lookup['birth_date'].to_numpy()[mem_row_idx]

# ---- service month, with year-over-year trend --------------------------
# FIX (post-profiling finding): claims were previously assigned a month
# independently of the member's own enrollment window, so ~32% of claims
# landed in months the member wasn't even enrolled. Service month must now
# be drawn only from each claim's assigned member's [enroll_start, enroll_end]
# range, weighted by the same year-over-year trend within that range.
trend_weights = np.array([1.0 * (1.055 ** (mi / 12)) for mi in range(N_MONTHS)])
trend_weights = trend_weights / trend_weights.sum()

claim_enroll_start = enroll_start[mem_row_idx]
claim_enroll_end = enroll_end[mem_row_idx]

claim_month_idx = np.empty(N_CLAIMS_BASE, dtype=int)
_combo_df = pd.DataFrame({
    'start': claim_enroll_start,
    'end': claim_enroll_end,
    'orig_idx': np.arange(N_CLAIMS_BASE),
})
for (s, e), _grp in _combo_df.groupby(['start', 'end']):
    idxs = _grp['orig_idx'].to_numpy()
    months_range = np.arange(s, e + 1)
    w = trend_weights[s:e + 1]
    w = w / w.sum()
    claim_month_idx[idxs] = rng.choice(months_range, size=len(idxs), p=w)

day_in_month_by_idx = np.array([p.days_in_month for p in months])
day_offset = rng.integers(0, day_in_month_by_idx[claim_month_idx])
service_date = month_start_ts.to_numpy()[claim_month_idx] + day_offset * np.timedelta64(1, 'D')
is_winter = np.isin((claim_month_idx % 12), [10, 11, 0, 1])  # Nov,Dec,Jan,Feb

# ---- claim type, seasonally adjusted ----
base_ct_p = np.array([0.09, 0.39, 0.10, 0.25, 0.17])   # Inpatient, Outpatient, Emergency, Pharmacy, Preventive
winter_ct_p = np.array([0.13, 0.34, 0.15, 0.24, 0.14])
base_ct_p /= base_ct_p.sum(); winter_ct_p /= winter_ct_p.sum()

claim_type = np.empty(N_CLAIMS_BASE, dtype=object)
n_winter = is_winter.sum()
claim_type[is_winter] = rng.choice(CLAIM_TYPES, size=n_winter, p=winter_ct_p)
claim_type[~is_winter] = rng.choice(CLAIM_TYPES, size=N_CLAIMS_BASE - n_winter, p=base_ct_p)

# ---- provider assignment, conditioned on claim type ----
claim_provider_row = np.empty(N_CLAIMS_BASE, dtype=int)
for ct in CLAIM_TYPES:
    ct_mask = claim_type == ct
    pool = provider_idx_by_claimtype[ct]
    claim_provider_row[ct_mask] = rng.choice(pool, size=ct_mask.sum())

prov = provider_lookup.iloc[claim_provider_row].reset_index(drop=True)

# ---- codes ----
proc_row = np.empty(N_CLAIMS_BASE, dtype=int)
for ct in CLAIM_TYPES:
    ct_mask = claim_type == ct
    pool = np.where(proc_claimtype_bias == ct)[0]
    if len(pool) == 0:
        pool = np.arange(N_PROC_CODES)
    proc_row[ct_mask] = rng.choice(pool, size=ct_mask.sum())
claim_proc_code = proc_codes[proc_row]
claim_proc_complexity = proc_complexity[proc_row]  # hidden, used for cost + interaction

claim_diag1 = rng.choice(diag_codes, size=N_CLAIMS_BASE)
diag2_present = rng.random(N_CLAIMS_BASE) < 0.30
claim_diag2 = np.where(diag2_present, rng.choice(diag_codes, size=N_CLAIMS_BASE), None)

claim_revenue_code = np.where(claim_type == 'Inpatient',
                               rng.choice(REV_CODES, size=N_CLAIMS_BASE), None)

# ---- chronic flags (join from member) ----
mem_chronic = {f: member_lookup[f'chronic_{f}'].to_numpy()[mem_row_idx]
               for f in ['diabetes', 'chf', 'cancer', 'copd', 'esrd']}
n_chronic_flags = sum(mem_chronic.values())

# ---- age at service ----
patient_age = (pd.to_datetime(service_date) - pd.to_datetime(claim_member_birth)).days / 365.25
patient_age = patient_age.to_numpy()

# ---- length of stay ----
length_of_stay = np.zeros(N_CLAIMS_BASE)
ip_mask = claim_type == 'Inpatient'
length_of_stay[ip_mask] = np.round(rng.gamma(shape=2.0, scale=2.3, size=ip_mask.sum())) + 1
er_obs_mask = (claim_type == 'Emergency') & (rng.random(N_CLAIMS_BASE) < 0.15)
length_of_stay[er_obs_mask] = np.round(rng.gamma(shape=1.2, scale=0.8, size=er_obs_mask.sum()))

# ============================================================
# 5. COST GENERATION
# ============================================================
print("Computing severity...")
LOGN_PARAMS = {  # (mu, sigma of underlying normal), tuned to target medians
    'Inpatient':  (9.10, 0.55),
    'Emergency':  (7.50, 0.55),
    'Outpatient': (6.48, 0.60),
    'Pharmacy':   (4.50, 0.65),
    'Preventive': (5.19, 0.35),
}
base_cost = np.empty(N_CLAIMS_BASE)
for ct, (mu, sigma) in LOGN_PARAMS.items():
    ct_mask = claim_type == ct
    base_cost[ct_mask] = rng.lognormal(mean=mu, sigma=sigma, size=ct_mask.sum())

# catastrophic tail: ~0.4% of Inpatient/Emergency redrawn from a heavy Pareto tail
cat_eligible = np.isin(claim_type, ['Inpatient', 'Emergency'])
cat_mask = cat_eligible & (rng.random(N_CLAIMS_BASE) < 0.004)
pareto_draw = (rng.pareto(a=2.2, size=cat_mask.sum()) + 1) * 60_000
base_cost[cat_mask] = np.maximum(base_cost[cat_mask], pareto_draw)

# chronic load (compounding, cancer/ESRD weighted highest)
chronic_weight = {'diabetes': 1.12, 'chf': 1.18, 'cancer': 1.35, 'copd': 1.15, 'esrd': 1.30}
chronic_multiplier = np.ones(N_CLAIMS_BASE)
for f, w in chronic_weight.items():
    chronic_multiplier *= np.where(mem_chronic[f], w, 1.0)

# chronic x procedure-complexity interaction (amplified, not additive)
complexity_norm = claim_proc_complexity / 10.0
interaction_multiplier = 1 + (n_chronic_flags > 0) * complexity_norm * 0.6

# length-of-stay super-linear effect (inpatient/emergency only)
los_multiplier = 1 + 0.18 * (length_of_stay ** 1.15) / 5.0
los_multiplier = np.where(claim_type.astype(str) == 'Pharmacy', 1.0, los_multiplier)
los_multiplier = np.where((claim_type == 'Outpatient') | (claim_type == 'Preventive'), 1.0, los_multiplier)

# age U-shape
age_effect = 1 + 0.55 * np.exp(-((patient_age - 0) / 3) ** 2) + 0.35 * np.exp(-((patient_age - 78) / 12) ** 2)

# network + region + provider persistent effect
network_multiplier = np.where(prov['network_status'] == 'Out-of-Network', rng.uniform(1.2, 1.4, N_CLAIMS_BASE), 1.0)
region_index = {'Northeast': 1.12, 'Midwest': 0.95, 'South': 0.92, 'West': 1.08}
region_multiplier = np.vectorize(region_index.get)(claim_member_region_canon)
provider_multiplier = prov['cost_multiplier'].to_numpy()

# year-over-year trend on cost itself
year_of_claim = (claim_month_idx // 12)
trend_cost_multiplier = 1.055 ** year_of_claim

target_paid = (base_cost * chronic_multiplier * interaction_multiplier * los_multiplier *
               age_effect * network_multiplier * region_multiplier * provider_multiplier *
               trend_cost_multiplier)
target_paid = np.round(target_paid, 2)

print("Severity done.\n")

# ============================================================
# 6. FINANCIAL CHAIN, STATUS, DATES
# ============================================================
print("Building financial chain, status, dates...")

coinsurance_frac = np.where(member_lookup['plan_type'].to_numpy()[mem_row_idx] == 'HDHP',
                             rng.uniform(0.15, 0.30, N_CLAIMS_BASE),
                             rng.uniform(0.05, 0.15, N_CLAIMS_BASE))
patient_resp = np.round(target_paid * coinsurance_frac / (1 - coinsurance_frac), 2)
allowed_amount = np.round(target_paid + patient_resp, 2)
markup = np.where(prov['network_status'].to_numpy() == 'Out-of-Network',
                   rng.uniform(1.8, 3.5, N_CLAIMS_BASE), rng.uniform(1.3, 2.2, N_CLAIMS_BASE))
billed_amount = np.round(allowed_amount * markup, 2)

# claim status
status_roll = rng.random(N_CLAIMS_BASE)
claim_status = np.where(status_roll < 0.88, 'Paid', np.where(status_roll < 0.95, 'Denied', 'Pending'))
denial_reason_pool = np.array(['NOT_COVERED', 'PRIOR_AUTH_MISSING', 'DUPLICATE', 'OUT_OF_NETWORK', 'MED_NECESSITY'])
denial_reason_code = np.where(claim_status == 'Denied',
                               rng.choice(denial_reason_pool, size=N_CLAIMS_BASE), None)

paid_amount_final = target_paid.copy()
paid_amount_final[claim_status == 'Denied'] = 0.0
paid_amount_final[claim_status == 'Pending'] = np.nan
allowed_amount_final = allowed_amount.copy()
allowed_amount_final[claim_status == 'Denied'] = 0.0
patient_resp_final = patient_resp.copy()
patient_resp_final[claim_status == 'Denied'] = 0.0

# claim-type-dependent submission lag, then payment lag
SUBMIT_LAG = {'Pharmacy': (2, 5), 'Preventive': (5, 10), 'Outpatient': (7, 15),
              'Emergency': (10, 20), 'Inpatient': (15, 35)}
submit_lag_days = np.empty(N_CLAIMS_BASE)
for ct, (lo, hi) in SUBMIT_LAG.items():
    ct_mask = claim_type == ct
    submit_lag_days[ct_mask] = rng.integers(lo, hi + 1, ct_mask.sum())
submission_date = pd.to_datetime(service_date) + pd.to_timedelta(submit_lag_days, unit='D')

pay_lag_days = rng.integers(10, 46, size=N_CLAIMS_BASE)
paid_date = submission_date + pd.to_timedelta(pay_lag_days, unit='D')
paid_date = paid_date.where(claim_status == 'Paid', pd.NaT)

print("Financial chain done.\n")

# ============================================================
# 7. ASSEMBLE, PATIENT/REGION FIELDS, IDS
# ============================================================
print("Assembling claims frame...")

claim_id = np.array([f"C{str(i).zfill(8)}" for i in range(1, N_CLAIMS_BASE + 1)])

place_of_service_map = {'Inpatient': 'Inpatient Hospital', 'Outpatient': 'Outpatient Hospital',
                         'Emergency': 'Emergency Room', 'Pharmacy': 'Retail Pharmacy',
                         'Preventive': 'Office'}
place_of_service = np.vectorize(place_of_service_map.get)(claim_type)

record_source = rng.choice(['CLAIMS_SYS_A', 'CLAIMS_SYS_B'], size=N_CLAIMS_BASE, p=[0.7, 0.3])
load_ts_base = pd.Timestamp('2025-01-05') + pd.to_timedelta(rng.integers(0, 20, N_CLAIMS_BASE), unit='D')

claims_df = pd.DataFrame({
    'claim_id': claim_id,
    'member_id': claim_member_id,
    'provider_id': prov['provider_id'].to_numpy(),
    'provider_npi': prov['provider_npi'].to_numpy(),
    'service_date': pd.to_datetime(service_date).strftime('%Y-%m-%d'),
    'claim_submission_date': submission_date.strftime('%Y-%m-%d'),
    'paid_date': paid_date.strftime('%Y-%m-%d'),
    'diagnosis_code_1': claim_diag1,
    'diagnosis_code_2': claim_diag2,
    'procedure_code': claim_proc_code,
    'revenue_code': claim_revenue_code,
    'claim_type': claim_type,
    'place_of_service': place_of_service,
    'length_of_stay': np.where(np.isin(claim_type, ['Inpatient']), length_of_stay,
                                np.where((claim_type == 'Emergency') & er_obs_mask, length_of_stay, np.nan)),
    'billed_amount': billed_amount,
    'allowed_amount': allowed_amount_final,
    'paid_amount': paid_amount_final,
    'patient_responsibility_amount': patient_resp_final,
    'claim_status': claim_status,
    'denial_reason_code': denial_reason_code,
    'provider_type': prov['provider_type'].to_numpy(),
    'provider_specialty': prov['provider_specialty'].to_numpy(),
    'network_status': prov['network_status'].to_numpy(),
    'patient_age': np.round(patient_age, 1),
    'patient_sex': member_lookup['sex'].to_numpy()[mem_row_idx],
    'region': dirty_region(claim_member_region_canon),
    'chronic_flag_diabetes': mem_chronic['diabetes'].astype(int),
    'chronic_flag_chf': mem_chronic['chf'].astype(int),
    'chronic_flag_cancer': mem_chronic['cancer'].astype(int),
    'chronic_flag_copd': mem_chronic['copd'].astype(int),
    'chronic_flag_esrd': mem_chronic['esrd'].astype(int),
    'adjustment_flag': 0,
    'original_claim_id': None,
    'record_source': record_source,
    'load_timestamp': load_ts_base.strftime('%Y-%m-%d %H:%M:%S'),
})

print(f"Base claims assembled: {len(claims_df):,}\n")

# ============================================================
# 8. DIRTY INJECTIONS
# ============================================================
print("Injecting data quality issues...")
n = len(claims_df)

# 8.1 adjustments (~1.5% extra rows referencing an original claim)
n_adj = int(n * 0.015)
adj_src_idx = rng.choice(n, size=n_adj, replace=False)
adj_rows = claims_df.iloc[adj_src_idx].copy().reset_index(drop=True)
adj_rows['original_claim_id'] = adj_rows['claim_id'].to_numpy()
adj_rows['claim_id'] = [f"A{str(i).zfill(8)}" for i in range(1, n_adj + 1)]
adj_rows['adjustment_flag'] = 1
adj_delta_frac = rng.uniform(-0.3, 0.3, n_adj)
adj_rows['paid_amount'] = np.round(pd.to_numeric(adj_rows['paid_amount'], errors='coerce').fillna(0) * (1 + adj_delta_frac), 2)
adj_rows['load_timestamp'] = (pd.to_datetime(adj_rows['load_timestamp']) + pd.to_timedelta(rng.integers(5, 60, n_adj), unit='D')).astype(str)
claims_df = pd.concat([claims_df, adj_rows], ignore_index=True)

# 8.2 exact duplicate claim_id rows (~1.5%)
n_dup = int(n * 0.015)
dup_idx = rng.choice(len(claims_df), size=n_dup, replace=False)
claims_df = pd.concat([claims_df, claims_df.iloc[dup_idx]], ignore_index=True)

n = len(claims_df)

# 8.3 missing procedure_code (~4.5%)
miss_proc_idx = rng.choice(n, size=int(n * 0.045), replace=False)
claims_df.loc[miss_proc_idx, 'procedure_code'] = None

# 8.4 impossible / negative patient_age (~0.3%)
bad_age_idx = rng.choice(n, size=int(n * 0.003), replace=False)
bad_age_vals = rng.choice([-5, -1, 150, 200], size=len(bad_age_idx))
claims_df.loc[bad_age_idx, 'patient_age'] = bad_age_vals

# 8.5 paid_amount > billed_amount error (~0.5%)
err_idx = rng.choice(n, size=int(n * 0.005), replace=False)
claims_df.loc[err_idx, 'paid_amount'] = claims_df.loc[err_idx, 'billed_amount'].astype(float) * rng.uniform(1.05, 1.5, len(err_idx))

# 8.6 inconsistent claim_status casing/text
status_dirty_idx = rng.choice(n, size=int(n * 0.20), replace=False)
def dirty_status(s):
    return {'Paid': rng.choice(['paid', 'PD', 'Paid']),
            'Denied': rng.choice(['DENIED', 'denied', 'Denied']),
            'Pending': rng.choice(['pending', 'PENDING', 'Pending'])}.get(s, s)
claims_df.loc[status_dirty_idx, 'claim_status'] = claims_df.loc[status_dirty_idx, 'claim_status'].map(dirty_status)

# 8.7 orphan member_id (~2.5%) -- points to a member_id that doesn't exist in membership_raw
orphan_idx = rng.choice(n, size=int(n * 0.025), replace=False)
fake_ids = [f"M{str(i).zfill(6)}" for i in range(N_MEMBERS + 1, N_MEMBERS + 1 + len(orphan_idx))]
claims_df.loc[orphan_idx, 'member_id'] = fake_ids

# 8.8 malformed load_timestamp (~2%)
malformed_idx = rng.choice(n, size=int(n * 0.02), replace=False)
malformed_choices = ['', '2025-13-45', 'N/A', '00/00/0000']
claims_df.loc[malformed_idx, 'load_timestamp'] = rng.choice(malformed_choices, size=len(malformed_idx))

print(f"Final claims_raw rows: {len(claims_df):,}\n")

claims_df = claims_df.sample(frac=1, random_state=2).reset_index(drop=True)

# ============================================================
# 9. WRITE
# ============================================================
import os
os.makedirs("./data", exist_ok=True)
out_claims = "./data/claims_raw.csv"
out_members = "./data/membership_raw.csv"
claims_df.to_csv(out_claims, index=False)
membership_df.to_csv(out_members, index=False)
print(f"Wrote {out_claims} ({len(claims_df):,} rows, {claims_df.shape[1]} cols)")
print(f"Wrote {out_members} ({len(membership_df):,} rows, {membership_df.shape[1]} cols)")
