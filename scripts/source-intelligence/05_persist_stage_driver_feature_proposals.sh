#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORG="${ORG:-OCXDemo}"
MODE="${1:-preflight}"
shift || true

usage() {
  cat <<'USAGE'
Usage:
  05_persist_stage_driver_feature_proposals.sh preflight \
    --stage "Support" \
    --driver "Effectiveness of Resolution" \
    [--proposal-dir /path/to/stage-driver-proposal-...]

  05_persist_stage_driver_feature_proposals.sh apply \
    --stage "Support" \
    --driver "Effectiveness of Resolution" \
    [--proposal-dir /path/to/stage-driver-proposal-...]

Purpose:
  Persist a prepared Stage/Driver proposal package safely and idempotently.

Behavior:
  - If no exact proposal run exists, preflight plans a NEW run and apply creates it.
  - If one exact Running run exists, preflight/apply RESUME it safely.
  - If one exact Complete run exists, preflight verifies it and reports ALREADY_COMPLETE.
  - Complex formulas/rationales are transported by CSV + Bulk API 2.0.
  - Only missing Feature Definitions and lineage links are inserted.
  - The immutable Source Intelligence catalog is never modified.
  - Account, Opportunity, Case, and Task are never modified.
  - All proposal features remain DIRECT_EXPERIENCE / NOT_TESTED.

Modes:
  preflight  READ ONLY against Salesforce; local .ocx artifacts only.
  apply      Create/resume the proposal run and complete it after exact verification.
USAGE
}

if [ "$MODE" != "preflight" ] && [ "$MODE" != "apply" ]; then
  echo "ERROR: mode must be preflight or apply."
  usage
  exit 1
fi

STAGE=""
DRIVER=""
PROPOSAL_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage)
      STAGE="${2:-}"
      shift 2
      ;;
    --driver)
      DRIVER="${2:-}"
      shift 2
      ;;
    --proposal-dir)
      PROPOSAL_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [ -z "$STAGE" ] || [ -z "$DRIVER" ]; then
  echo "ERROR: --stage and --driver are required."
  usage
  exit 1
fi

cd "$PROJECT"

slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//;s/-$//'
}

STAGE_SLUG="$(slug "$STAGE")"
DRIVER_SLUG="$(slug "$DRIVER")"

if [ -z "$PROPOSAL_DIR" ]; then
  PROPOSAL_DIR="$(
    find "$PROJECT/.ocx" -maxdepth 1 -type d \
      -name "stage-driver-proposal-${STAGE_SLUG}-${DRIVER_SLUG}-*" \
      -print 2>/dev/null \
      | sort \
      | tail -1
  )"
fi

if [ -z "$PROPOSAL_DIR" ] || [ ! -d "$PROPOSAL_DIR" ]; then
  echo "ERROR: no prepared proposal directory found."
  exit 1
fi

FEATURE_PREVIEW="$PROPOSAL_DIR/feature-definition-write-preview.csv"
LINK_PREVIEW="$PROPOSAL_DIR/feature-ingredient-write-preview.csv"
FIELD_MAP="$PROPOSAL_DIR/persistence-field-map.json"
SOURCE_RUN_JSON="$PROPOSAL_DIR/source-run.json"

for f in "$FEATURE_PREVIEW" "$LINK_PREVIEW" "$FIELD_MAP" "$SOURCE_RUN_JSON"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing required proposal artifact: $f"
    exit 1
  fi
done

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$PROJECT/.ocx/stage-driver-persist-${STAGE_SLUG}-${DRIVER_SLUG}-${STAMP}"
mkdir -p "$OUT"

SOURCE_RUN_ID="$(
python3 - "$SOURCE_RUN_JSON" <<'PY'
import json, sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
rows=((d.get("result") or {}).get("records") or [])
if not rows:
    raise SystemExit("ERROR: source-run.json has no source catalog record.")
print(rows[0]["Id"])
PY
)"

SCOPE_VALUE="Stage=${STAGE}; Driver=${DRIVER}; SourceCatalog=${SOURCE_RUN_ID}"

