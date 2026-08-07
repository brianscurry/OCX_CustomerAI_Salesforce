#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-preflight}"

if [ "$MODE" != "preflight" ] && [ "$MODE" != "apply" ]; then
  echo "Usage:"
  echo "  $0 preflight"
  echo "  $0 apply"
  exit 1
fi

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
API_VERSION="${API_VERSION:-67.0}"

cd "$PROJECT"

for CMD in sf jq python3; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD"
    exit 1
  fi
done

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

SEED="$LATEST/seed-v3"
RAW="$LATEST/raw"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$LATEST/apply-$STAMP"

mkdir -p \
  "$OUT/describes" \
  "$OUT/prepared" \
  "$OUT/rollback" \
  "$OUT/results" \
  "$OUT/logs"

for FILE in \
  "$SEED/Account_updates.csv" \
  "$SEED/Opportunity_updates.csv" \
  "$SEED/Case_updates.csv" \
  "$RAW/accounts.csv" \
  "$RAW/opportunities.csv" \
  "$RAW/cases.csv"
do
  if [ ! -f "$FILE" ]; then
    echo "ERROR: Missing required file:"
    echo "  $FILE"
    exit 1
  fi
done

echo
echo "============================================================"
echo "OCX DEMO SOURCE DATA - $MODE"
echo "============================================================"
echo "Org:      $ORG"
echo "Seed:     $SEED"
echo "Output:   $OUT"
echo "============================================================"
echo

# ------------------------------------------------------------------
# 1. Capture live object metadata.
# ------------------------------------------------------------------

echo "[1/6] Reading live Salesforce metadata..."

for OBJ in Account Opportunity Case; do
  echo "  Describe: $OBJ"

  sf sobject describe \
    --target-org "$ORG" \
    --sobject "$OBJ" \
    --api-version "$API_VERSION" \
    --json \
    > "$OUT/describes/${OBJ}.json"
done

# ------------------------------------------------------------------
# 2. Preflight CSVs against live schema and prepare final files.
# ------------------------------------------------------------------

echo
echo "[2/6] Validating and preparing CSV files..."

python3 - "$LATEST" "$OUT" <<'PY'
import csv
import json
import sys
from pathlib import Path

ROOT = Path(sys.argv[1])
OUT = Path(sys.argv[2])

SEED = ROOT / "seed-v3"
RAW = ROOT / "raw"
DESC = OUT / "describes"
PREP = OUT / "prepared"
ROLLBACK = OUT / "rollback"

PREP.mkdir(exist_ok=True)
ROLLBACK.mkdir(exist_ok=True)

OBJECTS = {
    "Account": {
        "seed": SEED / "Account_updates.csv",
        "raw": RAW / "accounts.csv",
        "prepared": PREP / "Account_updates.csv",
        "rollback": ROLLBACK / "Account_rollback.csv",
    },
    "Opportunity": {
        "seed": SEED / "Opportunity_updates.csv",
        "raw": RAW / "opportunities.csv",
        "prepared": PREP / "Opportunity_updates.csv",
        "rollback": ROLLBACK / "Opportunity_rollback.csv",
    },
    "Case": {
        "seed": SEED / "Case_updates.csv",
        "raw": RAW / "cases.csv",
        "prepared": PREP / "Case_updates.csv",
        "rollback": ROLLBACK / "Case_rollback.csv",
    },
}

# Semantic mapping used only if our anonymized Account industry
# labels don't exactly match this org's standard Salesforce picklist.
INDUSTRY_EQUIVALENTS = {
    "Financial Services": ["Finance", "Banking", "Insurance"],
    "Professional Services": ["Consulting"],
    "Business Services": ["Consulting"],
    "Consumer Products": ["Retail", "Manufacturing"],
    "Technology": ["Technology"],
    "Healthcare": ["Healthcare"],
    "Manufacturing": ["Manufacturing"],
    "Retail": ["Retail"],
    "Telecommunications": ["Telecommunications", "Communications"],
    "Media": ["Media", "Entertainment"],
    "Energy": ["Energy", "Utilities"],
    "Transportation": ["Transportation", "Shipping"],
}

