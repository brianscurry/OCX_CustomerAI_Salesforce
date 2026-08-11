#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORG="${ORG:-OCXDemo}"
MODE="${1:-preflight}"

cd "$PROJECT"

SEED_DIR="$PROJECT/scripts/source-intelligence/seeds"
OUT="$PROJECT/.ocx/source-intelligence-seed-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

if [ "$MODE" != "preflight" ] && [ "$MODE" != "apply" ]; then
  echo "ERROR: mode must be preflight or apply"
  exit 1
fi

echo
echo "============================================================"
echo "REPRODUCIBLE CUSTOMER AI SOURCE INTELLIGENCE SEED"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Mode:    $MODE"
echo
echo "Expected catalog:"
echo "  304 Source Ingredients"
echo "  21 Profile Feature Definitions"
echo "  21 Profile Feature lineage links"
echo "  172 historical semantic recipe priors"
echo
echo "Source boundary:"
echo "  Account.Source_ACV__c = upstream Profile input"
echo "  Account.OCX_ACV__c    = downstream / excluded"
echo "============================================================"
echo

for f in \
  "$SEED_DIR/source_ingredients.csv" \
  "$SEED_DIR/profile_features.csv" \
  "$SEED_DIR/profile_feature_links.csv" \
  "$SEED_DIR/historical_recipe_templates.csv"
do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing seed: $f"
    exit 1
  fi
done

echo "[1/6] Verifying foundation objects..."

for obj in \
  OCX_Source_Intelligence_Run__c \
  OCX_Source_Ingredient__c \
  OCX_Feature_Definition__c \
  OCX_Feature_Ingredient__c \
  OCX_Feature_Template__c
do
  sf sobject describe --target-org "$ORG" --sobject "$obj" --json > "$OUT/describe-$obj.json"
  echo "  OK: $obj"
done

echo
echo "[2/6] Validating seed safety..."

python3 - "$SEED_DIR" <<'PY'
from pathlib import Path
import csv,re,sys

seed=Path(sys.argv[1])

def read(name):
    with (seed/name).open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

ings=read("source_ingredients.csv")
features=read("profile_features.csv")
links=read("profile_feature_links.csv")
templates=read("historical_recipe_templates.csv")

expected={
    "source_ingredients":(ings,304),
    "profile_features":(features,21),
    "profile_feature_links":(links,21),
    "historical_recipe_templates":(templates,172),
}
for name,(rows,count) in expected.items():
    print(f"  {name}: {len(rows)}")
    if len(rows)!=count:
        raise SystemExit(f"ERROR: expected {name}={count}; found {len(rows)}")

text="\n".join(
    (seed/name).read_text(encoding="utf-8",errors="replace")
    for name in [
        "source_ingredients.csv",
        "profile_features.csv",
        "profile_feature_links.csv",
        "historical_recipe_templates.csv",
    ]
)
for token in ("Marumba","Conga"):
    if re.search(rf"\b{token}\b",text,re.I):
        raise SystemExit(f"ERROR: forbidden legacy demo brand found: {token}")

idx={r.get("Canonical_Field_Key__c"):r for r in ings}
src=idx.get("salesforce:Account:Source_ACV__c")
ocx=idx.get("salesforce:Account:OCX_ACV__c")
if not src or src.get("Primary_Source_Role__c")!="PROFILE_INPUT" or src.get("Eligibility_Status__c")!="ELIGIBLE":
    raise SystemExit("ERROR: Source_ACV__c seed boundary is wrong.")
if ocx and ocx.get("Eligibility_Status__c")!="EXCLUDE":
    raise SystemExit("ERROR: OCX_ACV__c seed boundary is wrong.")

print("  PASS: counts, branding, and ACV boundary are correct.")
PY

if [ "$MODE" = "preflight" ]; then
  echo
  echo "============================================================"
  echo "REPRODUCIBLE SEED PREFLIGHT PASSED"
  echo "============================================================"
  echo "No Salesforce records were modified."
  echo "Next:"
  echo "  $0 apply"
  exit 0