echo
echo "============================================================"
echo "CUSTOMER AI — PERSIST STAGE / DRIVER FEATURE PROPOSALS"
echo "============================================================"
echo "Project:       $PROJECT"
echo "Org:           $ORG"
echo "Mode:          $MODE"
echo "Stage:         $STAGE"
echo "Driver:        $DRIVER"
echo "Proposal dir:  $PROPOSAL_DIR"
echo "Source run:    $SOURCE_RUN_ID"
echo "Output:        $OUT"
echo
echo "Persistence rules:"
echo "  - create a new run only when no exact proposal run exists"
echo "  - resume exactly one matching Running run when present"
echo "  - treat an exact Complete run as idempotently complete"
echo "  - bulk insert only missing records"
echo "  - source catalog remains read only"
echo "  - all proposal features remain NOT_TESTED"
echo "============================================================"
echo

echo "[1/7] Resolving proposal run state..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Name,Status__c,Run_Type__c,Scope__c,Ingredient_Count__c,Feature_Definition_Count__c,Direct_Experience_Count__c,CreatedDate FROM OCX_Source_Intelligence_Run__c ORDER BY CreatedDate DESC LIMIT 500" \
  --result-format json > "$OUT/recent-runs.json"

python3 - "$OUT/recent-runs.json" "$SCOPE_VALUE" "$OUT/proposal-run-state.json" <<'PY'
import json, sys
from pathlib import Path

d=json.loads(Path(sys.argv[1]).read_text())
scope=sys.argv[2]
out=Path(sys.argv[3])
rows=((d.get("result") or {}).get("records") or [])

exact=[r for r in rows if (r.get("Scope__c") or "") == scope]
complete=[r for r in exact if r.get("Status__c") == "Complete"]
running=[r for r in exact if r.get("Status__c") == "Running"]
other=[r for r in exact if r.get("Status__c") not in {"Complete","Running"}]

if other:
    print("ERROR: exact-scope proposal runs exist in unsupported states.", file=sys.stderr)
    for r in other:
        print(" ",r.get("Id"),r.get("Status__c"),r.get("CreatedDate"),file=sys.stderr)
    raise SystemExit(2)

if len(complete) > 1 or len(running) > 1 or (complete and running):
    print("ERROR: ambiguous exact-scope proposal run state.", file=sys.stderr)
    for r in exact:
        print(" ",r.get("Id"),r.get("Status__c"),r.get("CreatedDate"),file=sys.stderr)
    raise SystemExit(3)

if complete:
    state="COMPLETE"
    record=complete[0]
elif running:
    state="RUNNING"
    record=running[0]
else:
    state="NEW"
    record=None

payload={"state":state,"record":record,"scope":scope}
out.write_text(json.dumps(payload,indent=2)+"\n",encoding="utf-8")

print("PROPOSAL RUN STATE")
print("------------------")
print("state:",state)
if record:
    print("id:",record.get("Id"))
    print("name:",record.get("Name"))
    print("status:",record.get("Status__c"))
    print("created:",record.get("CreatedDate"))
else:
    print("id: <will be created only in apply mode>")
PY

RUN_STATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$OUT/proposal-run-state.json")"
PROPOSAL_RUN_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("record") or {}).get("Id") or "")' "$OUT/proposal-run-state.json")"
PAYLOAD_RUN_ID="${PROPOSAL_RUN_ID:-__NEW_PROPOSAL_RUN__}"

echo "  Persistence state: $RUN_STATE"
if [ -n "$PROPOSAL_RUN_ID" ]; then
  echo "  Proposal run:      $PROPOSAL_RUN_ID"
fi

echo
echo "[2/7] Inspecting current live proposal state..."

EXPLAINABILITY_FIELD="$(
python3 - "$FIELD_MAP" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
print(d.get("explainability") or "")
PY
)"

FEATURE_SELECT_FIELDS="Id,Feature_Key__c,Feature_Class__c,Empirical_Status__c,Human_Status__c"
if [ -n "$EXPLAINABILITY_FIELD" ]; then
  FEATURE_SELECT_FIELDS="${FEATURE_SELECT_FIELDS},${EXPLAINABILITY_FIELD}"
fi

echo "  Explainability field: ${EXPLAINABILITY_FIELD:-<none>}"

if [ "$RUN_STATE" = "NEW" ]; then
  printf '%s\n' '{"status":0,"result":{"totalSize":0,"done":true,"records":[]}}' > "$OUT/live-feature-definitions-before.json"
  printf '%s\n' '{"status":0,"result":{"totalSize":0,"done":true,"records":[]}}' > "$OUT/live-feature-links-before.json"
