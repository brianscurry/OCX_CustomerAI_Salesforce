#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
MODE="${1:-preflight}"

cd "$PROJECT"

RUN_ROOT="$PROJECT/.ocx/profile-anonymization-repair"
mkdir -p "$RUN_ROOT"

PERSON_FIELDS="
Source_Owner_Name__c
Customer_Manager_Name__c
Territory_Manager_Name__c
Renewals_Manager_Name__c
New_Account_Owner__c
Previous_Account_Owner__c
"

echo
echo "============================================================"
echo "OCX ACCOUNT PROFILE - BONGO ANONYMIZATION REPAIR"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Mode:    $MODE"
echo
echo "Rules:"
echo "  - Authoritative demo population: Account.OCX_Account_ID__c != null"
echo "  - Expected demo Accounts: 7,755"
echo "  - Account Name and OCX Account ID are NEVER modified"
echo "  - Prototype people are replaced with fixed demo identities"
echo "  - Product labels use ONLY the approved Bongo mappings"
echo "  - Forbidden legacy product labels are rejected after repair"
echo "============================================================"
echo

build_preflight() {
  STAMP="$(date +%Y%m%d_%H%M%S)"
  RUN_DIR="$RUN_ROOT/$STAMP"
  mkdir -p "$RUN_DIR"

  echo "[1/5] Describing live Account schema..."

  sf sobject describe \
    --sobject Account \
    --target-org "$ORG" \
    --json \
    > "$RUN_DIR/account-describe.json"

  python3 - "$RUN_DIR/account-describe.json" "$RUN_DIR/fields.env" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text())
if isinstance(doc, dict) and "result" in doc:
    doc = doc["result"]

fields = {f["name"]: f for f in doc.get("fields", [])}

required = [
    "Id",
    "Name",
    "OCX_Account_ID__c",
    "Product_Family_List__c",
    "Source_Owner_Name__c",
    "Customer_Manager_Name__c",
    "Territory_Manager_Name__c",
    "Renewals_Manager_Name__c",
    "New_Account_Owner__c",
    "Previous_Account_Owner__c",
]

missing = [f for f in required if f not in fields]
if missing:
    raise SystemExit("ERROR: Missing Account fields: " + ", ".join(missing))

not_updateable = [
    f for f in required
    if f not in {"Id", "Name", "OCX_Account_ID__c"}
    and not fields[f].get("updateable", False)
]
if not_updateable:
    raise SystemExit("ERROR: Fields are not updateable: " + ", ".join(not_updateable))

optional_primary = (
    "OCX_Primary_Product__c"
    if "OCX_Primary_Product__c" in fields
    and fields["OCX_Primary_Product__c"].get("updateable", False)
    else ""
)

Path(sys.argv[2]).write_text(
    f'OPTIONAL_PRIMARY_PRODUCT="{optional_primary}"\n'
)

print("  Required repair fields exist and are updateable.")
if optional_primary:
    print("  Optional product field found: OCX_Primary_Product__c")
PY

  # shellcheck disable=SC1090
  . "$RUN_DIR/fields.env"

  QUERY_FIELDS="Id,Name,OCX_Account_ID__c,Product_Family_List__c,Source_Owner_Name__c,Customer_Manager_Name__c,Territory_Manager_Name__c,Renewals_Manager_Name__c,New_Account_Owner__c,Previous_Account_Owner__c"

  if [ -n "${OPTIONAL_PRIMARY_PRODUCT:-}" ]; then
    QUERY_FIELDS="$QUERY_FIELDS,$OPTIONAL_PRIMARY_PRODUCT"
  fi

  echo
  echo "[2/5] Exporting the 7,755 authoritative demo Accounts..."

  sf data query \
    --target-org "$ORG" \
    --query "SELECT $QUERY_FIELDS FROM Account WHERE OCX_Account_ID__c != null ORDER BY Name" \
    --result-format csv \
    --output-file "$RUN_DIR/live_before.csv"

  echo
  echo "[3/5] Building minimal repair + rollback CSVs..."

  python3 - \
    "$RUN_DIR/live_before.csv" \
    "$RUN_DIR/account_updates.csv" \
    "$RUN_DIR/account_rollback.csv" \
    "$RUN_DIR/preflight-summary.json" <<'PY'