def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))

def write_csv(path, fieldnames, rows):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=fieldnames,
            extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(rows)

def describe(object_name):
    with open(DESC / f"{object_name}.json", encoding="utf-8") as fh:
        data = json.load(fh)

    fields = {}

    for f in data["result"]["fields"]:
        fields[f["name"]] = f

    return fields

def active_picklist_values(meta):
    return [
        p["value"]
        for p in meta.get("picklistValues", [])
        if p.get("active", True)
    ]

def validate_ids(object_name, rows):
    ids = [r.get("Id", "").strip() for r in rows]

    if not ids or any(not i for i in ids):
        raise RuntimeError(
            f"{object_name}: blank Id detected"
        )

    if len(ids) != len(set(ids)):
        raise RuntimeError(
            f"{object_name}: duplicate Id detected"
        )

def validate_columns(object_name, rows, fields):
    if not rows:
        raise RuntimeError(
            f"{object_name}: CSV contains no rows"
        )

    columns = list(rows[0].keys())

    if columns[0] != "Id":
        raise RuntimeError(
            f"{object_name}: first CSV column must be Id"
        )

    for col in columns:
        if col == "Id":
            continue

        if col not in fields:
            raise RuntimeError(
                f"{object_name}.{col}: field not found in live org"
            )

        if not fields[col].get("updateable", False):
            raise RuntimeError(
                f"{object_name}.{col}: field is not updateable"
            )

def normalize_account_industry(rows, fields):
    if "Industry" not in fields:
        return

    meta = fields["Industry"]

    if meta.get("type") != "picklist":
        return

    allowed = active_picklist_values(meta)

    if not allowed:
        return

    allowed_lookup = {
        v.lower(): v
        for v in allowed
    }

    replacements = {}

    for row in rows:
        original = row.get("Industry", "").strip()

        if not original:
            continue

        if original.lower() in allowed_lookup:
            row["Industry"] = allowed_lookup[original.lower()]
            continue

        replacement = None

        for candidate in INDUSTRY_EQUIVALENTS.get(original, []):
            if candidate.lower() in allowed_lookup:
                replacement = allowed_lookup[candidate.lower()]
                break

        if replacement is None and "other" in allowed_lookup:
            replacement = allowed_lookup["other"]

        if replacement is None:
            raise RuntimeError(
                "Account.Industry value is invalid and no safe "
                f"mapping exists: {original!r}. "
                f"Allowed values: {allowed}"
            )

        replacements[original] = replacement
        row["Industry"] = replacement

    if replacements:
        print()
        print("Account Industry normalization:")
        for src, dest in sorted(replacements.items()):
            print(f"  {src} -> {dest}")

def normalize_opportunity_type(rows, fields):
    """
    If Renewal is not an accepted Type picklist value,
    remove Type from the update entirely. We already know these
    opportunities represent the renewal pipeline.
    """
    if "Type" not in fields:
        return rows

    meta = fields["Type"]

    if meta.get("type") != "picklist":
        return rows

    allowed = active_picklist_values(meta)

    if not allowed:
        return rows

    renewal_allowed = any(
        v.lower() == "renewal"
        for v in allowed
    )

    if renewal_allowed:
        canonical = next(
            v for v in allowed
            if v.lower() == "renewal"
        )

        for row in rows:
            if "Type" in row:
                row["Type"] = canonical

        print()
        print(
            f"Opportunity.Type: using valid picklist value "
            f"{canonical!r}"
        )

        return rows

    print()
    print(
        "Opportunity.Type='Renewal' is NOT an allowed value "
        "in this org."
    )
    print("Type will NOT be modified.")
    print("Allowed Opportunity.Type values:")
    for value in allowed:
        print(f"  {value}")

    for row in rows:
        row.pop("Type", None)

    return rows