else
  sf data query \
    --target-org "$ORG" \
    --query "SELECT $FEATURE_SELECT_FIELDS FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$PROPOSAL_RUN_ID' ORDER BY Feature_Key__c" \
    --result-format json > "$OUT/live-feature-definitions-before.json"

  sf data query \
    --target-org "$ORG" \
    --query "SELECT Id,OCX_Feature_Definition__c,OCX_Source_Ingredient__c,Sequence__c FROM OCX_Feature_Ingredient__c WHERE OCX_Feature_Definition__r.OCX_Run__c = '$PROPOSAL_RUN_ID' ORDER BY OCX_Feature_Definition__c,Sequence__c" \
    --result-format json > "$OUT/live-feature-links-before.json"
fi

python3 - \
  "$FEATURE_PREVIEW" \
  "$LINK_PREVIEW" \
  "$OUT/live-feature-definitions-before.json" \
  "$OUT/live-feature-links-before.json" <<'PY'
from pathlib import Path
import csv, json, sys

feature_preview=Path(sys.argv[1])
link_preview=Path(sys.argv[2])
live_features_path=Path(sys.argv[3])
live_links_path=Path(sys.argv[4])

def csv_rows(path):
    with path.open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

def sf_rows(path):
    d=json.loads(path.read_text())
    return (d.get("result") or {}).get("records") or []

expected_features=csv_rows(feature_preview)
expected_links=csv_rows(link_preview)
live_features=sf_rows(live_features_path)
live_links=sf_rows(live_links_path)

print("CURRENT PROPOSAL RUN STATE")
print("---------------------")
print("expected_feature_definitions:",len(expected_features))
print("live_feature_definitions:",len(live_features))
print("expected_feature_links:",len(expected_links))
print("live_feature_links:",len(live_links))

bad=[
    r for r in live_features
    if r.get("Feature_Class__c") != "DIRECT_EXPERIENCE"
    or r.get("Empirical_Status__c") != "NOT_TESTED"
]
if bad:
    raise SystemExit("ERROR: existing proposal run contains unexpected feature state.")

print("PASS: any existing proposal records remain DIRECT_EXPERIENCE / NOT_TESTED.")
PY

echo
echo "[3/7] Building idempotent Bulk API CSVs..."

python3 - \
  "$PAYLOAD_RUN_ID" \
  "$FEATURE_PREVIEW" \
  "$LINK_PREVIEW" \
  "$FIELD_MAP" \
  "$OUT/live-feature-definitions-before.json" \
  "$OUT/live-feature-links-before.json" \
  "$OUT" <<'PY'
from pathlib import Path
import csv, json, sys

run_id=sys.argv[1]
feature_preview=Path(sys.argv[2])
link_preview=Path(sys.argv[3])
field_map_path=Path(sys.argv[4])
live_features_path=Path(sys.argv[5])
live_links_path=Path(sys.argv[6])
out=Path(sys.argv[7])

def csv_rows(path):
    with path.open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

def sf_rows(path):
    d=json.loads(path.read_text())
    return (d.get("result") or {}).get("records") or []

features=csv_rows(feature_preview)
links=csv_rows(link_preview)
field_map=json.loads(field_map_path.read_text())
explainability_field=field_map.get("explainability")

live_features=sf_rows(live_features_path)
live_links=sf_rows(live_links_path)

live_by_key={
    r.get("Feature_Key__c"):r
    for r in live_features
    if r.get("Feature_Key__c")
}

# Feature_Key__c equals Proposal_Key in this proposal-run design.
feature_columns=[
    "OCX_Run__c",
    "Feature_Key__c",
    "Feature_Class__c",
    "Feature_Type__c",
    "Availability_Status__c",
    "Empirical_Status__c",
    "Human_Status__c",
    "Stage_Key__c",
    "Stage_Name__c",
    "Driver_Key__c",
    "Driver_Name__c",
    "Primary_Theme__c",
    "Measurement_Concept__c",
    "Metric_Archetype__c",
    "Formula_Expression__c",
    "Grain__c",
    "Window_Days__c",
    "Predictive_Prior_Score__c",
    "Data_Coverage_Pct__c",
    "Direction_Hypothesis__c",
    "Generated_Rationale__c",
    "Origin__c",
]
if explainability_field:
    feature_columns.append(explainability_field)