import csv
import json
import re
import sys
from collections import Counter
from pathlib import Path

src = Path(sys.argv[1])
update_path = Path(sys.argv[2])
rollback_path = Path(sys.argv[3])
summary_path = Path(sys.argv[4])

EXPECTED_ACCOUNTS = 7755

# Exact approved Bongo product-family mappings.
PRODUCT_MAP = {
    "Contracts": "Agreements",
    "Commerce & Revenue": "Commercial Operations",
    "Core Apps": "Platform Services",
    "CPQ": "QuoteFlow",
    "CLM": "Contracta",
    "Digital Docs": "Docstream",

    # Exact approved product-name mappings.
    "Conga Composer": "Write Up",
    "Conga Sign": "Sign Here",
    "Conga Grid": "Matrix",
    "Conga X-Author": "Write Up Enterprise",
    "Conga X-Author Enterprise": "Write Up Enterprise",
    "Conga Orchestrate": "Conductor",
    "Conga Billing": "Billing",
    "Conga Collaborate": "Collab",
    "Conga Digital Commerce": "Online Seller",
    "Conga Order Management": "Order Pro",
    "Other": "Other",
    "Support": "Support",

    # Previously observed branded variants that map directly to the
    # approved family labels.
    "Conga Contracts": "Agreements",
    "Conga CPQ": "QuoteFlow",
    "Conga CLM": "Contracta",
}

DEMO_PRODUCT_LABELS = set(PRODUCT_MAP.values())

PERSON_VALUES = {
    "Source_Owner_Name__c": "Marcus Webb",
    "Customer_Manager_Name__c": "Sarah Chen",
    "Territory_Manager_Name__c": "Marcus Webb",
    "Renewals_Manager_Name__c": "Jennifer Park",
    "New_Account_Owner__c": "Marcus Webb",
    "Previous_Account_Owner__c": "Jennifer Park",
}

with src.open("r", encoding="utf-8-sig", newline="") as f:
    rows = list(csv.DictReader(f))

if len(rows) != EXPECTED_ACCOUNTS:
    raise SystemExit(
        f"ERROR: Expected {EXPECTED_ACCOUNTS} authoritative demo Accounts; "
        f"query returned {len(rows)}."
    )

if len({r["Id"] for r in rows}) != EXPECTED_ACCOUNTS:
    raise SystemExit("ERROR: Duplicate Salesforce Account IDs detected.")

if any(not (r.get("OCX_Account_ID__c") or "").strip() for r in rows):
    raise SystemExit("ERROR: Authoritative Account query returned a blank OCX Account ID.")

optional_primary = (
    "OCX_Primary_Product__c"
    if rows and "OCX_Primary_Product__c" in rows[0]
    else None
)

source_token_accounts = Counter()
unknown_token_accounts = Counter()
changed_product_accounts = 0
changed_primary_accounts = 0

# Split common multi-value delimiters. We canonicalize back to "; ".
splitter = re.compile(r"\s*[;,|]\s*")

def map_product_list(value):
    global changed_product_accounts
    raw = (value or "").strip()
    if not raw:
        return ""

    tokens = [t.strip() for t in splitter.split(raw) if t.strip()]
    mapped = []
    unknown = []

    for token in tokens:
        source_token_accounts[token] += 1

        if token in PRODUCT_MAP:
            mapped.append(PRODUCT_MAP[token])
        elif token in DEMO_PRODUCT_LABELS:
            # Makes the repair idempotent.
            mapped.append(token)
        else:
            unknown.append(token)
            unknown_token_accounts[token] += 1

    if unknown:
        return None

    # Preserve order while removing duplicate mapped labels.
    deduped = []
    seen = set()
    for token in mapped:
        if token not in seen:
            deduped.append(token)
            seen.add(token)

    return "; ".join(deduped)

def map_single_product(value):
    raw = (value or "").strip()
    if not raw:
        return ""
    if raw in PRODUCT_MAP:
        return PRODUCT_MAP[raw]
    if raw in DEMO_PRODUCT_LABELS:
        return raw
    unknown_token_accounts[raw] += 1
    return None