def validate_picklists(object_name, rows, fields):
    if not rows:
        return

    columns = rows[0].keys()

    for col in columns:
        if col == "Id":
            continue

        meta = fields[col]

        if meta.get("type") not in (
            "picklist",
            "multipicklist",
        ):
            continue

        allowed = active_picklist_values(meta)

        if not allowed:
            continue

        allowed_set = set(allowed)

        invalid = sorted({
            row.get(col, "").strip()
            for row in rows
            if row.get(col, "").strip()
            and row.get(col, "").strip() not in allowed_set
        })

        if invalid:
            raise RuntimeError(
                f"{object_name}.{col}: invalid picklist "
                f"value(s): {invalid}. Allowed: {allowed}"
            )

def make_rollback(object_name, raw_rows, prepared_fields, output):
    """
    Build a reversal file containing the pre-update values for exactly
    the fields this run will modify.
    """
    raw_by_id = {
        r["Id"]: r
        for r in raw_rows
    }

    rollback_rows = []

    for sfid, raw in raw_by_id.items():
        row = {"Id": sfid}

        for field in prepared_fields:
            if field == "Id":
                continue

            row[field] = raw.get(field, "")

        rollback_rows.append(row)

    write_csv(
        output,
        prepared_fields,
        rollback_rows
    )

expected_counts = {}

for object_name, cfg in OBJECTS.items():
    fields = describe(object_name)
    rows = read_csv(cfg["seed"])
    raw_rows = read_csv(cfg["raw"])

    validate_ids(object_name, rows)
    validate_columns(object_name, rows, fields)

    if object_name == "Account":
        normalize_account_industry(rows, fields)

    if object_name == "Opportunity":
        rows = normalize_opportunity_type(rows, fields)

    # Column set may have changed after Type removal.
    prepared_fields = list(rows[0].keys())

    # Revalidate the resulting columns.
    validate_columns(object_name, rows, fields)
    validate_picklists(object_name, rows, fields)

    if len(rows) != len(raw_rows):
        raise RuntimeError(
            f"{object_name}: seed/raw row-count mismatch: "
            f"{len(rows)} vs {len(raw_rows)}"
        )

    expected_counts[object_name] = len(rows)

    write_csv(
        cfg["prepared"],
        prepared_fields,
        rows
    )

    make_rollback(
        object_name,
        raw_rows,
        prepared_fields,
        cfg["rollback"]
    )

    print()
    print(
        f"{object_name}: PREPARED {len(rows)} records"
    )
    print(
        "  Fields: " +
        ", ".join(prepared_fields)
    )

# Additional semantic integrity checks for Case.
cases = read_csv(OBJECTS["Case"]["prepared"])

bad_closed = 0
bad_open = 0

for r in cases:
    ttr = r.get("Time_to_Resolution_Days__c", "").strip()
    age = r.get("Ageing_of_Open_Cases_Days__c", "").strip()

    # Seed semantics make these mutually exclusive.
    if ttr and age:
        bad_closed += 1

    if not ttr and not age:
        bad_open += 1

if bad_closed:
    raise RuntimeError(
        f"Case: {bad_closed} rows contain BOTH TTR and open ageing"
    )

if bad_open:
    raise RuntimeError(
        f"Case: {bad_open} rows contain neither TTR nor open ageing"
    )

print()
print("=" * 68)
print("PREPARED DATA VALIDATION PASSED")
print("=" * 68)

for obj, count in expected_counts.items():
    print(f"{obj}: {count:,} records")

print()
print("Rollback CSVs were also generated from the pre-update exports.")
PY

echo
echo "[3/6] Prepared file row counts..."

for FILE in \
  "$OUT/prepared/Account_updates.csv" \
  "$OUT/prepared/Opportunity_updates.csv" \
  "$OUT/prepared/Case_updates.csv"
do
  echo "  $(basename "$FILE"): $(( $(wc -l < "$FILE") - 1 ))"
done

