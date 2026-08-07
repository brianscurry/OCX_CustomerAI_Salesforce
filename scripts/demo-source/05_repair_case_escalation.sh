#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
API_VERSION="${API_VERSION:-67.0}"

cd "$PROJECT"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$PROJECT/.ocx/case-escalation-repair-$STAMP"

mkdir -p "$OUT"

echo
echo "============================================================"
echo "OCX DEMO - CASE ESCALATION CONSISTENCY REPAIR"
echo "============================================================"
echo "Org:    $ORG"
echo "Output: $OUT"
echo "============================================================"
echo

count_query() {
  local QUERY="$1"

  sf data query \
    --target-org "$ORG" \
    --api-version "$API_VERSION" \
    --query "$QUERY" \
    --json \
  | jq -r '
      .result.records[0].expr0
      // .result.totalSize
      // 0
    '
}

echo "[1/5] Measuring current Case escalation state..."

STATUS_ESCALATED="$(
  count_query \
    "SELECT count() FROM Case WHERE Status = 'Escalated'"
)"

BOOLEAN_ESCALATED="$(
  count_query \
    "SELECT count() FROM Case WHERE IsEscalated = true"
)"

MISMATCH="$(
  count_query \
    "SELECT count() FROM Case
     WHERE Status = 'Escalated'
     AND IsEscalated = false"
)"

echo
echo "Cases with Status='Escalated':       $STATUS_ESCALATED"
echo "Cases with IsEscalated=true:         $BOOLEAN_ESCALATED"
echo "Contradictory Cases requiring repair: $MISMATCH"
echo

if [ "$MISMATCH" -eq 0 ]; then
  echo "No repair required."
  exit 0
fi

echo "[2/5] Exporting only contradictory Case IDs..."

sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT Id
    FROM Case
    WHERE Status = 'Escalated'
      AND IsEscalated = false
    ORDER BY Id
  " \
  --result-format csv \
  --output-file "$OUT/mismatched_cases.csv"

echo "Exported:"
echo "  $OUT/mismatched_cases.csv"

echo
echo "[3/5] Building minimal repair CSV..."

python3 - "$OUT/mismatched_cases.csv" "$OUT/Case_escalation_repair.csv" <<'PY'
import csv
import sys

source = sys.argv[1]
target = sys.argv[2]

with open(source, newline="", encoding="utf-8-sig") as f:
    rows = list(csv.DictReader(f))

if not rows:
    raise SystemExit("ERROR: No mismatch records exported.")

ids = [r["Id"].strip() for r in rows]

if any(not sfid for sfid in ids):
    raise SystemExit("ERROR: Blank Salesforce Id found.")

if len(ids) != len(set(ids)):
    raise SystemExit("ERROR: Duplicate Salesforce Id found.")

with open(
    target,
    "w",
    newline="",
    encoding="utf-8"
) as f:
    writer = csv.DictWriter(
        f,
        fieldnames=["Id", "IsEscalated"],
        lineterminator="\n"
    )

    writer.writeheader()

    for sfid in ids:
        writer.writerow({
            "Id": sfid,
            "IsEscalated": "true"
        })

print(f"Prepared {len(ids)} Case updates.")
PY

echo
echo "Repair CSV:"
echo "  $OUT/Case_escalation_repair.csv"
echo

file "$OUT/Case_escalation_repair.csv"

echo
echo "Sample:"
head -n 6 "$OUT/Case_escalation_repair.csv"

echo
echo "[4/5] Updating contradictory Cases only..."

set +e

sf data update bulk \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --sobject Case \
  --file "$OUT/Case_escalation_repair.csv" \
  --line-ending LF \
  --wait 10 \
  --json \
  > "$OUT/update.json" \
  2> "$OUT/update.err"

STATUS=$?

set -e

cat "$OUT/update.json"

if [ -s "$OUT/update.err" ]; then
  echo
  echo "CLI stderr:"
  cat "$OUT/update.err"
fi

if [ "$STATUS" -ne 0 ]; then
  echo
  echo "ERROR: Case repair bulk update failed."
  echo "Do not retry manually."
  exit "$STATUS"
fi

echo
echo "[5/5] Verifying live Salesforce state..."

STATUS_ESCALATED_AFTER="$(
  count_query \
    "SELECT count() FROM Case WHERE Status = 'Escalated'"
)"

BOOLEAN_ESCALATED_AFTER="$(
  count_query \
    "SELECT count() FROM Case WHERE IsEscalated = true"
)"

MISMATCH_AFTER="$(
  count_query \
    "SELECT count() FROM Case
     WHERE Status = 'Escalated'
     AND IsEscalated = false"
)"

echo
echo "Cases with Status='Escalated':       $STATUS_ESCALATED_AFTER"
echo "Cases with IsEscalated=true:         $BOOLEAN_ESCALATED_AFTER"
echo "Remaining contradictions:            $MISMATCH_AFTER"
echo

if [ "$MISMATCH_AFTER" -ne 0 ]; then
  echo "ERROR: Escalation consistency repair is incomplete."
  exit 1
fi

echo "Representative Escalated Cases:"
echo

sf data query \
  --target-org "$ORG" \
  --api-version "$API_VERSION" \
  --query "
    SELECT
      CaseNumber,
      Status,
      IsEscalated,
      Priority,
      Support_Level__c,
      SLA_Violation__c,
      Root_Cause__c
    FROM Case
    WHERE Status = 'Escalated'
    LIMIT 10
  "

echo
echo "============================================================"
echo "CASE ESCALATION REPAIR COMPLETE"
echo "============================================================"
echo
echo "Rule enforced:"
echo "  Status = Escalated -> IsEscalated = true"
echo
echo "No Cases outside that contradiction set were modified."
echo "============================================================"
