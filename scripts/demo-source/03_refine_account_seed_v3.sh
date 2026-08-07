#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
cd "$PROJECT"

LATEST="$(
  find "$PROJECT/.ocx" \
    -maxdepth 1 \
    -type d \
    -name 'demo-source-seed-*' \
    -print \
  | sort \
  | tail -n 1
)"

[ -n "$LATEST" ] || {
  echo "ERROR: No demo-source-seed directory found."
  exit 1
}

RAW="$LATEST/raw/accounts.csv"
V2="$LATEST/seed-v2"
V3="$LATEST/seed-v3"

mkdir -p "$V3"

[ -f "$RAW" ] || {
  echo "ERROR: Missing $RAW"
  exit 1
}

[ -f "$V2/Opportunity_updates.csv" ] || {
  echo "ERROR: Missing Opportunity V2 seed"
  exit 1
}

[ -f "$V2/Case_updates.csv" ] || {
  echo "ERROR: Missing Case V2 seed"
  exit 1
}

python3 - "$RAW" "$V3/Account_updates.csv" <<'PY'
import csv
import hashlib
import math
import statistics
import sys
from collections import Counter
from datetime import date, timedelta

SOURCE = sys.argv[1]
OUTPUT = sys.argv[2]

SALT = "ocx-demo-account-profile-v3"
ANCHOR = date(2026, 8, 1)

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

# Company annual-revenue ranges, NOT contract value.
REVENUE_RANGES = {
    "SMB":        (5_000_000,     75_000_000),
    "Mid-Market": (50_000_000,   750_000_000),
    "Enterprise": (500_000_000,  7_500_000_000),
    "Strategic":  (2_000_000_000, 30_000_000_000),
}

def h_int(key, mod=None):
    digest = hashlib.sha256(
        f"{SALT}|{key}".encode()
    ).hexdigest()
    n = int(digest[:16], 16)
    return n if mod is None else n % mod

def frac(key):
    return h_int(key, 1_000_000) / 1_000_000

def text(v):
    return "" if v is None else str(v).strip()

def number(v):
    s = text(v).replace(",", "").replace("$", "")
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None

def log_uniform(low, high, key):
    f = frac(key)
    value = math.exp(
        math.log(low) +
        f * (math.log(high) - math.log(low))
    )
    return value

with open(SOURCE, newline="", encoding="utf-8-sig") as f:
    source_rows = list(csv.DictReader(f))

rows = []

for r in source_rows:
    sfid = r["Id"]

    acv = number(r.get("OCX_ACV__c")) or 0
    tenure = number(r.get("OCX_Tenure__c"))

    # Retain the V2 segment logic based on contract value.
    if acv >= 500_000:
        segment = "Strategic"
    elif acv >= 150_000:
        segment = "Enterprise"
    elif acv >= 50_000:
        segment = "Mid-Market"
    else:
        segment = "SMB"

    # Generate corporate revenue independently of ACV.
    low, high = REVENUE_RANGES[segment]

    annual_revenue = round(
        log_uniform(
            low,
            high,
            sfid + "|company-revenue"
        ),
        -5
    )

    # Revenue per employee gives realistic but varied company size.
    revenue_per_employee = (
        175_000 +
        h_int(
            sfid + "|revenue-per-employee",
            425_001
        )
    )

    employees = max(
        15,
        round(
            annual_revenue /
            revenue_per_employee
        )
    )

    employees = min(employees, 100_000)

    # Keep any real/preexisting profile field if already populated.
    industry = (
        text(r.get("Industry"))
        or INDUSTRIES[
            h_int(
                sfid + "|industry",
                len(INDUSTRIES)
            )
        ]
    )

    country, state, city, region = LOCATIONS[
        h_int(sfid + "|location", len(LOCATIONS))
    ]

    billing_country = text(r.get("BillingCountry")) or country
    billing_state = text(r.get("BillingState")) or state
    billing_city = text(r.get("BillingCity")) or city

    existing_region = text(r.get("Region__c"))

    if existing_region:
        region = existing_region

    existing_since = text(
        r.get("Customer_Since_Date__c")
    )

    if existing_since:
        customer_since = existing_since
    else:
        if tenure is None or tenure <= 0:
            tenure = (
                1 +
                h_int(sfid + "|tenure", 9) +
                frac(sfid + "|tenure-fraction")
            )

        customer_since = (
            ANCHOR -
            timedelta(
                days=max(
                    90,
                    round(tenure * 365.25)
                )
            )
        ).isoformat()

    rows.append({
        "Id": sfid,
        "AnnualRevenue": int(annual_revenue),
        "Industry": industry,
        "NumberOfEmployees": employees,
        "BillingCity": billing_city,
        "BillingState": billing_state,
        "BillingCountry": billing_country,
        "Customer_Since_Date__c": customer_since,
        "Customer_Segment__c": segment,
        "Region__c": region,
    })

