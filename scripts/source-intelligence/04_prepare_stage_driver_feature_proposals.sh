#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORG="${ORG:-OCXDemo}"

usage() {
  cat <<'USAGE'
Usage:
  04_prepare_stage_driver_feature_proposals.sh \
    --stage "Support" \
    --driver "Effectiveness of Resolution" \
    [--top 15] \
    [--discovery-dir /path/to/kpi-discovery-...]

READ ONLY.
This script prepares the Salesforce persistence package for chat-time
Stage/Driver KPI proposals. It DOES NOT run signal testing and DOES NOT
modify Salesforce.

It:
  - uses the latest completed Source Intelligence catalog as immutable source truth
  - consumes the frozen Stage/Driver discovery output
  - keeps every returned candidate as PROPOSED / NOT_TESTED
  - preserves DERIVABLE / MAPPING_REQUIRED / TARGET_NOT_YET_AVAILABLE
  - resolves candidate ingredients back to OCX_Source_Ingredient__c
  - prepares feature-definition and feature-lineage write previews
  - audits live Salesforce schema/picklists before any later apply step
USAGE
}

STAGE=""
DRIVER=""
TOP=15
DISCOVERY_DIR=""

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
    --top)
      TOP="${2:-15}"
      shift 2
      ;;
    --discovery-dir)
      DISCOVERY_DIR="${2:-}"
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

if ! [[ "$TOP" =~ ^[0-9]+$ ]] || [ "$TOP" -lt 1 ] || [ "$TOP" -gt 50 ]; then
  echo "ERROR: --top must be between 1 and 50."
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

if [ -z "$DISCOVERY_DIR" ]; then
  DISCOVERY_DIR="$(
    find "$PROJECT/.ocx" -maxdepth 1 -type d \
      -name "kpi-discovery-${STAGE_SLUG}-${DRIVER_SLUG}-*" \
      -print 2>/dev/null \
      | sort \
      | tail -1
  )"
fi

if [ -z "$DISCOVERY_DIR" ] || [ ! -d "$DISCOVERY_DIR" ]; then
  echo "ERROR: no discovery directory found for:"
  echo "  Stage:  $STAGE"
  echo "  Driver: $DRIVER"
  exit 1
fi

CANDIDATES="$DISCOVERY_DIR/ranked-kpi-candidates.csv"
GAPS="$DISCOVERY_DIR/target-signal-gaps.csv"

if [ ! -f "$CANDIDATES" ]; then
  echo "ERROR: missing $CANDIDATES"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$PROJECT/.ocx/stage-driver-proposal-${STAGE_SLUG}-${DRIVER_SLUG}-${STAMP}"
mkdir -p "$OUT"

echo
echo "============================================================"
echo "CUSTOMER AI — STAGE / DRIVER FEATURE PROPOSAL PREP"
echo "============================================================"
echo "Project:        $PROJECT"
echo "Org:            $ORG"
echo "Stage:          $STAGE"
echo "Driver:         $DRIVER"
echo "Discovery dir:  $DISCOVERY_DIR"
echo "Output:         $OUT"
echo
echo "READ ONLY."
echo "No Salesforce records or metadata will be modified."
echo
echo "Design:"
echo "  - signal testing is intentionally deferred"
echo "  - source catalog run remains immutable"
echo "  - chat-time candidates remain PROPOSED / NOT_TESTED"
echo "  - a later apply step will create a NEW proposal run"
echo "  - proposed Direct Experience features will never overwrite Profile features"
echo "============================================================"
echo

echo "[1/6] Finding immutable completed Source Intelligence catalog..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Name,Status__c,Ingredient_Count__c,Feature_Definition_Count__c,Profile_Feature_Count__c,Direct_Experience_Count__c,Cohort_Derived_Count__c,CreatedDate FROM OCX_Source_Intelligence_Run__c WHERE Status__c = 'Complete' ORDER BY CreatedDate DESC LIMIT 1" \
  --result-format json > "$OUT/source-run.json"

