#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
API_VERSION="${API_VERSION:-67.0}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$PROJECT/.ocx/demo-source-seed-$STAMP"

cd "$PROJECT"

for CMD in sf python3 jq; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD"
    exit 1
  fi
done

mkdir -p "$OUT/raw" "$OUT/seed" "$OUT/logs"

echo
echo "============================================================"
echo "OCX DEMO SOURCE DATA - SEED GENERATION"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Output:  $OUT"
echo
echo "THIS SCRIPT IS READ-ONLY AGAINST SALESFORCE."
echo "It does NOT update any records."
echo "============================================================"
echo

# ------------------------------------------------------------------
# 1. Export existing Account data
#
# OCX_ACV__c, OCX_Primary_Product__c, OCX_Revenue_Band__c,
# OCX_Tenure__c and OCX_Renewal_Quarter__c are being used here
# as reconstruction scaffolding because they represent source/profile
# information retained in the demo.
#
# They are NOT NPS/SAT/propensity/model outputs.
# ------------------------------------------------------------------

echo "[1/6] Exporting Account source/profile data..."

sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      Id,
      Name,
      AnnualRevenue,
      Industry,
      NumberOfEmployees,
      BillingCity,
      BillingState,
      BillingCountry,
      OCX_ACV__c,
      OCX_Primary_Product__c,
      OCX_Revenue_Band__c,
      OCX_Tenure__c,
      OCX_Renewal_Quarter__c,
      Customer_Since_Date__c,
      Customer_Segment__c,
      Region__c
    FROM Account
    ORDER BY Id
  " \
  --result-format csv \
  --output-file "$OUT/raw/accounts.csv"

# ------------------------------------------------------------------
# 2. Export Opportunity data
# ------------------------------------------------------------------

echo "[2/6] Exporting Opportunity commercial data..."

sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      Id,
      Name,
      AccountId,
      StageName,
      Type,
      ForecastCategory,
      Probability,
      Amount,
      CloseDate,
      OCX_Renewal_Quarter__c,
      ARR__c,
      Annual_Renewal__c,
      Territory__c
    FROM Opportunity
    ORDER BY Id
  " \
  --result-format csv \
  --output-file "$OUT/raw/opportunities.csv"

# ------------------------------------------------------------------
# 3. Export Case data
#
# Deliberately DO NOT use OCX_Driver__c, OCX_Sentiment__c,
# journey SAT, NPS, propensity or other downstream OCX results.
# ------------------------------------------------------------------

echo "[3/6] Exporting Case/support data..."

sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      Id,
      CaseNumber,
      AccountId,
      Status,
      IsClosed,
      Priority,
      IsEscalated,
      Reason,
      Type,
      CreatedDate,
      ClosedDate,
      Time_to_Resolution_Days__c,
      Ageing_of_Open_Cases_Days__c,
      Support_Level__c,
      Root_Cause__c,
      SLA_Violation__c,
      Product_Line__c,
      Support_Category__c
    FROM Case
    ORDER BY Id
  " \
  --result-format csv \
  --output-file "$OUT/raw/cases.csv"

# ------------------------------------------------------------------
# 4. Check whether native IsEscalated is updateable
# ------------------------------------------------------------------

echo "[4/6] Checking Case.IsEscalated updateability..."

sf sobject describe \
  --target-org "$ORG" \
  --sobject Case \
  --api-version "$API_VERSION" \
  --json \
  > "$OUT/raw/case-describe.json"

IS_ESCALATED_UPDATEABLE="$(
  jq -r '
    .result.fields[]
    | select(.name == "IsEscalated")
    | .updateable
  ' "$OUT/raw/case-describe.json"
)"

echo "Case.IsEscalated updateable: $IS_ESCALATED_UPDATEABLE"

export OCX_CASE_ESCALATED_UPDATEABLE="$IS_ESCALATED_UPDATEABLE"

# ------------------------------------------------------------------
# 5. Build deterministic reconstruction CSVs
# ------------------------------------------------------------------

echo "[5/6] Generating deterministic proposed source values..."