fi

echo
echo "[3/6] Creating Source Intelligence run..."

sf data create record \
  --target-org "$ORG" \
  --sobject OCX_Source_Intelligence_Run__c \
  --values "Run_Type__c='Versioned Source Intelligence Seed' Status__c=Running Source_System__c=Salesforce Scope__c='Account Opportunity Case Task' Schema_Version__c=67.0 Dictionary_Version__c=2.0" \
  --json > "$OUT/run.json"

RUN_ID="$(
python3 - "$OUT/run.json" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
r=d.get("result") or {}
rid=r.get("id") or r.get("Id")
if not rid:
    raise SystemExit("ERROR: could not resolve created run Id.")
print(rid)
PY
)"

echo "  Run Id: $RUN_ID"

echo
echo "[4/6] Materializing run-scoped payloads..."

python3 - "$SEED_DIR" "$OUT" "$RUN_ID" <<'PY'
from pathlib import Path
import csv,sys

seed=Path(sys.argv[1]); out=Path(sys.argv[2]); run_id=sys.argv[3]

def read(name):
    with (seed/name).open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

def write(name,rows):
    with (out/name).open("w",encoding="utf-8",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()),lineterminator="\n")
        w.writeheader(); w.writerows(rows)

ings=[]
for r in read("source_ingredients.csv"):
    ck=r["Canonical_Field_Key__c"]
    ings.append({
        **r,
        "OCX_Run__c":run_id,
        "Ingredient_Key__c":f"{run_id}:{ck}",
    })
write("source_ingredients.csv",ings)

features=[]
for r in read("profile_features.csv"):
    r=dict(r)
    stable=r.pop("Stable_Feature_Key")
    features.append({
        **r,
        "OCX_Run__c":run_id,
        "Feature_Key__c":f"{run_id}:{stable}",
    })
write("profile_features.csv",features)
PY

echo
echo "[5/6] Writing catalog..."

sf data upsert bulk \
  --target-org "$ORG" \
  --sobject OCX_Source_Ingredient__c \
  --file "$OUT/source_ingredients.csv" \
  --external-id Ingredient_Key__c \
  --line-ending LF \
  --wait 10

sf data upsert bulk \
  --target-org "$ORG" \
  --sobject OCX_Feature_Definition__c \
  --file "$OUT/profile_features.csv" \
  --external-id Feature_Key__c \
  --line-ending LF \
  --wait 10

sf data upsert bulk \
  --target-org "$ORG" \
  --sobject OCX_Feature_Template__c \
  --file "$SEED_DIR/historical_recipe_templates.csv" \
  --external-id Template_Key__c \
  --line-ending LF \
  --wait 10

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Canonical_Field_Key__c FROM OCX_Source_Ingredient__c WHERE OCX_Run__c = '$RUN_ID'" \
  --result-format csv \
  --output-file "$OUT/ingredient_ids.csv"

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Feature_Key__c FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$RUN_ID'" \
  --result-format csv \
  --output-file "$OUT/feature_ids.csv"

python3 - "$SEED_DIR" "$OUT" "$RUN_ID" <<'PY'
from pathlib import Path
import csv,sys

seed=Path(sys.argv[1]); out=Path(sys.argv[2]); run_id=sys.argv[3]

def read(path):
    with path.open(encoding="utf-8-sig",newline="") as f:
        return list(csv.DictReader(f))

ingredients={r["Canonical_Field_Key__c"]:r["Id"] for r in read(out/"ingredient_ids.csv")}
features={}
for r in read(out/"feature_ids.csv"):
    key=r["Feature_Key__c"]
    prefix=run_id+":"
    if key.startswith(prefix):
        features[key[len(prefix):]]=r["Id"]