SOURCE_RUN_ID="$(
python3 - "$OUT/source-run.json" <<'PY'
import json, sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
rows=((d.get("result") or {}).get("records") or [])
if not rows:
    raise SystemExit("ERROR: no completed Source Intelligence run found.")
print(rows[0]["Id"])
PY
)"

echo "  Source catalog run: $SOURCE_RUN_ID"

echo
echo "[2/6] Auditing live Salesforce persistence schema..."

for obj in \
  OCX_Source_Intelligence_Run__c \
  OCX_Source_Ingredient__c \
  OCX_Feature_Definition__c \
  OCX_Feature_Ingredient__c
do
  sf sobject describe \
    --target-org "$ORG" \
    --sobject "$obj" \
    --json > "$OUT/describe-$obj.json"
  echo "  OK: $obj"
done

python3 - "$OUT" <<'PY'
from pathlib import Path
import json, sys

out=Path(sys.argv[1])

required={
    "OCX_Source_Intelligence_Run__c":[
        "Status__c","Run_Type__c","Source_System__c","Scope__c",
        "Ingredient_Count__c","Feature_Definition_Count__c",
        "Profile_Feature_Count__c","Direct_Experience_Count__c",
        "Cohort_Derived_Count__c"
    ],
    "OCX_Source_Ingredient__c":[
        "Canonical_Field_Key__c","OCX_Run__c"
    ],
    "OCX_Feature_Definition__c":[
        "OCX_Run__c","Feature_Key__c","Feature_Class__c","Feature_Type__c",
        "Availability_Status__c","Empirical_Status__c","Human_Status__c",
        "Stage_Key__c","Stage_Name__c","Driver_Key__c","Driver_Name__c",
        "Primary_Theme__c","Measurement_Concept__c","Metric_Archetype__c",
        "Formula_Expression__c","Grain__c","Window_Days__c",
        "Predictive_Prior_Score__c",
        "Data_Coverage_Pct__c","Direction_Hypothesis__c",
        "Generated_Rationale__c","Origin__c"
    ],
    "OCX_Feature_Ingredient__c":[
        "OCX_Feature_Definition__c","OCX_Source_Ingredient__c",
        "Ingredient_Role__c","Sequence__c","Transform__c",
        "Is_Time_Field__c","Is_Grouping_Field__c","Is_Filter_Field__c",
        "Is_Cohort_Dimension__c","Is_Benchmark_Feature__c"
    ],
}

issues=[]
picklists=[]

for obj,fields in required.items():
    d=json.loads((out/f"describe-{obj}.json").read_text())
    result=d.get("result") or d
    fmap={f.get("name"):f for f in result.get("fields") or []}

    for field in fields:
        if field not in fmap:
            issues.append(f"MISSING FIELD: {obj}.{field}")

    for fname,f in fmap.items():
        vals=[
            x.get("value")
            for x in (f.get("picklistValues") or [])
            if x.get("active") is not False
        ]
        if vals and fname in {
            "Status__c","Run_Type__c","Feature_Class__c","Feature_Type__c",
            "Availability_Status__c","Empirical_Status__c","Human_Status__c",
            "Origin__c","Ingredient_Role__c"
        }:
            picklists.append((obj,fname,vals))

# Some enrichment fields have evolved across foundation revisions.
# They are optional for proposal persistence and resolved against the live org.
fd_desc=json.loads((out/"describe-OCX_Feature_Definition__c.json").read_text())
fd_result=fd_desc.get("result") or fd_desc
fd_fields={f.get("name") for f in (fd_result.get("fields") or []) if f.get("name")}

aliases={
    "explainability":[
        "Explainability__c",
        "Explainability_Score__c",
        "Explainability_Prior__c",
    ],
}
field_map={}
for logical,candidates in aliases.items():
    field_map[logical]=next((c for c in candidates if c in fd_fields), None)

(out/"persistence-field-map.json").write_text(
    json.dumps(field_map,indent=2)+"\n",encoding="utf-8"
)