python3 - "$OUT" <<'PY'
import csv
import hashlib
import math
import os
import re
import sys
from collections import Counter
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path

OUT = Path(sys.argv[1])
RAW = OUT / "raw"
SEED = OUT / "seed"

ANCHOR_DATE = date(2026, 8, 1)

# Fixed salt makes reruns deterministic.
SALT = "ocx-demo-source-restoration-v1"

INDUSTRIES = [
    "Technology",
    "Financial Services",
    "Healthcare",
    "Manufacturing",
    "Retail",
    "Professional Services",
    "Telecommunications",
    "Media",
    "Energy",
    "Transportation",
    "Business Services",
    "Consumer Products",
]

LOCATIONS = [
    ("United States", "California", "San Francisco", "West"),
    ("United States", "Washington", "Seattle", "West"),
    ("United States", "Texas", "Austin", "Central"),
    ("United States", "Illinois", "Chicago", "Central"),
    ("United States", "New York", "New York", "East"),
    ("United States", "Massachusetts", "Boston", "East"),
    ("Canada", "Ontario", "Toronto", "Canada"),
    ("Canada", "British Columbia", "Vancouver", "Canada"),
    ("United Kingdom", "England", "London", "EMEA"),
    ("Germany", "Bavaria", "Munich", "EMEA"),
    ("Australia", "New South Wales", "Sydney", "APAC"),
    ("Singapore", "Singapore", "Singapore", "APAC"),
]

ROOT_CAUSES = [
    "Customer Environment",
    "Customer-Driven Knowledge",
    "Defect",
    "Documentation",
    "Feature Request",
    "Infrastructure",
    "Licensing",
    "Third Party",
    "Unknown",
    "Upgrade",
]

ROOT_TO_CATEGORY = {
    "Customer Environment": "Configuration",
    "Customer-Driven Knowledge": "How-To",
    "Defect": "Technical Issue",
    "Documentation": "How-To",
    "Feature Request": "Feature Request",
    "Infrastructure": "Performance",
    "Licensing": "Billing / Licensing",
    "Third Party": "Integration",
    "Unknown": "General",
    "Upgrade": "Upgrade",
}

def h_int(key, mod=None):
    digest = hashlib.sha256(f"{SALT}|{key}".encode("utf-8")).hexdigest()
    value = int(digest[:16], 16)
    return value if mod is None else value % mod

def h_fraction(key):
    return h_int(key, 1_000_000) / 1_000_000.0

def clean(value):
    if value is None:
        return ""
    return str(value).strip()

def is_blank(value):
    return clean(value) == ""

def parse_number(value):
    s = clean(value)
    if not s:
        return None
    s = s.replace(",", "").replace("$", "").replace("%", "")
    match = re.search(r"-?\d+(?:\.\d+)?", s)
    if not match:
        return None
    try:
        return float(match.group())
    except ValueError:
        return None

def parse_band_money(value):
    """
    Best-effort extraction of values such as:
      $10M-$50M
      100M to 500M
      <10M
      >1B
    """
    s = clean(value).upper()
    if not s:
        return None

    token_re = re.compile(r"(\d+(?:\.\d+)?)\s*([KMB])")
    vals = []

    for number, suffix in token_re.findall(s):
        n = float(number)
        mult = {"K": 1_000, "M": 1_000_000, "B": 1_000_000_000}[suffix]
        vals.append(n * mult)

    if not vals:
        return None

    if len(vals) >= 2:
        return sum(vals[:2]) / 2

    val = vals[0]

    if "<" in s:
        return val * 0.65
    if ">" in s or "+" in s:
        return val * 1.35

    return val

def bool_value(value):
    return clean(value).lower() in ("true", "1", "yes", "y")

def money(value):
    n = parse_number(value)
    return None if n is None else round(n, 2)

def csv_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))

def write_csv(path, fieldnames, rows):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

accounts = csv_rows(RAW / "accounts.csv")

account_context = {}
account_updates = []

