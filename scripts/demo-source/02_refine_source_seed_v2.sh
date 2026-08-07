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

if [ -z "$LATEST" ] || [ ! -d "$LATEST" ]; then
  echo "ERROR: No demo-source-seed-* directory found."
  exit 1
fi

RAW="$LATEST/raw"
V2="$LATEST/seed-v2"

mkdir -p "$V2"

for FILE in \
  "$RAW/accounts.csv" \
  "$RAW/opportunities.csv" \
  "$RAW/cases.csv"
do
  if [ ! -f "$FILE" ]; then
    echo "ERROR: Missing $FILE"
    exit 1
  fi
done

echo
echo "============================================================"
echo "OCX DEMO SOURCE DATA - SEED V2"
echo "============================================================"
echo
echo "Using:"
echo "  $LATEST"
echo
echo "NO SALESFORCE RECORDS WILL BE MODIFIED."
echo

python3 - "$LATEST" <<'PY'
import csv
import hashlib
import math
import re
import statistics
import sys
from collections import Counter
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(sys.argv[1])
RAW = ROOT / "raw"
OUT = ROOT / "seed-v2"
OUT.mkdir(exist_ok=True)

ANCHOR_DATE = date(2026, 8, 1)
SALT = "ocx-demo-source-restoration-v2"

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
    digest = hashlib.sha256(
        f"{SALT}|{key}".encode("utf-8")
    ).hexdigest()
    value = int(digest[:16], 16)
    return value if mod is None else value % mod

def h_fraction(key):
    return h_int(key, 1_000_000) / 1_000_000.0

def clean(v):
    return "" if v is None else str(v).strip()

def number(v):
    s = clean(v).replace(",", "").replace("$", "").replace("%", "")
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        m = re.search(r"-?\d+(?:\.\d+)?", s)
        return float(m.group()) if m else None

def boolean(v):
    return clean(v).lower() in ("true", "1", "yes", "y")

def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

def write_csv(path, fields, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

def parse_revenue_band(v):
    """
    Parses common band values such as:
      $10M-$50M
      10M - 50M
      100M+
      <10M
    Returns a representative annual revenue value.
    """
    s = clean(v).upper()

    if not s:
        return None

    matches = re.findall(r"(\d+(?:\.\d+)?)\s*([KMB])", s)

    values = []

    for n, suffix in matches:
        multiplier = {
            "K": 1_000,
            "M": 1_000_000,
            "B": 1_000_000_000,
        }[suffix]

        values.append(float(n) * multiplier)

    if len(values) >= 2:
        return (values[0] + values[1]) / 2

    if len(values) == 1:
        value = values[0]

        if "<" in s:
            return value * 0.65

        if ">" in s or "+" in s:
            return value * 1.4

        return value

    return None

def percentile(values, p):
    vals = sorted(values)

    if not vals:
        return None

    pos = (len(vals) - 1) * p
    lo = math.floor(pos)
    hi = math.ceil(pos)

    if lo == hi:
        return vals[lo]

    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)

# ================================================================
# ACCOUNT
# ================================================================

accounts = read_csv(RAW / "accounts.csv")

account_context = {}
account_updates = []