report=[]
report.append("LIVE PERSISTENCE SCHEMA AUDIT")
report.append("-----------------------------")
if issues:
    report.extend(issues)
else:
    report.append("PASS: all required persistence fields exist.")
report.append("")
report.append("OPTIONAL FIELD RESOLUTION")
report.append("-------------------------")
report.append(
    "Explainability: " +
    (field_map.get("explainability") or "<not present; omit from proposal write>")
)
report.append("")
report.append("RELEVANT PICKLIST VALUES")
report.append("------------------------")
for obj,fname,vals in picklists:
    report.append(f"{obj}.{fname}: {', '.join(vals)}")

(out/"persistence-schema-audit.txt").write_text(
    "\n".join(report)+"\n",encoding="utf-8"
)
print("\n".join(report))

if issues:
    raise SystemExit("ERROR: persistence schema is missing required fields.")
PY

echo
echo "[3/6] Reading source ingredient lookup for the immutable catalog..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Canonical_Field_Key__c,Primary_Source_Role__c,Eligibility_Status__c,Source_Object__c,Source_Field__c FROM OCX_Source_Ingredient__c WHERE OCX_Run__c = '$SOURCE_RUN_ID'" \
  --result-format json > "$OUT/source-ingredients.json"

echo
echo "[4/6] Building proposed Direct Experience feature package..."

python3 - \
  "$STAGE" \
  "$DRIVER" \
  "$TOP" \
  "$CANDIDATES" \
  "$GAPS" \
  "$OUT/source-ingredients.json" \
  "$OUT/persistence-field-map.json" \
  "$OUT" <<'PY'
from pathlib import Path
import csv
import hashlib
import json
import re
import sys

stage=sys.argv[1]
driver=sys.argv[2]
top_n=int(sys.argv[3])
candidate_path=Path(sys.argv[4])
gap_path=Path(sys.argv[5])
ingredient_json=Path(sys.argv[6])
field_map_path=Path(sys.argv[7])
out=Path(sys.argv[8])
field_map=json.loads(field_map_path.read_text())
explainability_field=field_map.get("explainability")

def slug(s):
    return re.sub(r"[^a-z0-9]+","-",str(s).lower()).strip("-")

def read_csv(path):
    if not path.exists():
        return []
    with path.open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

def sf_records(path):
    d=json.loads(path.read_text())
    return (d.get("result") or {}).get("records") or []

candidates=read_csv(candidate_path)[:top_n]
gaps=read_csv(gap_path)

source_rows=sf_records(ingredient_json)
source_by_key={
    r.get("Canonical_Field_Key__c"):r
    for r in source_rows
    if r.get("Canonical_Field_Key__c")
}

def to_float(v, default=""):
    if v in (None,""):
        return default
    try:
        return float(v)
    except Exception:
        return default

def window_days(v):
    if not v:
        return ""
    m=re.search(r"(\d+)",str(v))
    return int(m.group(1)) if m else ""

def proposal_key(stage,driver,family,name,formula):
    raw="|".join([stage,driver,family or "",name or "",formula or ""])
    digest=hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]
    return f"proposal:{slug(stage)}:{slug(driver)}:{digest}"

feature_rows=[]
link_rows=[]
unresolved=[]