missing_features=[]
for r in features:
    key=r["Proposal_Key"]
    if key in live_by_key:
        continue

    outrow={
        "OCX_Run__c":run_id,
        "Feature_Key__c":key,
    }
    for c in feature_columns:
        if c in {"OCX_Run__c","Feature_Key__c"}:
            continue
        outrow[c]=r.get(c,"")
    missing_features.append(outrow)

with (out/"missing-feature-definitions.csv").open(
    "w",encoding="utf-8",newline=""
) as f:
    w=csv.DictWriter(
        f,fieldnames=feature_columns,lineterminator="\n",extrasaction="ignore"
    )
    w.writeheader()
    w.writerows(missing_features)

# If a Running proposal was partially persisted, repair optional explainability
# enrichment on already-created Feature Definitions before inserting the rest.
enrichment_updates=[]
if explainability_field:
    preview_by_key={r["Proposal_Key"]:r for r in features}
    for live in live_features:
        key=live.get("Feature_Key__c")
        preview=preview_by_key.get(key)
        if not preview:
            continue

        desired=str(preview.get(explainability_field) or "").strip()
        if desired == "":
            continue

        current=live.get(explainability_field)
        current_text="" if current is None else str(current).strip()

        # Normalize numeric representations (e.g. 0.8 vs 0.80).
        same=False
        try:
            same=abs(float(current_text)-float(desired)) < 1e-12
        except Exception:
            same=(current_text == desired)

        if not same:
            enrichment_updates.append({
                "Id":live.get("Id"),
                explainability_field:desired,
            })

enrichment_fields=["Id"] + ([explainability_field] if explainability_field else [])
with (out/"existing-feature-enrichment-updates.csv").open(
    "w",encoding="utf-8",newline=""
) as f:
    w=csv.DictWriter(f,fieldnames=enrichment_fields,lineterminator="\n")
    w.writeheader()
    if enrichment_updates:
        w.writerows(enrichment_updates)

# At preflight time we can only build missing links for Feature Definitions
# that already exist. Links for newly inserted Feature Definitions are rebuilt
# after the feature bulk load.
live_id_by_key={
    r.get("Feature_Key__c"):r.get("Id")
    for r in live_features
    if r.get("Feature_Key__c") and r.get("Id")
}
existing_link_keys={
    (
        r.get("OCX_Feature_Definition__c"),
        r.get("OCX_Source_Ingredient__c"),
        str(r.get("Sequence__c") or "")
    )
    for r in live_links
}

link_columns=[
    "OCX_Feature_Definition__c",
    "OCX_Source_Ingredient__c",
    "Ingredient_Role__c",
    "Sequence__c",
    "Transform__c",
    "Is_Time_Field__c",
    "Is_Grouping_Field__c",
    "Is_Filter_Field__c",
    "Is_Cohort_Dimension__c",
    "Is_Benchmark_Feature__c",
]

currently_resolvable_missing_links=[]
for r in links:
    fid=live_id_by_key.get(r["Proposal_Key"])
    if not fid:
        continue
    key=(fid,r["Source_Ingredient_Id"],str(r.get("Sequence__c") or ""))
    if key in existing_link_keys:
        continue
    currently_resolvable_missing_links.append({
        "OCX_Feature_Definition__c":fid,
        "OCX_Source_Ingredient__c":r["Source_Ingredient_Id"],
        "Ingredient_Role__c":r.get("Ingredient_Role__c") or "INPUT",
        "Sequence__c":r.get("Sequence__c",""),
        "Transform__c":r.get("Transform__c",""),
        "Is_Time_Field__c":r.get("Is_Time_Field__c","false"),
        "Is_Grouping_Field__c":r.get("Is_Grouping_Field__c","false"),
        "Is_Filter_Field__c":r.get("Is_Filter_Field__c","false"),
        "Is_Cohort_Dimension__c":r.get("Is_Cohort_Dimension__c","false"),
        "Is_Benchmark_Feature__c":r.get("Is_Benchmark_Feature__c","false"),
    })

with (out/"currently-resolvable-missing-links.csv").open(
    "w",encoding="utf-8",newline=""
) as f:
    w=csv.DictWriter(f,fieldnames=link_columns,lineterminator="\n")
    w.writeheader()
    w.writerows(currently_resolvable_missing_links)