updates = []
rollbacks = []

for row in rows:
    new_product_list = map_product_list(row.get("Product_Family_List__c"))

    if new_product_list is None:
        continue

    if new_product_list != (row.get("Product_Family_List__c") or "").strip():
        changed_product_accounts += 1

    update = {
        "Id": row["Id"],
        "Product_Family_List__c": new_product_list if new_product_list else "#N/A",
    }

    rollback = {
        "Id": row["Id"],
        "Product_Family_List__c":
            (row.get("Product_Family_List__c") or "").strip() or "#N/A",
    }

    for field, demo_name in PERSON_VALUES.items():
        update[field] = demo_name
        rollback[field] = (row.get(field) or "").strip() or "#N/A"

    if optional_primary:
        new_primary = map_single_product(row.get(optional_primary))
        if new_primary is None:
            continue

        old_primary = (row.get(optional_primary) or "").strip()
        if new_primary != old_primary:
            changed_primary_accounts += 1

        update[optional_primary] = new_primary if new_primary else "#N/A"
        rollback[optional_primary] = old_primary or "#N/A"

    updates.append(update)
    rollbacks.append(rollback)

# Fail closed if there are any source product tokens for which the user has
# not supplied a mapping.
if unknown_token_accounts:
    print()
    print("UNRESOLVED PRODUCT LABELS - NO UPDATE FILE WILL BE APPROVED")
    print("----------------------------------------------------------")
    for token, count in sorted(
        unknown_token_accounts.items(),
        key=lambda x: (-x[1], x[0].casefold())
    ):
        print(f"{count:5d} Accounts  {token}")
    raise SystemExit(
        "\nERROR: Unresolved product labels remain. "
        "Add explicit mappings before applying."
    )

if len(updates) != EXPECTED_ACCOUNTS:
    raise SystemExit(
        f"ERROR: Repair output contains {len(updates)} rows; "
        f"expected {EXPECTED_ACCOUNTS}."
    )

fieldnames = ["Id", "Product_Family_List__c", *PERSON_VALUES.keys()]
if optional_primary:
    fieldnames.append(optional_primary)

for path, data in [
    (update_path, updates),
    (rollback_path, rollbacks),
]:
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=fieldnames,
            lineterminator="\n",
        )
        w.writeheader()
        w.writerows(data)

# Validate generated output for brand leakage and person-field consistency.
for row in updates:
    for field, value in row.items():
        text = str(value or "")
        if re.search(r"\b(Conga|Mar(?:umba))\b", text, flags=re.I):
            raise SystemExit(
                f"ERROR: Forbidden demo brand leakage remains in "
                f"{field}: {text!r}"
            )

    for field, expected in PERSON_VALUES.items():
        if row[field] != expected:
            raise SystemExit(
                f"ERROR: {field} does not contain the approved demo identity."
            )

summary = {
    "authoritative_demo_accounts": len(rows),
    "repair_rows": len(updates),
    "product_family_list_accounts_changed": changed_product_accounts,
    "primary_product_accounts_changed": changed_primary_accounts,
    "person_fields_replaced": PERSON_VALUES,
    "product_source_tokens_observed": dict(
        sorted(source_token_accounts.items())
    ),
    "unresolved_product_labels": 0,
    "forbidden_brand_leaks_in_generated_output": 0,
    "account_name_will_be_updated": False,
    "ocx_account_id_will_be_updated": False,
}

summary_path.write_text(json.dumps(summary, indent=2) + "\n")

print()
print("PREFLIGHT SUMMARY")
print("-----------------")
print(f"authoritative_demo_accounts:            {len(rows)}")
print(f"repair_rows:                            {len(updates)}")
print(f"product_family_list_accounts_changed:   {changed_product_accounts}")
if optional_primary:
    print(f"primary_product_accounts_changed:       {changed_primary_accounts}")
print(f"unresolved_product_labels:              0")
print(f"forbidden_brand_leaks_generated:        0")
print(f"account_name_will_be_updated:           false")
print(f"ocx_account_id_will_be_updated:         false")