for row in candidates:
    pkey=proposal_key(
        stage,driver,row.get("Concept_Family"),row.get("KPI_Name"),row.get("Formula")
    )

    feature_rows.append({
        "Proposal_Key":pkey,
        "Feature_Key_Suffix":pkey,
        "Feature_Class__c":"DIRECT_EXPERIENCE",
        "Feature_Type__c":"KPI",
        "Availability_Status__c":row.get("Availability") or "PROPOSED",
        "Empirical_Status__c":"NOT_TESTED",
        "Human_Status__c":"PROPOSED",
        "Stage_Key__c":slug(stage).upper().replace("-","_"),
        "Stage_Name__c":stage,
        "Driver_Key__c":slug(driver).upper().replace("-","_"),
        "Driver_Name__c":driver,
        "Primary_Theme__c":row.get("Primary_Theme",""),
        "Measurement_Concept__c":row.get("Concept_Family",""),
        "Metric_Archetype__c":row.get("Metric_Archetype",""),
        "Formula_Expression__c":row.get("Formula",""),
        "Grain__c":row.get("Grain") or "Account",
        "Window_Days__c":window_days(row.get("Window")),
        "Predictive_Prior_Score__c":to_float(row.get("Predictive_Prior")),
        "Data_Coverage_Pct__c":(
            to_float(row.get("Data_Coverage_Score"),0) * 100
            if row.get("Data_Coverage_Score") not in (None,"")
            else ""
        ),
        "Direction_Hypothesis__c":row.get("Direction_Hypothesis",""),
        "Generated_Rationale__c":row.get("Rationale",""),
        "Origin__c":row.get("Candidate_Source") or "GENERATED",
        "Candidate_Score":row.get("Candidate_Score",""),
        "Recommendation":row.get("Recommendation",""),
        "Concept_Family":row.get("Concept_Family",""),
        "Historical_Evidence":row.get("Historical_Evidence",""),
    })
    if explainability_field:
        feature_rows[-1][explainability_field]=to_float(row.get("Explainability"))

    seq=0
    for raw_key in [
        x.strip()
        for x in str(row.get("Ingredients") or "").split(";")
        if x.strip()
    ]:
        if not raw_key.startswith("salesforce:"):
            unresolved.append({
                "Proposal_Key":pkey,
                "KPI_Name":row.get("KPI_Name",""),
                "Unresolved_Ingredient":raw_key,
                "Reason":"NOT_CANONICAL_SALESFORCE_KEY",
            })
            continue

        src=source_by_key.get(raw_key)
        if not src:
            unresolved.append({
                "Proposal_Key":pkey,
                "KPI_Name":row.get("KPI_Name",""),
                "Unresolved_Ingredient":raw_key,
                "Reason":"NOT_FOUND_IN_SOURCE_CATALOG",
            })
            continue

        if src.get("Eligibility_Status__c") == "EXCLUDE":
            unresolved.append({
                "Proposal_Key":pkey,
                "KPI_Name":row.get("KPI_Name",""),
                "Unresolved_Ingredient":raw_key,
                "Reason":"SOURCE_INGREDIENT_EXCLUDED",
            })
            continue

        seq += 1
        link_rows.append({
            "Proposal_Key":pkey,
            "Canonical_Field_Key__c":raw_key,
            "Source_Ingredient_Id":src.get("Id",""),
            "Ingredient_Role__c":"INPUT",
            "Sequence__c":seq,
            "Transform__c":"",
            "Is_Time_Field__c":"false",
            "Is_Grouping_Field__c":"false",
            "Is_Filter_Field__c":"false",
            "Is_Cohort_Dimension__c":"false",
            "Is_Benchmark_Feature__c":"false",
        })

for gap in gaps:
    label=gap.get("Desired_Signal") or gap.get("Concept_Family") or "Target signal"
    pkey=proposal_key(
        stage,driver,gap.get("Concept_Family"),label,"TARGET_NOT_YET_AVAILABLE"
    )
    feature_rows.append({
        "Proposal_Key":pkey,
        "Feature_Key_Suffix":pkey,
        "Feature_Class__c":"DIRECT_EXPERIENCE",
        "Feature_Type__c":"KPI",
        "Availability_Status__c":"TARGET_NOT_YET_AVAILABLE",
        "Empirical_Status__c":"NOT_TESTED",
        "Human_Status__c":"PROPOSED",
        "Stage_Key__c":slug(stage).upper().replace("-","_"),
        "Stage_Name__c":stage,
        "Driver_Key__c":slug(driver).upper().replace("-","_"),
        "Driver_Name__c":driver,
        "Primary_Theme__c":gap.get("Primary_Theme",""),
        "Measurement_Concept__c":gap.get("Concept_Family",""),
        "Metric_Archetype__c":"",
        "Formula_Expression__c":"",
        "Grain__c":"Account",
        "Window_Days__c":"",
        "Predictive_Prior_Score__c":"",
        "Data_Coverage_Pct__c":"",
        "Direction_Hypothesis__c":"",
        "Generated_Rationale__c":gap.get("Reason",""),
        "Origin__c":"TARGET_GAP",
        "Candidate_Score":"",
        "Recommendation":"TARGET_GAP",
        "Concept_Family":gap.get("Concept_Family",""),
        "Historical_Evidence":"",
    })
    if explainability_field:
        feature_rows[-1][explainability_field]=""