for row in accounts:
    sfid = row["Id"]
    acv = money(row.get("OCX_ACV__c")) or 0
    rev_band = clean(row.get("OCX_Revenue_Band__c"))
    tenure = parse_number(row.get("OCX_Tenure__c"))

    # Geography: preserve anything already populated.
    country, state, city, region = LOCATIONS[h_int(sfid + "|geo", len(LOCATIONS))]

    billing_country = clean(row.get("BillingCountry")) or country
    billing_state = clean(row.get("BillingState")) or state
    billing_city = clean(row.get("BillingCity")) or city
    final_region = clean(row.get("Region__c")) or region

    # Industry: original source contained industry; use a deterministic
    # anonymized distribution only when that source value was lost.
    industry = clean(row.get("Industry")) or INDUSTRIES[
        h_int(sfid + "|industry", len(INDUSTRIES))
    ]

    # Annual Revenue:
    # prefer existing standard value;
    # otherwise use retained revenue-band information if parseable;
    # otherwise derive a plausible anonymized value from ACV.
    existing_revenue = money(row.get("AnnualRevenue"))
    band_revenue = parse_band_money(rev_band)

    if existing_revenue is not None:
        annual_revenue = existing_revenue
    elif band_revenue is not None:
        jitter = 0.88 + 0.24 * h_fraction(sfid + "|revenue")
        annual_revenue = round(band_revenue * jitter, 0)
    else:
        acv_base = max(acv, 25_000)
        multiplier = 60 + h_int(sfid + "|revenue-multiple", 121)
        annual_revenue = round(max(2_000_000, acv_base * multiplier), 0)

    # Employees are consistent with annual revenue rather than independently
    # random. Revenue-per-employee varies deterministically.
    existing_employees = parse_number(row.get("NumberOfEmployees"))
    if existing_employees is not None:
        employees = int(existing_employees)
    else:
        revenue_per_employee = (
            180_000 + h_int(sfid + "|rpe", 321_000)
        )
        employees = max(20, int(annual_revenue / revenue_per_employee))
        employees = min(employees, 75_000)

    # Segment is derived from retained ACV, which makes commercial size and
    # profile segment coherent.
    existing_segment = clean(row.get("Customer_Segment__c"))

    if existing_segment:
        segment = existing_segment
    elif acv >= 500_000:
        segment = "Strategic"
    elif acv >= 150_000:
        segment = "Enterprise"
    elif acv >= 50_000:
        segment = "Mid-Market"
    else:
        segment = "SMB"

    # Reconstruct customer-since date from retained tenure where possible.
    existing_since = clean(row.get("Customer_Since_Date__c"))

    if existing_since:
        customer_since = existing_since
    else:
        if tenure is None or tenure <= 0:
            tenure = 1 + h_int(sfid + "|tenure", 9) + (
                h_int(sfid + "|tenure-days", 365) / 365
            )

        days = max(90, int(tenure * 365.25))
        customer_since = (ANCHOR_DATE - timedelta(days=days)).isoformat()

    product = clean(row.get("OCX_Primary_Product__c"))

    account_context[sfid] = {
        "acv": acv,
        "annual_revenue": annual_revenue,
        "employees": employees,
        "segment": segment,
        "region": final_region,
        "product": product,
        "country": billing_country,
        "industry": industry,
    }

    account_updates.append({
        "Id": sfid,
        "AnnualRevenue": int(annual_revenue),
        "Industry": industry,
        "NumberOfEmployees": employees,
        "BillingCity": billing_city,
        "BillingState": billing_state,
        "BillingCountry": billing_country,
        "Customer_Since_Date__c": customer_since,
        "Customer_Segment__c": segment,
        "Region__c": final_region,
    })

write_csv(
    SEED / "Account_updates.csv",
    [
        "Id",
        "AnnualRevenue",
        "Industry",
        "NumberOfEmployees",
        "BillingCity",
        "BillingState",
        "BillingCountry",
        "Customer_Since_Date__c",
        "Customer_Segment__c",
        "Region__c",
    ],
    account_updates,
)

# ------------------------------------------------------------------
# Opportunity
# ------------------------------------------------------------------

opportunities = csv_rows(RAW / "opportunities.csv")
opportunity_updates = []