print()
print("PERSON FIELD REPLACEMENTS")
print("-------------------------")
for field, name in PERSON_VALUES.items():
    print(f"{field:32s} -> {name}")

print()
print("PRODUCT TOKEN MAPPING INVENTORY")
print("-------------------------------")
for token, count in sorted(
    source_token_accounts.items(),
    key=lambda x: (-x[1], x[0].casefold())
):
    mapped = PRODUCT_MAP.get(token, token)
    print(f"{count:5d} Accounts  {token} -> {mapped}")
PY

  echo
  echo "[4/5] Verifying generated CSV safety..."

  python3 - "$RUN_DIR/account_updates.csv" <<'PY'
import csv
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])

with path.open("r", encoding="utf-8", newline="") as f:
    rows = list(csv.DictReader(f))

if len(rows) != 7755:
    raise SystemExit(f"ERROR: Update CSV has {len(rows)} rows, expected 7755.")

headers = rows[0].keys()
if "Name" in headers or "OCX_Account_ID__c" in headers:
    raise SystemExit(
        "ERROR: Update CSV contains protected Account identity fields."
    )

bad = []
for i, row in enumerate(rows, start=2):
    for field, value in row.items():
        if re.search(r"\b(Conga|Mar(?:umba))\b", value or "", re.I):
            bad.append((i, field, value))

if bad:
    raise SystemExit(
        "ERROR: Forbidden product/brand labels remain in generated CSV."
    )

print("  7,755 repair rows.")
print("  Protected Account identity fields absent.")
print("  No forbidden legacy labels in generated values.")
PY

  touch "$RUN_DIR/PRECHECK_OK"

  echo
  echo "[5/5] Preflight artifacts..."
  echo
  echo "Before snapshot:"
  echo "  $RUN_DIR/live_before.csv"
  echo
  echo "Update CSV:"
  echo "  $RUN_DIR/account_updates.csv"
  echo
  echo "Rollback CSV:"
  echo "  $RUN_DIR/account_rollback.csv"
  echo
  echo "Summary:"
  echo "  $RUN_DIR/preflight-summary.json"
  echo
  echo "============================================================"
  echo "PREFLIGHT PASSED"
  echo "============================================================"
  echo
  echo "NO SALESFORCE RECORDS WERE MODIFIED."
  echo
  echo "To apply this exact preflight:"
  echo "  $0 apply"
  echo
}

latest_preflight_dir() {
  find "$RUN_ROOT" \
    -type f \
    -name PRECHECK_OK \
    -print 2>/dev/null \
  | sed 's#/PRECHECK_OK$##' \
  | sort \
  | tail -1
}

verify_run() {
  RUN_DIR="$1"

  if [ ! -f "$RUN_DIR/account_updates.csv" ]; then
    echo "ERROR: Missing expected update CSV in $RUN_DIR"
    exit 1
  fi

  echo
  echo "[VERIFY 1/2] Reading repaired values back from Salesforce..."

  HEADER="$(head -1 "$RUN_DIR/account_updates.csv")"
  QUERY_FIELDS="$(printf '%s' "$HEADER" | sed 's/^Id,/Id,Name,OCX_Account_ID__c,/')"

  sf data query \
    --target-org "$ORG" \
    --query "SELECT $QUERY_FIELDS FROM Account WHERE OCX_Account_ID__c != null ORDER BY Name" \
    --result-format csv \
    --output-file "$RUN_DIR/live_after.csv"

  echo
  echo "[VERIFY 2/2] Comparing all repaired values..."

  python3 - \
    "$RUN_DIR/account_updates.csv" \
    "$RUN_DIR/live_after.csv" \
    "$RUN_DIR/verification-summary.json" <<'PY'
import csv
import json
import re
import sys
from pathlib import Path

expected_path = Path(sys.argv[1])
live_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])

def read(path):
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

expected = read(expected_path)
live = read(live_path)

expected_by_id = {r["Id"]: r for r in expected}
live_by_id = {r["Id"]: r for r in live}

fields = [f for f in expected[0].keys() if f != "Id"]
mismatches = []
brand_leaks = []
person_value_errors = []