def write_csv(path, rows, fields):
    with path.open("w",encoding="utf-8",newline="") as f:
        w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n",extrasaction="ignore")
        w.writeheader()
        if rows:
            w.writerows(rows)

feature_fields=[
    "Proposal_Key","Feature_Key_Suffix",
    "Feature_Class__c","Feature_Type__c","Availability_Status__c",
    "Empirical_Status__c","Human_Status__c",
    "Stage_Key__c","Stage_Name__c","Driver_Key__c","Driver_Name__c",
    "Primary_Theme__c","Measurement_Concept__c","Metric_Archetype__c",
    "Formula_Expression__c","Grain__c","Window_Days__c",
    "Predictive_Prior_Score__c","Data_Coverage_Pct__c",
    "Direction_Hypothesis__c","Generated_Rationale__c","Origin__c",
    "Candidate_Score","Recommendation","Concept_Family","Historical_Evidence"
]

if explainability_field:
    insert_at=feature_fields.index("Data_Coverage_Pct__c")
    feature_fields.insert(insert_at,explainability_field)

link_fields=[
    "Proposal_Key","Canonical_Field_Key__c","Source_Ingredient_Id",
    "Ingredient_Role__c","Sequence__c","Transform__c",
    "Is_Time_Field__c","Is_Grouping_Field__c","Is_Filter_Field__c",
    "Is_Cohort_Dimension__c","Is_Benchmark_Feature__c"
]

write_csv(out/"feature-definition-write-preview.csv",feature_rows,feature_fields)
write_csv(out/"feature-ingredient-write-preview.csv",link_rows,link_fields)
write_csv(
    out/"unresolved-ingredient-preview.csv",
    unresolved,
    ["Proposal_Key","KPI_Name","Unresolved_Ingredient","Reason"]
)

summary={
    "stage":stage,
    "driver":driver,
    "ranked_candidates_consumed":len(candidates),
    "target_gaps_consumed":len(gaps),
    "feature_definitions_prepared":len(feature_rows),
    "ingredient_links_prepared":len(link_rows),
    "unresolved_ingredient_references":len(unresolved),
    "availability_counts":{},
    "empirical_status":"NOT_TESTED",
    "persistence_status":"PREVIEW_ONLY",
}
for r in feature_rows:
    k=r["Availability_Status__c"]
    summary["availability_counts"][k]=summary["availability_counts"].get(k,0)+1

(out/"proposal-summary.json").write_text(
    json.dumps(summary,indent=2)+"\n",encoding="utf-8"
)

print("PROPOSAL PACKAGE SUMMARY")
print("------------------------")
for k,v in summary.items():
    print(f"{k}: {v}")
PY

echo
echo "[5/6] Checking proposed values against live picklists..."

python3 - "$OUT" <<'PY'
from pathlib import Path
import csv
import json
import sys

out=Path(sys.argv[1])

def describe(obj):
    d=json.loads((out/f"describe-{obj}.json").read_text())
    return d.get("result") or d

def picklist_values(obj,field):
    fmap={f.get("name"):f for f in describe(obj).get("fields") or []}
    f=fmap.get(field)
    if not f:
        return []
    return [
        x.get("value")
        for x in (f.get("picklistValues") or [])
        if x.get("active") is not False
    ]

with (out/"feature-definition-write-preview.csv").open(
    encoding="utf-8-sig",newline=""
) as f:
    rows=list(csv.DictReader(f))