for r in accounts:

    sfid = r["Id"]

    acv = number(r.get("OCX_ACV__c")) or 0
    tenure = number(r.get("OCX_Tenure__c"))

    country, state, city, region = LOCATIONS[
        h_int(sfid + "|geo", len(LOCATIONS))
    ]

    industry = clean(r.get("Industry"))

    if not industry:
        industry = INDUSTRIES[
            h_int(sfid + "|industry", len(INDUSTRIES))
        ]

    # ------------------------------------------------------------
    # Annual Revenue
    #
    # Preserve an existing standard value only if it looks like
    # actual corporate annual revenue.
    #
    # Otherwise:
    #  1. Prefer a parseable retained revenue band.
    #  2. Fall back to ACV-based corporate revenue.
    #
    # This deliberately avoids the tiny $2K-$20K results seen
    # in the first preview.
    # ------------------------------------------------------------

    existing_revenue = number(r.get("AnnualRevenue"))
    band_revenue = parse_revenue_band(r.get("OCX_Revenue_Band__c"))

    if existing_revenue is not None and existing_revenue >= 500_000:
        annual_revenue = existing_revenue

    elif band_revenue is not None:
        jitter = 0.90 + 0.20 * h_fraction(sfid + "|rev-jitter")
        annual_revenue = band_revenue * jitter

    else:
        base_acv = max(acv, 20_000)

        revenue_multiple = (
            70 +
            h_int(sfid + "|revenue-multiple", 131)
        )

        annual_revenue = max(
            1_000_000,
            base_acv * revenue_multiple
        )

    annual_revenue = round(annual_revenue, -3)

    # ------------------------------------------------------------
    # Employees
    #
    # Derive company size from revenue with variable revenue per
    # employee. Minimum is now 5 rather than producing a giant
    # artificial pile-up at 20.
    # ------------------------------------------------------------

    existing_employees = number(r.get("NumberOfEmployees"))

    if existing_employees is not None and existing_employees > 0:
        employees = int(existing_employees)
    else:
        revenue_per_employee = (
            140_000 +
            h_int(sfid + "|revenue-per-employee", 461_000)
        )

        employees = max(
            5,
            round(annual_revenue / revenue_per_employee)
        )

        employees = min(employees, 100_000)

    # Segment remains coherent with ACV.
    existing_segment = clean(r.get("Customer_Segment__c"))

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

    existing_since = clean(r.get("Customer_Since_Date__c"))

    if existing_since:
        customer_since = existing_since

    else:

        if tenure is None or tenure <= 0:
            tenure = (
                1 +
                h_int(sfid + "|tenure-years", 9) +
                h_fraction(sfid + "|tenure-fraction")
            )

        customer_since = (
            ANCHOR_DATE -
            timedelta(days=max(90, round(tenure * 365.25)))
        ).isoformat()

    billing_country = clean(r.get("BillingCountry")) or country
    billing_state = clean(r.get("BillingState")) or state
    billing_city = clean(r.get("BillingCity")) or city
    final_region = clean(r.get("Region__c")) or region

    product = clean(r.get("OCX_Primary_Product__c"))

    account_context[sfid] = {
        "acv": acv,
        "segment": segment,
        "region": final_region,
        "product": product,
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
    OUT / "Account_updates.csv",
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
    account_updates
)

# ================================================================
# OPPORTUNITY
#
# Diagnostic confirmed this scratch org contains a renewal pipeline:
# 7,618 / 7,618 opportunities are renewal-related.
#
# Treat that as intentional rather than generating fake variation.
# ================================================================

opportunities = read_csv(RAW / "opportunities.csv")

opp_updates = []

for r in opportunities:

    sfid = r["Id"]
    account_id = clean(r.get("AccountId"))
    amount = number(r.get("Amount")) or 0

    # For this demo renewal pipeline:
    #
    # Opportunity Amount = expected renewal commercial value.
    # ARR = renewal ARR.
    # Annual Renewal = same annualized renewal value.
    #
    # No random discount is required.
    arr = round(amount, 2)
    annual_renewal = round(amount, 2)

    territory = clean(r.get("Territory__c"))

    if not territory:
        territory = account_context.get(
            account_id, {}
        ).get("region", "")

    opp_updates.append({
        "Id": sfid,
        "Type": "Renewal",
        "ARR__c": f"{arr:.2f}",
        "Annual_Renewal__c": f"{annual_renewal:.2f}",
        "Territory__c": territory,
    })

write_csv(
    OUT / "Opportunity_updates.csv",
    [
        "Id",
        "Type",
        "ARR__c",
        "Annual_Renewal__c",
        "Territory__c",
    ],
    opp_updates
)

# ================================================================
# CASE / SUPPORT
# ================================================================

cases = read_csv(RAW / "cases.csv")
case_updates = []