summary={
    "expected_features":len(features),
    "live_features_before":len(live_features),
    "missing_features_to_insert":len(missing_features),
    "existing_feature_enrichment_updates":len(enrichment_updates),
    "expected_links":len(links),
    "live_links_before":len(live_links),
    "currently_resolvable_missing_links":len(currently_resolvable_missing_links),
    "explainability_field":explainability_field,
}
(out/"persistence-preflight-summary.json").write_text(
    json.dumps(summary,indent=2)+"\n",encoding="utf-8"
)

print("PERSISTENCE PAYLOAD SUMMARY")
print("----------------------")
for k,v in summary.items():
    print(f"{k}: {v}")
PY

echo
echo "[4/7] Validating persistence payload safety..."

python3 - "$OUT/missing-feature-definitions.csv" "$FEATURE_PREVIEW" <<'PY'
from pathlib import Path
import csv,re,sys

missing_path=Path(sys.argv[1])
preview_path=Path(sys.argv[2])

def rows(path):
    with path.open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

missing=rows(missing_path)
preview=rows(preview_path)

for r in missing:
    if r.get("Feature_Class__c") != "DIRECT_EXPERIENCE":
        raise SystemExit("ERROR: persistence payload contains non-Direct Experience feature.")
    if r.get("Empirical_Status__c") != "NOT_TESTED":
        raise SystemExit("ERROR: persistence payload contains empirically tested feature.")

if len(missing) > len(preview):
    raise SystemExit("ERROR: missing feature count exceeds prepared proposal count.")

print("PASS: persistence feature payload is a subset of the prepared proposal package.")
print("PASS: all persistence features are DIRECT_EXPERIENCE / NOT_TESTED.")
print("PASS: complex formula/rationale text will be transported as CSV fields.")
PY

if [ -n "$EXPLAINABILITY_FIELD" ]; then
  echo "PASS: optional explainability enrichment is wired to $EXPLAINABILITY_FIELD."
else
  echo "NOTE: no optional explainability field is available in the prepared field map."
fi

# A Complete exact-scope run must be internally exact before we call it idempotently complete.
if [ "$RUN_STATE" = "COMPLETE" ]; then
  python3 - "$OUT/persistence-preflight-summary.json" <<'PY'
import json,sys
from pathlib import Path
s=json.loads(Path(sys.argv[1]).read_text())
problems=[]
if s.get("missing_features_to_insert") != 0:
    problems.append(f"missing features={s.get('missing_features_to_insert')}")
if s.get("existing_feature_enrichment_updates") != 0:
    problems.append(f"enrichment repairs={s.get('existing_feature_enrichment_updates')}")
if s.get("live_links_before") != s.get("expected_links"):
    problems.append(f"links live={s.get('live_links_before')} expected={s.get('expected_links')}")
if s.get("currently_resolvable_missing_links") != 0:
    problems.append(f"missing links={s.get('currently_resolvable_missing_links')}")
if problems:
    raise SystemExit("ERROR: Complete proposal run is inconsistent: "+", ".join(problems))
print("PASS: exact Complete proposal run already matches the prepared package.")
PY
fi

if [ "$MODE" = "preflight" ]; then
  echo
  echo "============================================================"
  echo "PERSISTENCE PREFLIGHT PASSED"
  echo "============================================================"
  echo "NO SALESFORCE RECORDS OR METADATA WERE MODIFIED."
  echo
  echo "Persistence state: $RUN_STATE"
  if [ "$RUN_STATE" = "NEW" ]; then
    echo "Apply will create one NEW proposal run."
  elif [ "$RUN_STATE" = "RUNNING" ]; then
    echo "Apply will resume proposal run: $PROPOSAL_RUN_ID"
  else
    echo "The exact proposal run is already Complete: $PROPOSAL_RUN_ID"
  fi
  echo
  echo "Next only after review:"
  echo "  $0 apply --stage \"$STAGE\" --driver \"$DRIVER\" --proposal-dir \"$PROPOSAL_DIR\""
  echo "============================================================"
  exit 0
fi

if [ "$RUN_STATE" = "COMPLETE" ]; then
  echo
  echo "============================================================"
  echo "PROPOSAL ALREADY COMPLETE"
  echo "============================================================"
  echo "Proposal Run Id: $PROPOSAL_RUN_ID"
  echo "No Salesforce records were modified."
  echo "============================================================"
  exit 0
fi