checks={
    "Feature_Class__c":set(r["Feature_Class__c"] for r in rows if r["Feature_Class__c"]),
    "Feature_Type__c":set(r["Feature_Type__c"] for r in rows if r["Feature_Type__c"]),
    "Availability_Status__c":set(r["Availability_Status__c"] for r in rows if r["Availability_Status__c"]),
    "Empirical_Status__c":set(r["Empirical_Status__c"] for r in rows if r["Empirical_Status__c"]),
    "Human_Status__c":set(r["Human_Status__c"] for r in rows if r["Human_Status__c"]),
    "Origin__c":set(r["Origin__c"] for r in rows if r["Origin__c"]),
}

problems=[]
print("PICKLIST COMPATIBILITY")
print("----------------------")
for field,used in checks.items():
    allowed=set(picklist_values("OCX_Feature_Definition__c",field))
    if not allowed:
        print(f"{field}: unrestricted / no active picklist values returned")
        continue

    invalid=sorted(used-allowed)
    print(f"{field}:")
    print(f"  used:    {', '.join(sorted(used)) or '<none>'}")
    print(f"  allowed: {', '.join(sorted(allowed))}")
    if invalid:
        problems.append((field,invalid))
        print(f"  REVIEW:  {', '.join(invalid)}")
    else:
        print("  PASS")

(out/"picklist-review.json").write_text(
    json.dumps(
        {
            "problems":[
                {"field":field,"invalid_values":vals}
                for field,vals in problems
            ]
        },
        indent=2
    )+"\n",
    encoding="utf-8"
)

if problems:
    print()
    print("NOTE: write preview is valid, but a later apply script must map the")
    print("      REVIEW values to allowed Salesforce picklist values.")
else:
    print()
    print("PASS: all constrained proposal values are live-picklist compatible.")
PY

echo
echo "[6/6] Final read-only checks..."

python3 - "$OUT" <<'PY'
from pathlib import Path
import csv
import re
import sys

out=Path(sys.argv[1])

with (out/"feature-definition-write-preview.csv").open(
    encoding="utf-8-sig",newline=""
) as f:
    features=list(csv.DictReader(f))

with (out/"feature-ingredient-write-preview.csv").open(
    encoding="utf-8-sig",newline=""
) as f:
    links=list(csv.DictReader(f))

if not features:
    raise SystemExit("ERROR: proposal package contains zero feature definitions.")

for r in features:
    if r["Feature_Class__c"] != "DIRECT_EXPERIENCE":
        raise SystemExit("ERROR: non-Direct Experience feature in proposal package.")
    if r["Empirical_Status__c"] != "NOT_TESTED":
        raise SystemExit("ERROR: proposal was incorrectly marked empirically tested.")

    text=" ".join(r.values())

print(f"feature_definitions: {len(features)}")
print(f"ingredient_links: {len(links)}")
print("PASS: proposal package contains Direct Experience proposals only.")
print("PASS: all proposal features remain NOT_TESTED.")
print("PASS: source catalog was used for lineage only; it was not modified.")
PY

echo
echo "Artifacts:"
echo "  $OUT/persistence-schema-audit.txt"
echo "  $OUT/persistence-field-map.json"
echo "  $OUT/proposal-summary.json"
echo "  $OUT/feature-definition-write-preview.csv"
echo "  $OUT/feature-ingredient-write-preview.csv"
echo "  $OUT/unresolved-ingredient-preview.csv"
echo "  $OUT/picklist-review.json"
echo
echo "============================================================"
echo "STAGE / DRIVER FEATURE PROPOSAL PREP COMPLETE"
echo "============================================================"
echo "NO SALESFORCE RECORDS OR METADATA WERE MODIFIED."
echo
echo "Next after review:"
echo "  build/apply a NEW Stage/Driver proposal run"
echo "  do NOT alter the immutable source catalog run"
echo "  signal testing remains a later analytical step"
echo "============================================================"