for row in opportunities:
    sfid = row["Id"]
    account_id = clean(row.get("AccountId"))
    amount = money(row.get("Amount")) or 0
    name = clean(row.get("Name"))
    opp_type = clean(row.get("Type"))

    renewal = (
        "renew" in name.lower()
        or "renew" in opp_type.lower()
        or bool(clean(row.get("OCX_Renewal_Quarter__c")))
    )

    existing_arr = money(row.get("ARR__c"))

    if existing_arr is not None:
        arr = existing_arr
    elif amount > 0:
        if renewal:
            factor = 0.90 + (0.10 * h_fraction(sfid + "|arr"))
        else:
            factor = 0.65 + (0.25 * h_fraction(sfid + "|arr"))
        arr = round(amount * factor, 2)
    else:
        arr = 0

    existing_renewal = money(row.get("Annual_Renewal__c"))

    if existing_renewal is not None:
        annual_renewal = existing_renewal
    elif renewal:
        annual_renewal = round(arr, 2)
    else:
        annual_renewal = ""

    territory = clean(row.get("Territory__c"))

    if not territory and account_id in account_context:
        territory = account_context[account_id]["region"]

    opportunity_updates.append({
        "Id": sfid,
        "ARR__c": f"{arr:.2f}",
        "Annual_Renewal__c": (
            f"{annual_renewal:.2f}"
            if isinstance(annual_renewal, (float, int))
            else ""
        ),
        "Territory__c": territory,
    })

write_csv(
    SEED / "Opportunity_updates.csv",
    [
        "Id",
        "ARR__c",
        "Annual_Renewal__c",
        "Territory__c",
    ],
    opportunity_updates,
)

# ------------------------------------------------------------------
# Case
# ------------------------------------------------------------------

cases = csv_rows(RAW / "cases.csv")
case_updates = []

update_escalated = (
    os.environ.get("OCX_CASE_ESCALATED_UPDATEABLE", "false").lower()
    == "true"
)

def support_level_for(account_id, key):
    segment = account_context.get(account_id, {}).get("segment", "")

    if segment in ("Strategic", "Enterprise"):
        return "Level 2 Paying"

    if segment == "Mid-Market":
        return "Level 1 Paying"

    # SMB mix.
    return (
        "Level 1 Paying"
        if h_fraction(key + "|support-level") > 0.55
        else "Free"
    )

def ttr_for(priority, key):
    p = priority.lower()
    f = h_fraction(key + "|ttr")

    if "high" in p:
        return round(0.25 + f * 3.0, 2)

    if "medium" in p:
        return round(1.0 + f * 6.0, 2)

    if "low" in p:
        return round(2.0 + f * 12.0, 2)

    return round(1.0 + f * 9.0, 2)

def open_age_for(priority, key):
    p = priority.lower()

    if "high" in p:
        maximum = 12
    elif "medium" in p:
        maximum = 25
    else:
        maximum = 45

    return round(
        1 + h_fraction(key + "|open-age") * (maximum - 1),
        2
    )

def sla_threshold(priority, support_level):
    p = priority.lower()

    if "high" in p:
        base = 1.0
    elif "medium" in p:
        base = 4.0
    else:
        base = 8.0

    if support_level == "Level 2 Paying":
        return base

    if support_level == "Level 1 Paying":
        return base * 1.5

    return base * 2.0