fields = [
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
]

with open(OUTPUT, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)

def percentile(values, p):
    vals = sorted(values)
    pos = (len(vals) - 1) * p
    lo = math.floor(pos)
    hi = math.ceil(pos)

    if lo == hi:
        return vals[lo]

    return (
        vals[lo] +
        (vals[hi] - vals[lo]) *
        (pos - lo)
    )

revenues = [r["AnnualRevenue"] for r in rows]
employees = [r["NumberOfEmployees"] for r in rows]

print()
print("=" * 68)
print("ACCOUNT V3 PREVIEW")
print("=" * 68)
print(f"Records: {len(rows)}")
print()

print(
    "AnnualRevenue: "
    f"min=${min(revenues):,.0f}, "
    f"p25=${percentile(revenues,.25):,.0f}, "
    f"median=${percentile(revenues,.50):,.0f}, "
    f"p75=${percentile(revenues,.75):,.0f}, "
    f"p90=${percentile(revenues,.90):,.0f}, "
    f"max=${max(revenues):,.0f}, "
    f"mean=${statistics.mean(revenues):,.0f}"
)

print(
    "Employees: "
    f"min={min(employees):,}, "
    f"p25={percentile(employees,.25):,.0f}, "
    f"median={percentile(employees,.50):,.0f}, "
    f"p75={percentile(employees,.75):,.0f}, "
    f"p90={percentile(employees,.90):,.0f}, "
    f"max={max(employees):,}, "
    f"mean={statistics.mean(employees):,.0f}"
)

print()
print("Segments:")

for k, v in Counter(
    r["Customer_Segment__c"] for r in rows
).most_common():
    print(f"  {k}: {v}")

print()
print("Industries:")

for k, v in Counter(
    r["Industry"] for r in rows
).most_common():
    print(f"  {k}: {v}")

print()
print("Regions:")

for k, v in Counter(
    r["Region__c"] for r in rows
).most_common():
    print(f"  {k}: {v}")

print()
print("Sample:")
print(",".join(fields))

for r in rows[:8]:
    print(",".join(str(r[f]) for f in fields))

print()
print("NO SALESFORCE RECORDS WERE MODIFIED.")
PY

# Promote the already-approved V2 Opportunity and Case files into
# the final candidate set without regenerating them.

cp \
  "$V2/Opportunity_updates.csv" \
  "$V3/Opportunity_updates.csv"

cp \
  "$V2/Case_updates.csv" \
  "$V3/Case_updates.csv"

echo
echo "============================================================"
echo "FINAL CANDIDATE SEED SET"
echo "============================================================"
echo
echo "Account V3:"
echo "  $V3/Account_updates.csv"
echo
echo "Opportunity V2:"
echo "  $V3/Opportunity_updates.csv"
echo
echo "Case V2:"
echo "  $V3/Case_updates.csv"
echo
echo "NO SALESFORCE RECORDS WERE MODIFIED."
echo