def support_level(account_id, key):

    segment = account_context.get(
        account_id, {}
    ).get("segment", "")

    if segment == "Strategic":
        return "Level 2 Paying"

    if segment == "Enterprise":
        return (
            "Level 2 Paying"
            if h_fraction(key + "|support-level") < 0.55
            else "Level 1 Paying"
        )

    if segment == "Mid-Market":
        return (
            "Level 1 Paying"
            if h_fraction(key + "|support-level") < 0.80
            else "Free"
        )

    return (
        "Level 1 Paying"
        if h_fraction(key + "|support-level") < 0.35
        else "Free"
    )

def ttr_days(priority, key):

    f = h_fraction(key + "|ttr")
    p = priority.lower()

    if p == "high":
        return round(0.25 + f * 3.75, 2)

    if p == "medium":
        return round(0.75 + f * 7.25, 2)

    return round(1.5 + f * 13.5, 2)

def open_age(priority, key):

    f = h_fraction(key + "|age")
    p = priority.lower()

    if p == "high":
        return round(1 + f * 13, 2)

    if p == "medium":
        return round(1 + f * 29, 2)

    return round(1 + f * 49, 2)

def sla_threshold(priority, level, is_closed):

    p = priority.lower()

    if is_closed:

        threshold = {
            "high": 3.5,
            "medium": 7.5,
            "low": 15.0,
        }.get(p, 9.0)

    else:

        threshold = {
            "high": 12.0,
            "medium": 25.0,
            "low": 45.0,
        }.get(p, 30.0)

    # Premium customers have tighter service commitments.
    if level == "Level 2 Paying":
        multiplier = 0.80
    elif level == "Level 1 Paying":
        multiplier = 1.00
    else:
        multiplier = 1.35

    return threshold * multiplier

for r in cases:

    sfid = r["Id"]
    account_id = clean(r.get("AccountId"))

    closed = boolean(r.get("IsClosed"))
    priority = clean(r.get("Priority")) or "Medium"

    level = (
        clean(r.get("Support_Level__c"))
        or support_level(account_id, sfid)
    )

    root = clean(r.get("Root_Cause__c"))

    if not root:
        root = ROOT_CAUSES[
            h_int(sfid + "|root", len(ROOT_CAUSES))
        ]

    category = (
        clean(r.get("Support_Category__c"))
        or ROOT_TO_CATEGORY[root]
    )

    product = clean(r.get("Product_Line__c"))

    if not product:
        product = account_context.get(
            account_id, {}
        ).get("product", "")

    if not product:
        product = "Core Platform"

    if closed:

        existing_ttr = number(
            r.get("Time_to_Resolution_Days__c")
        )

        ttr = (
            existing_ttr
            if existing_ttr is not None
            else ttr_days(priority, sfid)
        )

        age = ""
        metric = ttr

    else:

        existing_age = number(
            r.get("Ageing_of_Open_Cases_Days__c")
        )

        age = (
            existing_age
            if existing_age is not None
            else open_age(priority, sfid)
        )

        ttr = ""
        metric = age

    threshold = sla_threshold(
        priority,
        level,
        closed
    )

    violation = metric > threshold

    # ------------------------------------------------------------
    # Escalation
    #
    # Do not equate SLA violation with escalation.
    #
    # Create a restrained distribution based on:
    #   severity
    #   SLA breach
    #   deterministic random component
    #
    # Expected overall rate should be closer to normal operating
    # conditions rather than the prior 32.9%.
    # ------------------------------------------------------------

    p = priority.lower()

    if p == "high":
        base_escalation_probability = 0.12
    elif p == "medium":
        base_escalation_probability = 0.05
    else:
        base_escalation_probability = 0.02

    if violation:
        base_escalation_probability += 0.10

    escalated = (
        h_fraction(sfid + "|escalation") <
        base_escalation_probability
    )

    case_updates.append({
        "Id": sfid,
        "Time_to_Resolution_Days__c":
            f"{ttr:.2f}" if isinstance(ttr, (int, float)) else "",
        "Ageing_of_Open_Cases_Days__c":
            f"{age:.2f}" if isinstance(age, (int, float)) else "",
        "Support_Level__c": level,
        "Root_Cause__c": root,
        "SLA_Violation__c": "true" if violation else "false",
        "Product_Line__c": product,
        "Support_Category__c": category,
        "IsEscalated": "true" if escalated else "false",
    })