for row in cases:
    sfid = row["Id"]
    account_id = clean(row.get("AccountId"))
    is_closed = bool_value(row.get("IsClosed"))
    priority = clean(row.get("Priority")) or "Medium"

    support_level = (
        clean(row.get("Support_Level__c"))
        or support_level_for(account_id, sfid)
    )

    root_cause = clean(row.get("Root_Cause__c"))

    if not root_cause:
        root_cause = ROOT_CAUSES[
            h_int(sfid + "|root-cause", len(ROOT_CAUSES))
        ]

    category = (
        clean(row.get("Support_Category__c"))
        or ROOT_TO_CATEGORY[root_cause]
    )

    product = clean(row.get("Product_Line__c"))

    if not product:
        product = account_context.get(account_id, {}).get("product", "")

    if not product:
        product = "Core Platform"

    existing_ttr = parse_number(row.get("Time_to_Resolution_Days__c"))
    existing_age = parse_number(row.get("Ageing_of_Open_Cases_Days__c"))

    if is_closed:
        ttr = (
            round(existing_ttr, 2)
            if existing_ttr is not None
            else ttr_for(priority, sfid)
        )
        open_age = ""
        metric_for_sla = ttr
    else:
        ttr = ""
        open_age = (
            round(existing_age, 2)
            if existing_age is not None
            else open_age_for(priority, sfid)
        )
        metric_for_sla = open_age

    threshold = sla_threshold(priority, support_level)

    calculated_violation = metric_for_sla > threshold

    # Preserve an existing true value; otherwise create a coherent source
    # indicator from duration/age versus service target.
    existing_violation = bool_value(row.get("SLA_Violation__c"))
    violation = existing_violation or calculated_violation

    output = {
        "Id": sfid,
        "Time_to_Resolution_Days__c": (
            f"{ttr:.2f}" if isinstance(ttr, (float, int)) else ""
        ),
        "Ageing_of_Open_Cases_Days__c": (
            f"{open_age:.2f}"
            if isinstance(open_age, (float, int))
            else ""
        ),
        "Support_Level__c": support_level,
        "Root_Cause__c": root_cause,
        "SLA_Violation__c": "true" if violation else "false",
        "Product_Line__c": product,
        "Support_Category__c": category,
    }

    if update_escalated:
        # Escalation is related to severity/SLA breach but not identical.
        # This creates reasonable variation rather than setting all breached
        # cases to escalated.
        currently_escalated = bool_value(row.get("IsEscalated"))

        generated_escalation = (
            violation
            and (
                "high" in priority.lower()
                or h_fraction(sfid + "|escalation") > 0.62
            )
        )

        output["IsEscalated"] = (
            "true"
            if (currently_escalated or generated_escalation)
            else "false"
        )

    case_updates.append(output)

case_fields = [
    "Id",
    "Time_to_Resolution_Days__c",
    "Ageing_of_Open_Cases_Days__c",
    "Support_Level__c",
    "Root_Cause__c",
    "SLA_Violation__c",
    "Product_Line__c",
    "Support_Category__c",
]

if update_escalated:
    case_fields.append("IsEscalated")

write_csv(
    SEED / "Case_updates.csv",
    case_fields,
    case_updates,
)

# ------------------------------------------------------------------
# Summary report
# ------------------------------------------------------------------

def count_values(rows, field):
    return Counter(clean(r.get(field)) or "(blank)" for r in rows)

def pct(n, total):
    return 0 if not total else round(n * 100.0 / total, 1)

account_industries = count_values(account_updates, "Industry")
account_segments = count_values(account_updates, "Customer_Segment__c")
account_regions = count_values(account_updates, "Region__c")
account_countries = count_values(account_updates, "BillingCountry")

case_levels = count_values(case_updates, "Support_Level__c")
case_roots = count_values(case_updates, "Root_Cause__c")
case_categories = count_values(case_updates, "Support_Category__c")
case_sla = count_values(case_updates, "SLA_Violation__c")

closed_cases = sum(1 for r in cases if bool_value(r.get("IsClosed")))
open_cases = len(cases) - closed_cases

escalated_count = None
if update_escalated:
    escalated_count = sum(
        1
        for r in case_updates
        if bool_value(r.get("IsEscalated"))
    )

def top_lines(counter, limit=20):
    return "\n".join(
        f"  {k}: {v}"
        for k, v in counter.most_common(limit)
    )