person_expected = {
    "Source_Owner_Name__c": "Marcus Webb",
    "Customer_Manager_Name__c": "Sarah Chen",
    "Territory_Manager_Name__c": "Marcus Webb",
    "Renewals_Manager_Name__c": "Jennifer Park",
    "New_Account_Owner__c": "Marcus Webb",
    "Previous_Account_Owner__c": "Jennifer Park",
}

for sfid, exp in expected_by_id.items():
    got = live_by_id.get(sfid)
    if got is None:
        mismatches.append((sfid, "<record>", "missing"))
        continue

    for field in fields:
        ev = "" if exp.get(field) == "#N/A" else (exp.get(field) or "").strip()
        gv = (got.get(field) or "").strip()

        if ev != gv:
            mismatches.append((sfid, field, f"{ev!r} != {gv!r}"))

        if re.search(r"\b(Conga|Mar(?:umba))\b", gv, flags=re.I):
            brand_leaks.append((sfid, field, gv))

    for field, expected_name in person_expected.items():
        if (got.get(field) or "").strip() != expected_name:
            person_value_errors.append(
                (sfid, field, (got.get(field) or "").strip())
            )

summary = {
    "expected_accounts": len(expected_by_id),
    "live_authoritative_accounts": len(live_by_id),
    "fields_verified": len(fields),
    "field_values_verified": len(expected_by_id) * len(fields),
    "value_mismatches": len(mismatches),
    "forbidden_conga_or_marumba_values": len(brand_leaks),
    "person_identity_errors": len(person_value_errors),
}

summary_path.write_text(json.dumps(summary, indent=2) + "\n")

print()
print("VERIFICATION SUMMARY")
print("--------------------")
for key, value in summary.items():
    print(f"{key}: {value}")

if mismatches:
    print()
    print("First mismatches:")
    for item in mismatches[:20]:
        print(item)

if brand_leaks:
    print()
    print("First forbidden brand leaks:")
    for item in brand_leaks[:20]:
        print(item)

if person_value_errors:
    print()
    print("First person identity errors:")
    for item in person_value_errors[:20]:
        print(item)

if (
    summary["expected_accounts"] != 7755
    or summary["live_authoritative_accounts"] != 7755
    or mismatches
    or brand_leaks
    or person_value_errors
):
    raise SystemExit("\nERROR: Post-load verification failed.")

print()
print("PASS: Bongo profile anonymization repair verified.")
PY
}

apply_repair() {
  RUN_DIR="$(latest_preflight_dir)"

  if [ -z "$RUN_DIR" ] || [ ! -f "$RUN_DIR/PRECHECK_OK" ]; then
    echo "ERROR: No passed preflight found."
    echo "Run:"
    echo "  $0 preflight"
    exit 1
  fi

  echo "Using passed preflight:"
  echo "  $RUN_DIR"
  echo
  echo "This update does NOT contain Account.Name or OCX_Account_ID__c."

  echo
  echo "[APPLY] Updating 7,755 Account profile records..."

  sf data update bulk \
    --target-org "$ORG" \
    --sobject Account \
    --file "$RUN_DIR/account_updates.csv" \
    --line-ending LF \
    --wait 30

  verify_run "$RUN_DIR"

  touch "$RUN_DIR/APPLY_VERIFIED"

  echo
  echo "============================================================"
  echo "BONGO PROFILE ANONYMIZATION REPAIR COMPLETE"
  echo "============================================================"
  echo "Rollback snapshot preserved:"
  echo "  $RUN_DIR/account_rollback.csv"
}

verify_latest() {
  RUN_DIR="$(latest_preflight_dir)"

  if [ -z "$RUN_DIR" ]; then
    echo "ERROR: No preflight run found."
    exit 1
  fi

  verify_run "$RUN_DIR"
}

case "$MODE" in
  preflight)
    build_preflight
    ;;
  apply)
    apply_repair
    ;;
  verify)
    verify_latest
    ;;
  *)
    echo "Usage:"
    echo "  $0 preflight"
    echo "  $0 apply"
    echo "  $0 verify"
    exit 1
    ;;
esac