if [ "$RUN_STATE" = "NEW" ]; then
  echo
  echo "[5/7] Creating NEW Stage/Driver proposal run..."

  RUN_VALUES="Status__c='Running' Run_Type__c='STAGE_DRIVER_PROPOSAL' Source_System__c='Salesforce' Scope__c='${SCOPE_VALUE}' Ingredient_Count__c=0 Feature_Definition_Count__c=0 Profile_Feature_Count__c=0 Direct_Experience_Count__c=0 Cohort_Derived_Count__c=0"

  sf data create record \
    --target-org "$ORG" \
    --sobject OCX_Source_Intelligence_Run__c \
    --values "$RUN_VALUES" \
    --json > "$OUT/create-run.json"

  PROPOSAL_RUN_ID="$(python3 - "$OUT/create-run.json" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
r=d.get("result") or {}
rid=r.get("id") or r.get("Id")
if not rid:
    print(json.dumps(d,indent=2),file=sys.stderr)
    raise SystemExit("ERROR: could not read new proposal Run Id.")
print(rid)
PY
)"

  echo "  New proposal run: $PROPOSAL_RUN_ID"

  python3 - "$OUT/missing-feature-definitions.csv" "$PROPOSAL_RUN_ID" <<'PY'
import csv,sys
from pathlib import Path
path=Path(sys.argv[1])
run_id=sys.argv[2]
with path.open(encoding="utf-8-sig",newline="") as f:
    rows=list(csv.DictReader(f))
    fields=list(rows[0].keys()) if rows else []
for r in rows:
    if r.get("OCX_Run__c") == "__NEW_PROPOSAL_RUN__":
        r["OCX_Run__c"]=run_id
with path.open("w",encoding="utf-8",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
PY
else
  echo
  echo "[5/7] Resuming existing Stage/Driver proposal run: $PROPOSAL_RUN_ID"
fi

echo "Repairing partial Feature Definition enrichment, then inserting only missing Feature Definitions..."

ENRICHMENT_UPDATE_COUNT="$(
python3 - "$OUT/existing-feature-enrichment-updates.csv" <<'PY'
import csv,sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding="utf-8-sig",newline="") as f:
    print(sum(1 for _ in csv.DictReader(f)))
PY
)"

if [ "$ENRICHMENT_UPDATE_COUNT" -gt 0 ]; then
  echo "  Updating optional enrichment on $ENRICHMENT_UPDATE_COUNT existing Feature Definitions..."
  if ! sf data update bulk \
      --target-org "$ORG" \
      --sobject OCX_Feature_Definition__c \
      --file "$OUT/existing-feature-enrichment-updates.csv" \
      --line-ending LF \
      --wait 10 \
      --json > "$OUT/feature-enrichment-update.json"
  then
    echo "ERROR: existing Feature Definition enrichment update failed."
    cat "$OUT/feature-enrichment-update.json" || true
    echo "STOP. Inspect the error before another run."
    exit 1
  fi
else
  echo "  No existing Feature Definition enrichment repairs are needed."
fi

MISSING_FEATURE_COUNT="$(
python3 - "$OUT/missing-feature-definitions.csv" <<'PY'
import csv,sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding="utf-8-sig",newline="") as f:
    print(sum(1 for _ in csv.DictReader(f)))
PY
)"

if [ "$MISSING_FEATURE_COUNT" -gt 0 ]; then
  if ! sf data import bulk \
      --target-org "$ORG" \
      --sobject OCX_Feature_Definition__c \
      --file "$OUT/missing-feature-definitions.csv" \
      --line-ending LF \
      --wait 10 \
      --json > "$OUT/feature-import.json"
  then
    echo "ERROR: Feature Definition bulk import failed."
    cat "$OUT/feature-import.json" || true
    echo "STOP. Inspect the error before another run; this script is idempotent and can resume safely."
    exit 1
  fi
else
  echo "  No missing Feature Definitions."
fi

echo
echo "Refreshing live Feature Definitions..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Feature_Key__c,Feature_Class__c,Empirical_Status__c,Human_Status__c FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$PROPOSAL_RUN_ID' ORDER BY Feature_Key__c" \
  --result-format json > "$OUT/live-feature-definitions-after.json"