write_csv(
    OUT / "Case_updates.csv",
    [
        "Id",
        "Time_to_Resolution_Days__c",
        "Ageing_of_Open_Cases_Days__c",
        "Support_Level__c",
        "Root_Cause__c",
        "SLA_Violation__c",
        "Product_Line__c",
        "Support_Category__c",
        "IsEscalated",
    ],
    case_updates
)

# ================================================================
# PREVIEW
# ================================================================

def stats(values):

    vals = sorted(
        float(v)
        for v in values
        if v not in ("", None)
    )

    if not vals:
        return "none"

    def p(q):
        return percentile(vals, q)

    return (
        f"min={min(vals):,.2f}, "
        f"p25={p(.25):,.2f}, "
        f"median={p(.50):,.2f}, "
        f"p75={p(.75):,.2f}, "
        f"p90={p(.90):,.2f}, "
        f"max={max(vals):,.2f}, "
        f"mean={statistics.mean(vals):,.2f}"
    )

def show_counter(title, values):

    print(title)

    for value, count in Counter(values).most_common():
        print(f"  {value or '(blank)'}: {count}")

print()
print("=" * 70)
print("SEED V2 PREVIEW")
print("=" * 70)

print()
print("ACCOUNT")
print("-------")
print(f"Records: {len(account_updates)}")

print(
    "AnnualRevenue: " +
    stats([r["AnnualRevenue"] for r in account_updates])
)

print(
    "Employees: " +
    stats([r["NumberOfEmployees"] for r in account_updates])
)

show_counter(
    "Segments:",
    [r["Customer_Segment__c"] for r in account_updates]
)

show_counter(
    "Regions:",
    [r["Region__c"] for r in account_updates]
)

print()
print("OPPORTUNITY")
print("-----------")
print(f"Records: {len(opp_updates)}")

show_counter(
    "Type:",
    [r["Type"] for r in opp_updates]
)

print(
    "ARR: " +
    stats([r["ARR__c"] for r in opp_updates])
)

print()
print("CASE")
print("----")
print(f"Records: {len(case_updates)}")

show_counter(
    "Support Level:",
    [r["Support_Level__c"] for r in case_updates]
)

sla_count = sum(
    1 for r in case_updates
    if r["SLA_Violation__c"] == "true"
)

esc_count = sum(
    1 for r in case_updates
    if r["IsEscalated"] == "true"
)

print(
    f"SLA violations: {sla_count}/{len(case_updates)} "
    f"({sla_count/len(case_updates)*100:.1f}%)"
)

print(
    f"Escalations: {esc_count}/{len(case_updates)} "
    f"({esc_count/len(case_updates)*100:.1f}%)"
)

print(
    "Closed-case TTR: " +
    stats([
        r["Time_to_Resolution_Days__c"]
        for r in case_updates
    ])
)

print(
    "Open-case ageing: " +
    stats([
        r["Ageing_of_Open_Cases_Days__c"]
        for r in case_updates
    ])
)

print()
print("NO SALESFORCE RECORDS WERE MODIFIED.")
print()
PY

echo
echo "============================================================"
echo "SAMPLES"
echo "============================================================"

echo
echo "ACCOUNT"
head -n 8 "$V2/Account_updates.csv"

echo
echo "OPPORTUNITY"
head -n 8 "$V2/Opportunity_updates.csv"

echo
echo "CASE"
head -n 8 "$V2/Case_updates.csv"

echo
echo "============================================================"
echo "SEED V2 GENERATED"
echo "============================================================"
echo
echo "NO SALESFORCE RECORDS WERE MODIFIED."
echo
echo "Files:"
echo "  $V2/Account_updates.csv"
echo "  $V2/Opportunity_updates.csv"
echo "  $V2/Case_updates.csv"
echo