report = f"""# OCX Demo Source Seed Preview

ANCHOR DATE
-----------
{ANCHOR_DATE.isoformat()}

NO SALESFORCE RECORDS WERE MODIFIED.

ACCOUNT
-------
Records: {len(account_updates)}

Industry distribution:
{top_lines(account_industries)}

Customer segment distribution:
{top_lines(account_segments)}

Region distribution:
{top_lines(account_regions)}

Country distribution:
{top_lines(account_countries)}

Annual Revenue:
  min: {min(float(r["AnnualRevenue"]) for r in account_updates):,.0f}
  max: {max(float(r["AnnualRevenue"]) for r in account_updates):,.0f}
  avg: {sum(float(r["AnnualRevenue"]) for r in account_updates) / len(account_updates):,.0f}

Employees:
  min: {min(int(r["NumberOfEmployees"]) for r in account_updates):,}
  max: {max(int(r["NumberOfEmployees"]) for r in account_updates):,}
  avg: {sum(int(r["NumberOfEmployees"]) for r in account_updates) / len(account_updates):,.0f}

OPPORTUNITY
-----------
Records: {len(opportunity_updates)}

ARR populated:
  {sum(1 for r in opportunity_updates if clean(r["ARR__c"]))}
  ({pct(sum(1 for r in opportunity_updates if clean(r["ARR__c"])), len(opportunity_updates))}%)

Annual Renewal populated:
  {sum(1 for r in opportunity_updates if clean(r["Annual_Renewal__c"]))}
  ({pct(sum(1 for r in opportunity_updates if clean(r["Annual_Renewal__c"])), len(opportunity_updates))}%)

Territory populated:
  {sum(1 for r in opportunity_updates if clean(r["Territory__c"]))}
  ({pct(sum(1 for r in opportunity_updates if clean(r["Territory__c"])), len(opportunity_updates))}%)

CASE / SUPPORT
--------------
Records: {len(case_updates)}
Closed: {closed_cases}
Open: {open_cases}

Support levels:
{top_lines(case_levels)}

Root causes:
{top_lines(case_roots)}

Support categories:
{top_lines(case_categories)}

SLA violation:
{top_lines(case_sla)}

Case.IsEscalated updateable:
  {update_escalated}
"""

if escalated_count is not None:
    report += f"""
Proposed escalated cases:
  {escalated_count}
  ({pct(escalated_count, len(case_updates))}%)
"""

report += """
SOURCE-PROVENANCE RULES
-----------------------
These seed files restore/reconstruct plausible upstream inputs.

They intentionally do NOT use:
- NPS or NPS class
- Journey SAT
- Driver SAT
- propensity or predictions
- portfolio outputs
- expansion outputs
- OCX survey outcomes
- OCX Driver classification for support cases

Conversation payloads are NOT being copied into Salesforce.
Task.OCX_Activity_ID__c remains the join to the Conversations DB.

NOT YET RESTORED
----------------
Two source ingredients from the original feature dictionary remain candidates
for a later metadata delta if we decide they improve the demo:

- Opportunity renewal-specific probability
- Source-system support case satisfaction / CSAT

Neither is required to validate Salesforce schema-driven feature discovery.
"""

(OUT / "SEED_PREVIEW.txt").write_text(report)

print(report)
PY

# ------------------------------------------------------------------
# 6. Show samples and final paths
# ------------------------------------------------------------------

echo
echo "[6/6] Previewing proposed CSV updates..."
echo

echo "ACCOUNT SAMPLE"
echo "--------------"
head -n 8 "$OUT/seed/Account_updates.csv"

echo
echo "OPPORTUNITY SAMPLE"
echo "------------------"
head -n 8 "$OUT/seed/Opportunity_updates.csv"

echo
echo "CASE SAMPLE"
echo "-----------"
head -n 8 "$OUT/seed/Case_updates.csv"

echo
echo "============================================================"
echo "SEED GENERATION COMPLETE"
echo "============================================================"
echo
echo "NO SALESFORCE RECORDS WERE MODIFIED."
echo
echo "Review this report:"
echo "  $OUT/SEED_PREVIEW.txt"
echo
echo "Generated update files:"
echo "  $OUT/seed/Account_updates.csv"
echo "  $OUT/seed/Opportunity_updates.csv"
echo "  $OUT/seed/Case_updates.csv"
echo
echo "Raw source exports:"
echo "  $OUT/raw/accounts.csv"
echo "  $OUT/raw/opportunities.csv"
echo "  $OUT/raw/cases.csv"
echo
echo "Do NOT run a bulk update yet."
echo "============================================================"
echo