echo
echo "[6/7] Building and bulk inserting only missing lineage links..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,OCX_Feature_Definition__c,OCX_Source_Ingredient__c,Sequence__c FROM OCX_Feature_Ingredient__c WHERE OCX_Feature_Definition__r.OCX_Run__c = '$PROPOSAL_RUN_ID' ORDER BY OCX_Feature_Definition__c,Sequence__c" \
  --result-format json > "$OUT/live-feature-links-mid.json"

python3 - \
  "$LINK_PREVIEW" \
  "$OUT/live-feature-definitions-after.json" \
  "$OUT/live-feature-links-mid.json" \
  "$OUT/missing-feature-links.csv" <<'PY'
from pathlib import Path
import csv,json,sys

link_preview=Path(sys.argv[1])
feature_json=Path(sys.argv[2])
live_links_json=Path(sys.argv[3])
out_path=Path(sys.argv[4])

with link_preview.open(encoding="utf-8-sig",newline="") as f:
    expected=list(csv.DictReader(f))

def sf_rows(path):
    d=json.loads(path.read_text())
    return (d.get("result") or {}).get("records") or []

features=sf_rows(feature_json)
live_links=sf_rows(live_links_json)

id_by_key={
    r.get("Feature_Key__c"):r.get("Id")
    for r in features
    if r.get("Feature_Key__c") and r.get("Id")
}

existing={
    (
        r.get("OCX_Feature_Definition__c"),
        r.get("OCX_Source_Ingredient__c"),
        str(r.get("Sequence__c") or "")
    )
    for r in live_links
}

cols=[
    "OCX_Feature_Definition__c",
    "OCX_Source_Ingredient__c",
    "Ingredient_Role__c",
    "Sequence__c",
    "Transform__c",
    "Is_Time_Field__c",
    "Is_Grouping_Field__c",
    "Is_Filter_Field__c",
    "Is_Cohort_Dimension__c",
    "Is_Benchmark_Feature__c",
]

missing=[]
for r in expected:
    fid=id_by_key.get(r["Proposal_Key"])
    if not fid:
        raise SystemExit(
            "ERROR: expected Feature Definition was not created: "+r["Proposal_Key"]
        )

    key=(fid,r["Source_Ingredient_Id"],str(r.get("Sequence__c") or ""))
    if key in existing:
        continue

    missing.append({
        "OCX_Feature_Definition__c":fid,
        "OCX_Source_Ingredient__c":r["Source_Ingredient_Id"],
        "Ingredient_Role__c":r.get("Ingredient_Role__c") or "INPUT",
        "Sequence__c":r.get("Sequence__c",""),
        "Transform__c":r.get("Transform__c",""),
        "Is_Time_Field__c":r.get("Is_Time_Field__c","false"),
        "Is_Grouping_Field__c":r.get("Is_Grouping_Field__c","false"),
        "Is_Filter_Field__c":r.get("Is_Filter_Field__c","false"),
        "Is_Cohort_Dimension__c":r.get("Is_Cohort_Dimension__c","false"),
        "Is_Benchmark_Feature__c":r.get("Is_Benchmark_Feature__c","false"),
    })

with out_path.open("w",encoding="utf-8",newline="") as f:
    w=csv.DictWriter(f,fieldnames=cols,lineterminator="\n")
    w.writeheader()
    w.writerows(missing)

print("expected_links:",len(expected))
print("existing_links:",len(live_links))
print("missing_links_to_insert:",len(missing))
PY

MISSING_LINK_COUNT="$(
python3 - "$OUT/missing-feature-links.csv" <<'PY'
import csv,sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding="utf-8-sig",newline="") as f:
    print(sum(1 for _ in csv.DictReader(f)))
PY
)"

if [ "$MISSING_LINK_COUNT" -gt 0 ]; then
  if ! sf data import bulk \
      --target-org "$ORG" \
      --sobject OCX_Feature_Ingredient__c \
      --file "$OUT/missing-feature-links.csv" \
      --line-ending LF \
      --wait 10 \
      --json > "$OUT/link-import.json"
  then
    echo "ERROR: Feature Ingredient bulk import failed."
    cat "$OUT/link-import.json" || true
    echo "STOP. Inspect the error before another run."
    exit 1
  fi
else
  echo "  No missing Feature Ingredient links."
fi

echo
echo "[7/7] Final verification and completing the proposal run..."