echo
echo "Prepared CSV hashes:"
shasum -a 256 "$OUT"/prepared/*.csv | tee "$OUT/prepared-sha256.txt"

echo
echo "Rollback CSV hashes:"
shasum -a 256 "$OUT"/rollback/*.csv | tee "$OUT/rollback-sha256.txt"

# ------------------------------------------------------------------
# Preflight mode stops here.
# ------------------------------------------------------------------

if [ "$MODE" = "preflight" ]; then
  echo
  echo "============================================================"
  echo "PREFLIGHT SUCCEEDED"
  echo "============================================================"
  echo
  echo "NO SALESFORCE RECORDS WERE MODIFIED."
  echo
  echo "Prepared files:"
  echo "  $OUT/prepared/Account_updates.csv"
  echo "  $OUT/prepared/Opportunity_updates.csv"
  echo "  $OUT/prepared/Case_updates.csv"
  echo
  echo "Rollback snapshots:"
  echo "  $OUT/rollback/"
  echo
  echo "To apply the exact same source seed set, run:"
  echo
  echo "  /tmp/09_apply_ocx_demo_source_seed.sh apply"
  echo
  exit 0
fi

# ------------------------------------------------------------------
# 4. Bulk update records.
# ------------------------------------------------------------------

echo
echo "[4/6] APPLY MODE - updating Salesforce records..."
echo
echo "THIS WILL MODIFY OCXDemo."
echo

bulk_update() {
  local OBJ="$1"
  local FILE="$2"

  local OBJ_DIR="$OUT/results/$OBJ"
  local JSON="$OUT/${OBJ}-bulk-update.json"
  local ERR="$OUT/logs/${OBJ}-bulk-update.err"

  mkdir -p "$OBJ_DIR"

  echo
  echo "------------------------------------------------------------"
  echo "Updating $OBJ"
  echo "File: $FILE"
  echo "------------------------------------------------------------"

  set +e

  sf data update bulk \
    --target-org "$ORG" \
    --api-version "$API_VERSION" \
    --sobject "$OBJ" \
    --file "$FILE" \
    --line-ending CRLF \
    --wait 20 \
    --json \
    > "$JSON" \
    2> "$ERR"

  STATUS=$?

  set -e

  cat "$JSON"

  if [ -s "$ERR" ]; then
    echo
    echo "CLI stderr:"
    cat "$ERR"
  fi

  if [ "$STATUS" -ne 0 ]; then
    echo
    echo "ERROR: $OBJ bulk update command failed."
    echo "Stopping before the next object."
    exit "$STATUS"
  fi

  JOB_ID="$(
    jq -r '
      [
        ..
        | strings
        | select(
            test("^750[[:alnum:]]{12,15}$")
          )
      ][0] // empty
    ' "$JSON"
  )"

  if [ -n "$JOB_ID" ]; then
    echo
    echo "Bulk job ID: $JOB_ID"
    echo "Retrieving full Bulk API result..."

    (
      cd "$OBJ_DIR"

      sf data bulk results \
        --target-org "$ORG" \
        --api-version "$API_VERSION" \
        --job-id "$JOB_ID" \
        --json \
        > bulk-results.json \
        2> bulk-results.err
    )

    cat "$OBJ_DIR/bulk-results.json"

    if [ -s "$OBJ_DIR/bulk-results.err" ]; then
      cat "$OBJ_DIR/bulk-results.err"
    fi
  else
    echo
    echo "NOTE: No Bulk job ID was extracted from CLI JSON."
    echo "The command itself returned success."
  fi
}

bulk_update \
  "Account" \
  "$OUT/prepared/Account_updates.csv"

bulk_update \
  "Opportunity" \
  "$OUT/prepared/Opportunity_updates.csv"

bulk_update \
  "Case" \
  "$OUT/prepared/Case_updates.csv"

# ------------------------------------------------------------------
# 5. Verify live Salesforce population.
# ------------------------------------------------------------------

echo
echo "[5/6] Verifying live Salesforce data..."

count_query() {
  local LABEL="$1"
  local QUERY="$2"

  RESULT="$(
    sf data query \
      --target-org "$ORG" \
      --api-version "$API_VERSION" \
      --query "$QUERY" \
      --json
  )"

  COUNT="$(
    printf '%s' "$RESULT" \
      | jq -r '
          .result.records[0].expr0
          // .result.totalSize
          // 0
        '
  )"

  printf "%-46s %s\n" "$LABEL" "$COUNT"
}

echo
echo "ACCOUNT"
count_query \
  "Accounts with Industry:" \
  "SELECT count() FROM Account WHERE Industry != null"

count_query \
  "Accounts with AnnualRevenue:" \
  "SELECT count() FROM Account WHERE AnnualRevenue != null"

count_query \
  "Accounts with Employees:" \
  "SELECT count() FROM Account WHERE NumberOfEmployees != null"

count_query \
  "Accounts with Customer Since:" \
  "SELECT count() FROM Account WHERE Customer_Since_Date__c != null"

count_query \
  "Accounts with Segment:" \
  "SELECT count() FROM Account WHERE Customer_Segment__c != null"

count_query \
  "Accounts with Region:" \
  "SELECT count() FROM Account WHERE Region__c != null"

echo
echo "OPPORTUNITY"
count_query \
  "Opportunities with ARR:" \
  "SELECT count() FROM Opportunity WHERE ARR__c != null"

count_query \
  "Opportunities with Annual Renewal:" \
  "SELECT count() FROM Opportunity WHERE Annual_Renewal__c != null"

count_query \
  "Opportunities with Territory:" \
  "SELECT count() FROM Opportunity WHERE Territory__c != null"

echo
echo "CASE"
count_query \
  "Closed Cases with TTR:" \
  "SELECT count() FROM Case WHERE IsClosed = true AND Time_to_Resolution_Days__c != null"

count_query \
  "Open Cases with ageing:" \
  "SELECT count() FROM Case WHERE IsClosed = false AND Ageing_of_Open_Cases_Days__c != null"

count_query \
  "Cases with Support Level:" \
  "SELECT count() FROM Case WHERE Support_Level__c != null"

count_query \
  "Cases with Root Cause:" \
  "SELECT count() FROM Case WHERE Root_Cause__c != null"

count_query \
  "Cases with Product Line:" \
  "SELECT count() FROM Case WHERE Product_Line__c != null"

count_query \
  "SLA violations:" \
  "SELECT count() FROM Case WHERE SLA_Violation__c = true"

count_query \
  "Escalated cases:" \
  "SELECT count() FROM Case WHERE IsEscalated = true"

# ------------------------------------------------------------------
# 6. Query representative samples.
# ------------------------------------------------------------------

echo
echo "[6/6] Representative live samples..."

echo
echo "ACCOUNT SAMPLE"
sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      Name,
      Industry,
      AnnualRevenue,
      NumberOfEmployees,
      BillingCountry,
      Customer_Segment__c,
      Region__c,
      Customer_Since_Date__c
    FROM Account
    WHERE Industry != null
    LIMIT 5
  "

echo
echo "OPPORTUNITY SAMPLE"
sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      Name,
      Type,
      Amount,
      ARR__c,
      Annual_Renewal__c,
      Territory__c,
      Probability,
      CloseDate
    FROM Opportunity
    WHERE ARR__c != null
    LIMIT 5
  "

echo
echo "CASE SAMPLE"
sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      CaseNumber,
      Status,
      Priority,
      IsEscalated,
      Time_to_Resolution_Days__c,
      Ageing_of_Open_Cases_Days__c,
      Support_Level__c,
      Root_Cause__c,
      SLA_Violation__c,
      Product_Line__c,
      Support_Category__c
    FROM Case
    WHERE Support_Level__c != null
    LIMIT 5
  "

echo
echo "============================================================"
echo "OCX DEMO SOURCE DATA UPGRADE COMPLETE"
echo "============================================================"
echo
echo "Output:"
echo "  $OUT"
echo
echo "Rollback CSVs:"
echo "  $OUT/rollback/"
echo
echo "Git status was not modified by this script."
echo "============================================================"