rows=[]
for r in read(seed/"profile_feature_links.csv"):
    stable=r["Stable_Feature_Key"]
    ck=r["Canonical_Field_Key__c"]
    if stable not in features:
        raise SystemExit(f"ERROR: missing feature id for {stable}")
    if ck not in ingredients:
        raise SystemExit(f"ERROR: missing ingredient id for {ck}")
    rows.append({
        "OCX_Feature_Definition__c":features[stable],
        "OCX_Source_Ingredient__c":ingredients[ck],
        "Ingredient_Role__c":r["Ingredient_Role__c"],
        "Sequence__c":r["Sequence__c"],
        "Transform__c":r["Transform__c"],
        "Is_Time_Field__c":r["Is_Time_Field__c"],
        "Is_Grouping_Field__c":r["Is_Grouping_Field__c"],
        "Is_Filter_Field__c":r["Is_Filter_Field__c"],
        "Is_Cohort_Dimension__c":r["Is_Cohort_Dimension__c"],
        "Is_Benchmark_Feature__c":r["Is_Benchmark_Feature__c"],
    })

with (out/"profile_feature_links.csv").open("w",encoding="utf-8",newline="") as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0].keys()),lineterminator="\n")
    w.writeheader(); w.writerows(rows)
PY

sf data import bulk \
  --target-org "$ORG" \
  --sobject OCX_Feature_Ingredient__c \
  --file "$OUT/profile_feature_links.csv" \
  --line-ending LF \
  --wait 10

echo
echo "[6/6] Verifying and completing run..."

sf data query --target-org "$ORG" \
  --query "SELECT COUNT(Id) qty FROM OCX_Source_Ingredient__c WHERE OCX_Run__c = '$RUN_ID'" \
  --result-format json > "$OUT/count-ingredients.json"

sf data query --target-org "$ORG" \
  --query "SELECT COUNT(Id) qty FROM OCX_Feature_Definition__c WHERE OCX_Run__c = '$RUN_ID'" \
  --result-format json > "$OUT/count-features.json"

sf data query --target-org "$ORG" \
  --query "SELECT COUNT(Id) qty FROM OCX_Feature_Ingredient__c WHERE OCX_Feature_Definition__r.OCX_Run__c = '$RUN_ID'" \
  --result-format json > "$OUT/count-links.json"

sf data query --target-org "$ORG" \
  --query "SELECT COUNT(Id) qty FROM OCX_Feature_Template__c WHERE Dictionary_Version__c = '2.0-historical-prior'" \
  --result-format json > "$OUT/count-templates.json"

python3 - "$OUT" <<'PY'
from pathlib import Path
import json,sys
d=Path(sys.argv[1])
def count(name):
    x=json.loads((d/name).read_text())
    r=((x.get("result") or {}).get("records") or [{}])[0]
    return int(r.get("qty",r.get("expr0",0)))
vals={
    "ingredients":count("count-ingredients.json"),
    "features":count("count-features.json"),
    "links":count("count-links.json"),
    "templates":count("count-templates.json"),
}
print("FINAL REPRODUCIBILITY VERIFICATION")
print("----------------------------------")
for k,v in vals.items():
    print(f"{k}: {v}")
exp={"ingredients":304,"features":21,"links":21,"templates":172}
for k,v in exp.items():
    if vals[k]!=v:
        raise SystemExit(f"ERROR: expected {k}={v}; found {vals[k]}")
print("PASS: versioned seeds reproduced the approved catalog.")
PY

sf data update record \
  --target-org "$ORG" \
  --sobject OCX_Source_Intelligence_Run__c \
  --record-id "$RUN_ID" \
  --values "Status__c=Complete Ingredient_Count__c=304 Feature_Definition_Count__c=21 Profile_Feature_Count__c=21 Direct_Experience_Count__c=0 Cohort_Derived_Count__c=0"

echo
echo "============================================================"
echo "REPRODUCIBLE SOURCE INTELLIGENCE SEED COMPLETE"
echo "============================================================"
echo "Run Id: $RUN_ID"
echo "No Account, Opportunity, Case, or Task records were modified."
echo "============================================================"