FINAL_FEATURE_SELECT_FIELDS="Id,Feature_Key__c,Feature_Class__c,Availability_Status__c,Empirical_Status__c,Human_Status__c"
if [ -n "$EXPLAINABILITY_FIELD" ]; then
  FINAL_FEATURE_SELECT_FIELDS="${FINAL_FEATURE_SELECT_FIELDS},${EXPLAINABILITY_FIELD}"
fi

sf data query \
  --target-org "$ORG" \
  --query "SELECT $FINAL_FEATURE_SELECT_FIELDS FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$PROPOSAL_RUN_ID' ORDER BY Feature_Key__c" \
  --result-format json > "$OUT/live-feature-definitions-final.json"

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,OCX_Feature_Definition__c,OCX_Source_Ingredient__c,Sequence__c FROM OCX_Feature_Ingredient__c WHERE OCX_Feature_Definition__r.OCX_Run__c = '$PROPOSAL_RUN_ID'" \
  --result-format json > "$OUT/live-feature-links-final.json"

read -r FINAL_FEATURE_COUNT FINAL_LINK_COUNT <<EOF
$(python3 - "$OUT/live-feature-definitions-final.json" "$OUT/live-feature-links-final.json" "$FEATURE_PREVIEW" "$LINK_PREVIEW" <<'PY'
import csv,json,sys
from pathlib import Path

def sf_count(path):
    d=json.loads(Path(path).read_text())
    return len((d.get("result") or {}).get("records") or [])

def csv_count(path):
    with Path(path).open(encoding="utf-8-sig",newline="") as f:
        return sum(1 for _ in csv.DictReader(f))

lf=sf_count(sys.argv[1])
ll=sf_count(sys.argv[2])
ef=csv_count(sys.argv[3])
el=csv_count(sys.argv[4])

if lf != ef:
    raise SystemExit(f"ERROR: Feature Definition count mismatch: expected {ef}, live {lf}")
if ll != el:
    raise SystemExit(f"ERROR: Feature Ingredient count mismatch: expected {el}, live {ll}")

d=json.loads(Path(sys.argv[1]).read_text())
rows=(d.get("result") or {}).get("records") or []
bad=[
    r for r in rows
    if r.get("Feature_Class__c") != "DIRECT_EXPERIENCE"
    or r.get("Empirical_Status__c") != "NOT_TESTED"
]
if bad:
    raise SystemExit("ERROR: final proposal state violates DIRECT_EXPERIENCE / NOT_TESTED boundary.")

print(lf,ll)
PY
)
EOF

sf data update record \
  --target-org "$ORG" \
  --sobject OCX_Source_Intelligence_Run__c \
  --record-id "$PROPOSAL_RUN_ID" \
  --values "Status__c=Complete Ingredient_Count__c=$FINAL_LINK_COUNT Feature_Definition_Count__c=$FINAL_FEATURE_COUNT Profile_Feature_Count__c=0 Direct_Experience_Count__c=$FINAL_FEATURE_COUNT Cohort_Derived_Count__c=0" \
  --json > "$OUT/complete-run.json"

echo
echo "FINAL RUN"
echo "---------"
sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Name,Status__c,Run_Type__c,Scope__c,Ingredient_Count__c,Feature_Definition_Count__c,Profile_Feature_Count__c,Direct_Experience_Count__c,Cohort_Derived_Count__c FROM OCX_Source_Intelligence_Run__c WHERE Id = '$PROPOSAL_RUN_ID'" \
  --result-format human

echo
echo "FEATURE STATUS INVENTORY"
echo "------------------------"
sf data query \
  --target-org "$ORG" \
  --query "SELECT Availability_Status__c,Empirical_Status__c,Human_Status__c,COUNT(Id) qty FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$PROPOSAL_RUN_ID' GROUP BY Availability_Status__c,Empirical_Status__c,Human_Status__c ORDER BY Availability_Status__c" \
  --result-format human

echo
echo "============================================================"
echo "STAGE / DRIVER PROPOSAL PERSISTENCE COMPLETE"
echo "============================================================"
echo "Proposal Run Id:           $PROPOSAL_RUN_ID"
echo "Feature Definitions:        $FINAL_FEATURE_COUNT"
echo "Feature Ingredient Links:   $FINAL_LINK_COUNT"
echo
echo "Immutable source catalog was not modified:"
echo "  $SOURCE_RUN_ID"
echo
echo "Signal testing was NOT performed."
echo "All proposal features remain NOT_TESTED."
echo "============================================================"
