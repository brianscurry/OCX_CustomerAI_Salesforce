#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORG="${ORG:-OCXDemo}"

usage() {
  cat <<'USAGE'
Usage:
  32_stage_driver_kpi_discovery_preflight.sh --stage "Support" --driver "Effectiveness of Resolution" [--top 15]
  32_stage_driver_kpi_discovery_preflight.sh "Support" "Effectiveness of Resolution" [15]

READ ONLY.
Builds ranked Direct Experience KPI candidates from the Salesforce-resident
Customer AI Source Intelligence catalog. It does not create or update Salesforce
records.

Examples:
  ~/Downloads/32_stage_driver_kpi_discovery_preflight.sh \
    --stage "Support" \
    --driver "Effectiveness of Resolution" \
    --top 15

  ~/Downloads/32_stage_driver_kpi_discovery_preflight.sh \
    --stage "Renewal" \
    --driver "Confidence in Value" \
    --top 15
USAGE
}

STAGE=""
DRIVER=""
TOP=15

if [ "$#" -gt 0 ] && [[ "${1:-}" != --* ]]; then
  STAGE="${1:-}"
  DRIVER="${2:-}"
  TOP="${3:-15}"
else
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
fi

if [ -z "$STAGE" ] || [ -z "$DRIVER" ]; then
  echo "ERROR: both Stage and Driver are required."
  usage
  exit 1
fi

if ! [[ "$TOP" =~ ^[0-9]+$ ]] || [ "$TOP" -lt 5 ] || [ "$TOP" -gt 50 ]; then
  echo "ERROR: --top must be an integer between 5 and 50."
  exit 1
fi

cd "$PROJECT"

STAMP="$(date +%Y%m%d_%H%M%S)"
SAFE_STAGE="$(printf '%s' "$STAGE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
SAFE_DRIVER="$(printf '%s' "$DRIVER" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
OUT="$PROJECT/.ocx/kpi-discovery-${SAFE_STAGE}-${SAFE_DRIVER}-${STAMP}"
mkdir -p "$OUT"

echo
echo "============================================================"
echo "CUSTOMER AI — STAGE / DRIVER KPI DISCOVERY PREFLIGHT v7"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Stage:   $STAGE"
echo "Driver:  $DRIVER"
echo "Top:     $TOP"
echo "Output:  $OUT"
echo
echo "READ ONLY."
echo "No Salesforce records or metadata will be modified."
echo
echo "Purpose:"
echo "  - infer the most relevant CX themes for this Stage + Driver"
echo "  - rank eligible Direct Experience ingredients"
echo "  - reuse resolved historical recipe priors as evidence"
echo "  - propose explainable KPI formulas"
echo "  - label every proposal as NOT_TESTED until empirical validation"
echo "============================================================"
echo

echo "[1/5] Finding the latest completed Source Intelligence run..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Name,Status__c,Ingredient_Count__c,Feature_Definition_Count__c,Completed_At__c,CreatedDate FROM OCX_Source_Intelligence_Run__c WHERE Status__c = 'Complete' ORDER BY CreatedDate DESC LIMIT 1" \
  --result-format json > "$OUT/run.json"

RUN_ID="$(
python3 - "$OUT/run.json" <<'PY'
import json, sys
from pathlib import Path

d = json.loads(Path(sys.argv[1]).read_text())
rows = ((d.get("result") or {}).get("records") or [])
if not rows:
    raise SystemExit("ERROR: no completed OCX Source Intelligence run exists.")
r = rows[0]
rid = r.get("Id")
if not rid:
    raise SystemExit("ERROR: completed Source Intelligence run has no Id.")
print(rid)
PY
)"

echo "  Run Id: $RUN_ID"

echo
echo "[2/5] Reading eligible Source Ingredients..."

sf data query \
  --target-org "$ORG" \
  --query "SELECT Id,Name,Canonical_Field_Key__c,Source_Object__c,Source_Field__c,Field_Label__c,Field_Type__c,Grain__c,Account_Path__c,Business_Concept__c,Observation_Type__c,Primary_Theme__c,Secondary_Themes__c,Measurement_Concepts__c,Primary_Source_Role__c,Source_Roles__c,Provenance_Role__c,Metric_Archetypes__c,Direction_Hypothesis__c,Windowable__c,Aggregatable__c,Coverage_Pct__c,Populated_Count__c,Distinct_Count__c,Predictive_Prior_Score__c,Explainability_Score__c,Actionability_Score__c,Controllability_Score__c,Stability_Prior_Score__c,Leakage_Risk_Score__c,Source_Confidence_Score__c,Eligibility_Status__c,Classification_Basis__c,Reference_Evidence__c FROM OCX_Source_Ingredient__c WHERE OCX_Run__c = '$RUN_ID' AND Eligibility_Status__c = 'ELIGIBLE' AND Primary_Source_Role__c IN ('DIRECT_EXPERIENCE_INPUT','LINKAGE') ORDER BY Source_Object__c,Source_Field__c" \
  --result-format json > "$OUT/ingredients.json"

echo
echo "[3/5] Reading historical recipe priors and CX theme dictionary..."

# Do not assume optional template fields exist in the live org.
# The first version of this script assumed Default_Window__c, but the
# deployed OCX_Feature_Template__c schema does not expose that field.
# Build the SELECT list from live Describe so discovery survives schema drift.
sf sobject describe \
  --target-org "$ORG" \
  --sobject OCX_Feature_Template__c \
  --json > "$OUT/template-describe.json"

TEMPLATE_FIELDS="$(
python3 - "$OUT/template-describe.json" "$OUT/template-schema-summary.txt" <<'PY'
import json
import sys
from pathlib import Path

describe_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])

d = json.loads(describe_path.read_text())
result = d.get("result") or d
available = {f.get("name") for f in (result.get("fields") or []) if f.get("name")}

required = {
    "Id",
    "Name",
    "Template_Key__c",
    "Target_Feature_Class__c",
    "Active__c",
}

missing_required = sorted(required - available)
if missing_required:
    raise SystemExit(
        "ERROR: OCX_Feature_Template__c is missing required discovery fields: "
        + ", ".join(missing_required)
    )

desired = [
    "Id",
    "Name",
    "Template_Key__c",
    "Target_Feature_Class__c",
    "Feature_Type__c",
    "Primary_Theme_Key__c",
    "Measurement_Concept_Key__c",
    "Archetype__c",
    "Required_Ingredient_Roles__c",
    "Formula_Template__c",
    "Default_Bucketing_Strategy__c",
    # Window fields are optional. Query whichever one actually exists.
    "Default_Window__c",
    "Default_Window_Days__c",
    "Window_Days__c",
    "Window__c",
    "Direction_Hypothesis__c",
    "Predictive_Prior__c",
    "Explainability_Prior__c",
    "Cohort_Suitability_Prior__c",
    "Historical_Prior_Score__c",
    "Evidence_Basis__c",
    "Description__c",
    "Active__c",
    "Dictionary_Version__c",
]

selected = [f for f in desired if f in available]
missing_optional = [f for f in desired if f not in available]

window_candidates = [
    f for f in [
        "Default_Window__c",
        "Default_Window_Days__c",
        "Window_Days__c",
        "Window__c",
    ]
    if f in available
]

summary = [
    "OCX_Feature_Template__c LIVE SCHEMA",
    "-----------------------------------",
    f"selected_fields: {len(selected)}",
    "window_field: " + (window_candidates[0] if window_candidates else "<none; discovery defaults to 90d>"),
    "missing_optional: " + (", ".join(missing_optional) if missing_optional else "<none>"),
]
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")

print(",".join(selected))
PY
)"

cat "$OUT/template-schema-summary.txt"

sf data query \
  --target-org "$ORG" \
  --query "SELECT $TEMPLATE_FIELDS FROM OCX_Feature_Template__c WHERE Active__c = true AND Target_Feature_Class__c = 'DIRECT_EXPERIENCE' ORDER BY Template_Key__c" \
  --result-format json > "$OUT/templates.json"

sf data query \
  --target-org "$ORG" \
  --query "SELECT Theme_Key__c,Name,Description__c,Sort_Order__c FROM OCX_CX_Theme__c WHERE Active__c = true ORDER BY Sort_Order__c" \
  --result-format json > "$OUT/themes.json"

sf data query \
  --target-org "$ORG" \
  --query "SELECT Name,Theme_Key__c,Concept_Key__c,Description__c,Dictionary_Version__c FROM OCX_CX_Concept__c WHERE Active__c = true ORDER BY Theme_Key__c,Name" \
  --result-format json > "$OUT/concepts.json"

echo
echo "[4/5] Generating and ranking KPI candidates..."

python3 - \
  "$STAGE" \
  "$DRIVER" \
  "$TOP" \
  "$OUT" <<'PY'
from pathlib import Path
from collections import Counter, defaultdict
import csv
import json
import math
import re
import sys

stage = sys.argv[1].strip()
driver = sys.argv[2].strip()
top_n = int(sys.argv[3])
out = Path(sys.argv[4])

THEMES = [
    "PEOPLE",
    "PROCESS",
    "TIME",
    "INFORMATION",
    "PRODUCT_SERVICE",
    "VALUE",
]

STOP = {
    "a","an","and","are","as","at","be","by","for","from","how","in","into",
    "is","it","of","on","or","our","the","their","to","with","within","customer",
    "customers","stage","driver","experience",
}

# These are meaning priors, not hard mappings.
THEME_LEXICON = {
    "PEOPLE": {
        "people","rep","reps","agent","agents","owner","manager","csm","consultant",
        "support","assignment","assigned","handoff","engagement","contact","interaction",
        "training","trained","certification","certified","role","roles","tenure",
        "staff","staffing","coverage","relationship","expert","expertise","skill","skills",
        "capacity","continuity",
    },
    "PROCESS": {
        "process","workflow","step","steps","effort","friction","escalation","escalated",
        "resolution","resolve","resolved","implementation","onboarding","approval",
        "handoff","rework","cycle","case","cases","ticket","tickets","queue","status",
        "stage","stages","transition","completion","closed","open","routing","procedure",
        "complexity","smooth","ease","effective","effectiveness",
    },
    "TIME": {
        "time","timely","speed","fast","slow","duration","days","hours","response",
        "resolution","age","aging","ageing","recency","delay","delayed","wait","waiting",
        "cycle","timeline","predictability","overdue","due","close","closed","renewal",
        "latency","elapsed","sla",
    },
    "INFORMATION": {
        "information","communication","clarity","clear","accurate","accuracy","helpful",
        "guidance","documentation","document","knowledge","brief","subject","description",
        "message","messages","conversation","email","meeting","chat","understanding",
        "expectation","expectations","visibility","status","update","updates","content",
    },
    "PRODUCT_SERVICE": {
        "product","service","feature","features","usability","reliability","integration",
        "bug","defect","severity","critical","support","case","ticket","incident",
        "performance","quality","availability","usage","adoption","platform","license",
        "community","configuration","root","cause",
    },
    "VALUE": {
        "value","roi","return","revenue","arr","acv","renewal","renew","expansion",
        "upsell","commercial","business","outcome","benefit","benefits","price","cost",
        "contract","retention","confidence","realize","realized","realization",
        "adoption","usage",
    },
}

STAGE_PRIORS = {
    "support": {"PROCESS": 0.20, "TIME": 0.20, "PEOPLE": 0.15, "PRODUCT_SERVICE": 0.20, "INFORMATION": 0.15},
    "implementation": {"PROCESS": 0.22, "TIME": 0.20, "PEOPLE": 0.18, "INFORMATION": 0.15, "PRODUCT_SERVICE": 0.10},
    "onboarding": {"PROCESS": 0.22, "TIME": 0.18, "PEOPLE": 0.18, "INFORMATION": 0.18},
    "renewal": {"VALUE": 0.25, "PEOPLE": 0.15, "PROCESS": 0.12, "TIME": 0.12, "PRODUCT_SERVICE": 0.12},
    "purchase": {"VALUE": 0.22, "PROCESS": 0.18, "INFORMATION": 0.15, "PEOPLE": 0.12},
    "sales": {"VALUE": 0.22, "PROCESS": 0.18, "INFORMATION": 0.15, "PEOPLE": 0.12},
}

DRIVER_PRIORS = {
    "resolution": {"PROCESS": 0.25, "TIME": 0.22, "PRODUCT_SERVICE": 0.18, "PEOPLE": 0.12, "INFORMATION": 0.10},
    "effectiveness": {"PROCESS": 0.18, "PRODUCT_SERVICE": 0.18, "PEOPLE": 0.12, "VALUE": 0.08},
    "confidence": {"VALUE": 0.22, "INFORMATION": 0.18, "PEOPLE": 0.12, "PRODUCT_SERVICE": 0.10},
    "value": {"VALUE": 0.30, "PRODUCT_SERVICE": 0.12, "INFORMATION": 0.10, "PEOPLE": 0.08},
    "clarity": {"INFORMATION": 0.28, "PROCESS": 0.18, "PEOPLE": 0.10},
    "ease": {"PROCESS": 0.26, "TIME": 0.12, "INFORMATION": 0.10},
    "reliability": {"PRODUCT_SERVICE": 0.30, "TIME": 0.10, "PROCESS": 0.08},
    "responsiveness": {"TIME": 0.30, "PEOPLE": 0.14, "PROCESS": 0.12},
    "speed": {"TIME": 0.34, "PROCESS": 0.10},
    "communication": {"INFORMATION": 0.28, "PEOPLE": 0.18},
    "relationship": {"PEOPLE": 0.26, "VALUE": 0.12, "INFORMATION": 0.10},
    "quality": {"PRODUCT_SERVICE": 0.20, "PROCESS": 0.14, "INFORMATION": 0.10},
}

def sf_records(name):
    d = json.loads((out/name).read_text())
    return (d.get("result") or {}).get("records") or []

def clean_sf(r):
    return {k:v for k,v in r.items() if k != "attributes"}

ingredients = [clean_sf(r) for r in sf_records("ingredients.json")]
templates = [clean_sf(r) for r in sf_records("templates.json")]
themes = [clean_sf(r) for r in sf_records("themes.json")]
concepts = [clean_sf(r) for r in sf_records("concepts.json")]

def words(s):
    toks = re.findall(r"[a-z0-9]+", str(s or "").lower())
    return [t for t in toks if len(t) >= 2 and t not in STOP]

def norm_theme(s):
    s = str(s or "").upper().strip()
    s = s.replace("/", "_").replace(" ", "_").replace("-", "_")
    if s in {"PRODUCT", "PRODUCTSERVICE", "PRODUCT__SERVICE"}:
        return "PRODUCT_SERVICE"
    return s

def clamp(v):
    return max(0.0, min(1.0, float(v)))

def num(v, default=0.0):
    if v is None or v == "":
        return default
    try:
        return float(v)
    except Exception:
        return default

def pct_score(v):
    x = num(v, 0.0)
    if x > 1:
        x /= 100.0
    return clamp(x)

query_tokens = set(words(stage + " " + driver))
stage_tokens = set(words(stage))
driver_tokens = set(words(driver))

theme_scores = {t: 0.05 for t in THEMES}

# Literal semantic overlap.
for theme, lex in THEME_LEXICON.items():
    overlap = query_tokens & lex
    theme_scores[theme] += min(0.55, 0.11 * len(overlap))

# Stage priors.
stage_norm = " ".join(words(stage))
for key, priors in STAGE_PRIORS.items():
    if key in stage_norm:
        for theme, boost in priors.items():
            theme_scores[theme] += boost

# Driver priors.
driver_norm = " ".join(words(driver))
for key, priors in DRIVER_PRIORS.items():
    if key in driver_norm:
        for theme, boost in priors.items():
            theme_scores[theme] += boost

# Use the actual theme/concept dictionary as a light semantic prior.
for c in concepts:
    text = " ".join([
        c.get("Name",""),
        c.get("Concept_Key__c",""),
        c.get("Description__c",""),
    ])
    ct = set(words(text))
    overlap = len(query_tokens & ct)
    if overlap:
        theme = norm_theme(c.get("Theme_Key__c"))
        if theme in theme_scores:
            theme_scores[theme] += min(0.20, 0.04 * overlap)

mx = max(theme_scores.values()) or 1.0
theme_scores = {k: clamp(v / mx) for k,v in theme_scores.items()}
ranked_themes = sorted(theme_scores.items(), key=lambda x:(-x[1], x[0]))
active_themes = [t for t,s in ranked_themes if s >= 0.45][:4]
if not active_themes:
    active_themes = [ranked_themes[0][0]]

def split_multi(s):
    return [
        norm_theme(x)
        for x in re.split(r"[;,|]+", str(s or ""))
        if x.strip()
    ]

def text_match_score(text):
    wt = set(words(text))
    if not query_tokens or not wt:
        return 0.0
    exact = len(query_tokens & wt)
    jacc = exact / len(query_tokens | wt)
    containment = exact / max(1, len(query_tokens))
    return clamp(0.60 * containment + 0.40 * jacc)

def ingredient_theme_score(r):
    its = []
    if r.get("Primary_Theme__c"):
        its.append(norm_theme(r["Primary_Theme__c"]))
    its.extend(split_multi(r.get("Secondary_Themes__c")))
    if not its:
        return 0.20
    vals = [theme_scores.get(t,0.0) for t in its]
    return max(vals) if vals else 0.20

def ingredient_text(r):
    return " ".join(str(r.get(k,"") or "") for k in [
        "Field_Label__c","Business_Concept__c","Measurement_Concepts__c",
        "Metric_Archetypes__c","Classification_Basis__c","Reference_Evidence__c",
        "Source_Object__c","Source_Field__c",
    ])

def coverage_score(r):
    c = pct_score(r.get("Coverage_Pct__c"))
    if c == 0 and num(r.get("Populated_Count__c")) > 0:
        # Preserve some data-confidence when older seed rows did not retain
        # a calculated coverage percentage.
        c = 0.70
    return c

def allowed_ingredient(r):
    if r.get("Eligibility_Status__c") != "ELIGIBLE":
        return False
    if r.get("Primary_Source_Role__c") not in {"DIRECT_EXPERIENCE_INPUT","LINKAGE"}:
        return False
    if num(r.get("Leakage_Risk_Score__c"),0.0) >= 0.80:
        return False
    return True

ingredients = [r for r in ingredients if allowed_ingredient(r)]
by_canonical = {r.get("Canonical_Field_Key__c"):r for r in ingredients}
by_field_lower = defaultdict(list)
for r in ingredients:
    by_field_lower[str(r.get("Source_Field__c","")).lower()].append(r)

def archetypes(r):
    vals = [x.strip().upper() for x in re.split(r"[;,|]+", str(r.get("Metric_Archetypes__c") or "")) if x.strip()]
    return vals

def generic_formula(r):
    obj = r.get("Source_Object__c","")
    field = r.get("Source_Field__c","")
    label = r.get("Field_Label__c") or field
    ftype = str(r.get("Field_Type__c") or "").lower()
    arch = archetypes(r)
    ref = f"{obj}.{field}"

    if any(x in arch for x in ["DURATION","AGE"]):
        return f"AVG({ref}) BY Account OVER <window>", "DERIVABLE", "DURATION", f"Average {label}"
    field_hint = f"{field} {label}".lower()
    if "RECENCY" in arch or "date" in ftype or "date" in field_hint:
        return f"DAYS_SINCE(MAX({ref})) BY Account", "DERIVABLE", "RECENCY", f"Recency of {label}"
    if "RATE" in arch or ftype == "boolean":
        if field.lower() == "isclosed":
            if obj == "Case":
                kpi_name = "Case Closure Rate"
            elif obj == "Task":
                kpi_name = "Task Completion Rate"
            elif obj == "Opportunity":
                kpi_name = "Opportunity Closed Rate"
            else:
                kpi_name = f"{label} Rate"
        elif field.lower() == "iswon" and obj == "Opportunity":
            kpi_name = "Opportunity Won Rate"
        else:
            kpi_name = f"{label} Rate"
        return f"SUM(IF({ref}=true,1,0)) / COUNT(*) BY Account OVER <window>", "DERIVABLE", "RATE", kpi_name
    if "COUNT" in arch:
        return f"COUNT({ref}) BY Account OVER <window>", "DERIVABLE", "COUNT", f"{label} Count"
    if "BREADTH" in arch:
        return f"COUNT_DISTINCT({ref}) BY Account OVER <window>", "DERIVABLE", "BREADTH", f"{label} Breadth"
    if "STATE_SHARE" in arch:
        return f"COUNT_IF({ref}=<relevant_state>) / COUNT(*) BY Account OVER <window>", "MAPPING_REQUIRED", "STATE_SHARE", f"{label} Share"
    if "TREND" in arch:
        return f"TREND(AVG({ref}) BY Account OVER <window>)", "DERIVABLE", "TREND", f"{label} Trend"
    if "VARIABILITY" in arch:
        return f"STDDEV({ref}) BY Account OVER <window>", "DERIVABLE", "VARIABILITY", f"{label} Variability"
    if any(x in arch for x in ["MONETARY","RATIO"]):
        return f"AVG({ref}) BY Account OVER <window>", "DERIVABLE", arch[0] if arch else "MEASURE", f"Average {label}"
    if ftype in {"double","currency","int","long","percent"}:
        return f"AVG({ref}) BY Account OVER <window>", "DERIVABLE", "MEASURE", f"Average {label}"
    if ftype in {"picklist","multipicklist","string"}:
        return f"SHARE_BY_VALUE({ref}) BY Account OVER <window>", "MAPPING_REQUIRED", "STATE_SHARE", f"{label} Mix"
    return f"AGGREGATE({ref}) BY Account OVER <window>", "MAPPING_REQUIRED", "MEASURE", f"{label} KPI"

def recommended_window(obj, driver_text):
    d = str(driver_text).lower()
    if "renew" in d:
        return "180d"
    if obj == "Case":
        return "90d"
    if obj == "Task":
        return "90d"
    if obj == "Opportunity":
        return "180d"
    return "90d"

def ingredient_score(r):
    semantic = ingredient_theme_score(r)
    lexical = text_match_score(ingredient_text(r))
    predictive = clamp(num(r.get("Predictive_Prior_Score__c"),0.50))
    explain = clamp(num(r.get("Explainability_Score__c"),0.50))
    action = clamp(num(r.get("Actionability_Score__c"),0.45))
    source_conf = clamp(num(r.get("Source_Confidence_Score__c"),0.70))
    stability = clamp(num(r.get("Stability_Prior_Score__c"),0.65))
    coverage = coverage_score(r)
    leakage = clamp(num(r.get("Leakage_Risk_Score__c"),0.0))

    score = (
        0.25 * semantic +
        0.18 * lexical +
        0.15 * predictive +
        0.11 * explain +
        0.08 * action +
        0.08 * source_conf +
        0.07 * stability +
        0.08 * coverage -
        0.20 * leakage
    )
    return clamp(score), {
        "semantic": semantic,
        "lexical": lexical,
        "predictive": predictive,
        "explainability": explain,
        "actionability": action,
        "source_confidence": source_conf,
        "stability": stability,
        "coverage": coverage,
        "leakage": leakage,
    }

# Rank ingredients first.
ingredient_rank = []
for r in ingredients:
    s, parts = ingredient_score(r)
    ingredient_rank.append((s,r,parts))
ingredient_rank.sort(key=lambda x:(-x[0], x[1].get("Canonical_Field_Key__c","")))

candidate_rows = []

# Generic ingredient-derived proposals.
for score, r, parts in ingredient_rank:
    formula, availability, arch, name = generic_formula(r)
    window = recommended_window(r.get("Source_Object__c",""), driver)
    formula = formula.replace("<window>", window)

    # Categorical shares need a human/model-selected state unless the historical
    # recipe library supplies one.
    if "<relevant_state>" in formula:
        availability = "MAPPING_REQUIRED"

    primary_theme = norm_theme(r.get("Primary_Theme__c"))
    if primary_theme not in THEMES:
        primary_theme = max(
            THEMES,
            key=lambda t: theme_scores.get(t,0.0)
        )

    candidate_rows.append({
        "Candidate_Source": "GENERIC_INGREDIENT",
        "KPI_Name": name,
        "Stage": stage,
        "Driver": driver,
        "Primary_Theme": primary_theme,
        "Theme_Fit": round(parts["semantic"],4),
        "Ingredients": r.get("Canonical_Field_Key__c",""),
        "Formula": formula,
        "Metric_Archetype": arch,
        "Grain": "Account",
        "Window": window,
        "Availability": availability,
        "Empirical_Status": "NOT_TESTED",
        "Predictive_Prior": round(parts["predictive"],4),
        "Explainability": round(parts["explainability"],4),
        "Actionability": round(parts["actionability"],4),
        "Data_Coverage_Score": round(parts["coverage"],4),
        "Historical_Prior": 0.0,
        "Semantic_Score": round(parts["lexical"],4),
        "Candidate_Score": round(score,4),
        "Direction_Hypothesis": r.get("Direction_Hypothesis__c",""),
        "Rationale": (
            f"Eligible {r.get('Primary_Source_Role__c')} from "
            f"{r.get('Source_Object__c')}.{r.get('Source_Field__c')}; "
            f"theme fit={parts['semantic']:.2f}; semantic text fit={parts['lexical']:.2f}; "
            f"coverage prior={parts['coverage']:.2f}. "
            "Correlation is not assumed; validate empirically against the Driver outcome."
        ),
        "Historical_Evidence": r.get("Reference_Evidence__c",""),
        "Source_Object": r.get("Source_Object__c",""),
        "Source_Field": r.get("Source_Field__c",""),
    })

# Historical recipe proposals.
def template_text(t):
    return " ".join(str(t.get(k,"") or "") for k in [
        "Name","Description__c","Primary_Theme_Key__c","Measurement_Concept_Key__c",
        "Archetype__c","Formula_Template__c","Required_Ingredient_Roles__c",
        "Evidence_Basis__c",
    ])

def parse_resolved_fields(evidence):
    text = str(evidence or "")
    fields = []
    # Evidence strings generated earlier include:
    # "Resolved Current Fields=Source_X__c;Source_Y__c"
    for match in re.finditer(r"Resolved Current Fields=([^|]+)", text, flags=re.I):
        chunk = match.group(1)
        chunk = chunk.split("Derived Dependencies=",1)[0]
        for fld in re.split(r"[;,]+", chunk):
            fld=fld.strip()
            if not fld:
                continue
            if "." in fld:
                fields.append(fld)
            else:
                fields.append(fld)
    return list(dict.fromkeys(fields))

def match_fields_to_catalog(fields, t):
    matched = []
    source_hint = ""
    ev = str(t.get("Evidence_Basis__c") or "")
    m = re.search(r"Source=([^;|]+)", ev)
    if m:
        source_hint = m.group(1).lower()
    object_hint = None
    if "support" in source_hint or "case" in source_hint:
        object_hint = "Case"
    elif "opportunit" in source_hint:
        object_hint = "Opportunity"
    elif "account" in source_hint:
        object_hint = "Account"

    for fld in fields:
        fld = fld.strip()
        if not fld:
            continue
        if fld.startswith("salesforce:"):
            if fld in by_canonical:
                matched.append(by_canonical[fld])
            continue
        raw = fld.split(".")[-1]
        opts = by_field_lower.get(raw.lower(),[])
        if object_hint:
            objopts = [r for r in opts if r.get("Source_Object__c") == object_hint]
            if objopts:
                opts = objopts
        if opts:
            matched.append(opts[0])
    # dedupe
    seen=set()
    outm=[]
    for r in matched:
        key=r.get("Canonical_Field_Key__c")
        if key and key not in seen:
            seen.add(key); outm.append(r)
    return outm

for t in templates:
    ttheme = norm_theme(t.get("Primary_Theme_Key__c"))
    theme_fit = theme_scores.get(ttheme, 0.20)
    lexical = text_match_score(template_text(t))
    hist = clamp(num(t.get("Historical_Prior_Score__c"),0.50))
    pred = clamp(num(t.get("Predictive_Prior__c"),0.50))
    explain = clamp(num(t.get("Explainability_Prior__c"),0.65))

    resolved = parse_resolved_fields(t.get("Evidence_Basis__c"))
    matched = match_fields_to_catalog(resolved, t)

    if resolved and not matched:
        # Historical recipe references no currently eligible direct input.
        continue

    # If matched fields exist, fold in their current live source quality.
    if matched:
        current_scores = [ingredient_score(r)[0] for r in matched]
        current_data = sum(coverage_score(r) for r in matched)/len(matched)
        current_fit = sum(current_scores)/len(current_scores)
    else:
        current_data = 0.55
        current_fit = 0.50

    score = clamp(
        0.24 * theme_fit +
        0.18 * lexical +
        0.16 * hist +
        0.13 * pred +
        0.10 * explain +
        0.11 * current_fit +
        0.08 * current_data
    )

    formula = t.get("Formula_Template__c") or "Historical recipe; inspect Evidence_Basis__c"
    raw_window = (
        t.get("Default_Window__c")
        or t.get("Default_Window_Days__c")
        or t.get("Window_Days__c")
        or t.get("Window__c")
        or ""
    )
    if raw_window in ("", None):
        window = "90d"
    else:
        raw_window = str(raw_window).strip()
        window = raw_window if re.search(r"[a-zA-Z]", raw_window) else f"{raw_window}d"
    ingredients_text = ";".join(
        r.get("Canonical_Field_Key__c","") for r in matched
    ) or ";".join(resolved)

    availability = "DERIVABLE" if matched else "MAPPING_REQUIRED"

    # A historical formula with unresolved placeholders is evidence, not an
    # executable current Salesforce KPI.
    if re.search(r"\{[^}]+\}|<[^>]+>", str(formula)):
        availability = "MAPPING_REQUIRED"

    candidate_rows.append({
        "Candidate_Source": "HISTORICAL_RECIPE_PRIOR",
        "KPI_Name": t.get("Name") or t.get("Template_Key__c"),
        "Stage": stage,
        "Driver": driver,
        "Primary_Theme": ttheme if ttheme in THEMES else active_themes[0],
        "Theme_Fit": round(theme_fit,4),
        "Ingredients": ingredients_text,
        "Formula": formula,
        "Metric_Archetype": t.get("Archetype__c",""),
        "Grain": "Account",
        "Window": window,
        "Availability": availability,
        "Empirical_Status": "NOT_TESTED",
        "Predictive_Prior": round(pred,4),
        "Explainability": round(explain,4),
        "Actionability": 0.50,
        "Data_Coverage_Score": round(current_data,4),
        "Historical_Prior": round(hist,4),
        "Semantic_Score": round(lexical,4),
        "Candidate_Score": round(score,4),
        "Direction_Hypothesis": t.get("Direction_Hypothesis__c",""),
        "Rationale": (
            "Resolved historical recipe used only as candidate-generation evidence. "
            f"Current theme fit={theme_fit:.2f}; Stage/Driver semantic fit={lexical:.2f}; "
            f"historical prior={hist:.2f}. Legacy Driver labels do not determine current relevance. "
            "Correlation must be tested on current Driver outcomes."
        ),
        "Historical_Evidence": t.get("Evidence_Basis__c",""),
        "Source_Object": "",
        "Source_Field": "",
    })


# ---------------------------------------------------------------------------
# V3: Driver-intent / causal-proximity reranking.
#
# Theme fit is deliberately not enough. A Product/Service field can be a valid
# source ingredient and still be a poor explanation of "Effectiveness of
# Resolution". This layer asks a second question:
#
#   Is this candidate a plausible observable cause/explanation of THIS Driver?
#
# It also penalizes context/profile-like measures that happen to share a theme.
# ---------------------------------------------------------------------------

INTENT_EXPANSIONS = {
    "resolution": {
        "positive": {
            "resolution","resolve","resolved","ttr","sla","violation","violated",
            "escalation","escalated","ageing","aging","open","close","closed",
            "response","first","reopen","reopened","severity","critical","major",
            "bug","defect","root","cause","special","attention","time","duration",
            "customer","environment","documentation",
        },
        "negative": {
            "support level","free support","product breadth","product line breadth",
            "ticket types present","tickets to prod ratio","seat utilization",
            "license","licenses","territory","region","segment","cohort",
        },
    },
    "effectiveness": {
        "positive": {
            "effective","effectiveness","success","successful","resolved","resolution",
            "sla","escalation","rework","reopen","quality","defect","root","cause",
            "response","duration","time","ageing","aging",
        },
        "negative": {
            "breadth","mix","support level","free support","seat","license",
        },
    },
    "confidence": {
        "positive": {
            "confidence","engagement","renewal","probability","forecast","commit",
            "usage","adoption","value","risk","relationship","activity","meeting",
            "conversation","renew","stage","age","recency",
        },
        "negative": {
            "product breadth","ticket types present",
        },
    },
    "value": {
        "positive": {
            "value","renewal","renew","arr","acv","amount","commercial","revenue",
            "usage","adoption","engagement","expansion","probability","forecast",
            "relationship","benefit","business",
        },
        "negative": {
            "ticket types present","product breadth",
        },
    },
    "clarity": {
        "positive": {
            "clarity","clear","communication","documentation","knowledge","response",
            "description","subject","guidance","information","meeting","email","activity",
        },
        "negative": {"breadth","revenue","amount"},
    },
    "responsiveness": {
        "positive": {
            "response","first","time","duration","sla","ageing","aging","recency",
            "activity","engagement","wait","delay","resolution",
        },
        "negative": {"breadth","revenue","amount"},
    },
    "reliability": {
        "positive": {
            "reliability","bug","defect","severity","critical","root","cause","sla",
            "incident","case","resolution","escalation","product",
        },
        "negative": {"support level","region","segment"},
    },
}

STAGE_OBJECT_PRIORS = {
    "support": {
        "Case": 1.00,
        "Task": 0.82,
        "Opportunity": 0.28,
        "Account": 0.18,
    },
    "renewal": {
        "Opportunity": 1.00,
        "Task": 0.82,
        "Case": 0.62,
        "Account": 0.22,
    },
    "implementation": {
        "Task": 0.90,
        "Case": 0.65,
        "Opportunity": 0.52,
        "Account": 0.20,
    },
    "onboarding": {
        "Task": 0.92,
        "Case": 0.58,
        "Opportunity": 0.50,
        "Account": 0.20,
    },
}

CONTEXT_PHRASES = {
    "support level",
    "free support",
    "product breadth",
    "product line breadth",
    "ticket types present",
    "tickets to prod ratio",
    "seat utilization",
    "license",
    "licenses",
    "region",
    "territory",
    "segment",
    "cohort",
}

def phrase_tokens(text):
    return set(words(text))

def intent_profile():
    q = " ".join(words(stage + " " + driver))
    positive = set(query_tokens)
    negative_phrases = set()
    activated = []
    for trigger, spec in INTENT_EXPANSIONS.items():
        if trigger in q:
            activated.append(trigger)
            positive |= set(spec["positive"])
            negative_phrases |= set(spec["negative"])
    return activated, positive, negative_phrases

ACTIVE_INTENTS, DRIVER_POSITIVE_TERMS, DRIVER_NEGATIVE_PHRASES = intent_profile()

def candidate_object(r):
    if r.get("Source_Object"):
        return r["Source_Object"]
    text = str(r.get("Ingredients") or "")
    objs = []
    for obj in ("Case","Task","Opportunity","Account"):
        if f"salesforce:{obj}:" in text:
            objs.append(obj)
    if objs:
        # Historical recipes can span fields, but current demo recipes are
        # overwhelmingly single-object. Prefer the first observed object.
        return objs[0]
    return ""

def object_fit(r):
    obj = candidate_object(r)
    stage_norm = " ".join(words(stage))
    for key, priors in STAGE_OBJECT_PRIORS.items():
        if key in stage_norm:
            return priors.get(obj, 0.35)
    return 0.60 if obj else 0.50

def candidate_driver_fit(r):
    text = " ".join([
        str(r.get("KPI_Name") or ""),
        str(r.get("Formula") or ""),
        str(r.get("Ingredients") or ""),
        str(r.get("Metric_Archetype") or ""),
        str(r.get("Historical_Evidence") or ""),
    ])
    toks = phrase_tokens(text)
    if not toks:
        return 0.0

    overlap = len(toks & DRIVER_POSITIVE_TERMS)
    denom = max(3, min(12, len(DRIVER_POSITIVE_TERMS)))
    token_fit = min(1.0, overlap / denom * 2.2)

    # Direct query-word match matters more than broad theme resemblance.
    direct = text_match_score(text)

    return clamp(0.68 * token_fit + 0.32 * direct)

def causal_proximity(r):
    name_formula = (
        str(r.get("KPI_Name") or "") + " " +
        str(r.get("Formula") or "") + " " +
        str(r.get("Metric_Archetype") or "")
    ).lower()

    arch = str(r.get("Metric_Archetype") or "").upper()

    if any(k in name_formula for k in (
        "resolution", "sla", "violation", "escalat", "response",
        "ageing", "aging", "reopen", "severity", "bug", "defect",
        "root cause", "time to resolution"
    )):
        return 1.00

    if arch in {"RATE","DURATION","RECENCY","TREND","VARIABILITY"}:
        return 0.82
    if arch in {"COUNT","STATE_SHARE","MEASURE"}:
        return 0.68
    if arch in {"BREADTH","MIX"}:
        return 0.42

    return 0.58

def context_penalty(r):
    text = (
        str(r.get("KPI_Name") or "") + " " +
        str(r.get("Formula") or "") + " " +
        str(r.get("Ingredients") or "")
    ).lower()

    penalty = 0.0

    # Penalize context/profile-like measures unless the Driver explicitly asks
    # for that concept.
    driver_text = (" ".join(words(driver))).lower()
    for phrase in CONTEXT_PHRASES | DRIVER_NEGATIVE_PHRASES:
        if phrase in text and phrase not in driver_text:
            penalty += 0.12

    # Breadth is usually weak for a resolution-quality Driver unless breadth,
    # complexity, variety, or coverage is actually in the Driver semantics.
    if any(x in text for x in ("breadth","ticket types present")):
        if not any(x in driver_text for x in ("breadth","complex","variety","coverage")):
            penalty += 0.14

    return min(0.35, penalty)

def formula_quality_penalty(r):
    formula = str(r.get("Formula") or "")
    name = str(r.get("KPI_Name") or "")
    penalty = 0.0
    warnings = []

    # Averaging a calendar date is not an interpretable experience KPI.
    if re.search(r"\bAVG\s*\([^)]*date", formula, flags=re.I):
        penalty += 0.35
        warnings.append("AVERAGE_CALENDAR_DATE")

    # Raw context ratios can be legitimate but should not outrank direct
    # experience measures for operational Drivers.
    if "tickets to prod ratio" in name.lower():
        penalty += 0.16
        warnings.append("WEAK_CAUSAL_PROXIMITY")

    return penalty, warnings

reranked = []
for r in candidate_rows:
    old_score = float(r["Candidate_Score"])
    driver_fit = candidate_driver_fit(r)
    obj_fit = object_fit(r)
    causal = causal_proximity(r)
    ctx_penalty = context_penalty(r)
    fq_penalty, warnings = formula_quality_penalty(r)

    adjusted = clamp(
        0.48 * old_score +
        0.27 * driver_fit +
        0.13 * obj_fit +
        0.12 * causal -
        ctx_penalty -
        fq_penalty
    )

    r["Original_Prior_Score"] = round(old_score, 4)
    r["Driver_Fit_Score"] = round(driver_fit, 4)
    r["Stage_Object_Fit"] = round(obj_fit, 4)
    r["Causal_Proximity"] = round(causal, 4)
    r["Context_Penalty"] = round(ctx_penalty, 4)
    r["Quality_Warnings"] = ";".join(warnings)
    r["Candidate_Score"] = round(adjusted, 4)

    # Hard suppress semantically nonsensical calendar-date averages.
    if "AVERAGE_CALENDAR_DATE" in warnings:
        continue

    reranked.append(r)

candidate_rows = reranked


# ---------------------------------------------------------------------------
# V4: candidate hygiene, concept-family diversity, and explicit target gaps.
# ---------------------------------------------------------------------------

NON_MEASURE_HINTS = {
    "email","phone","fax","website","url","name","account number","record type",
    "id","identifier","postal code","street","city","country code","state code",
}

COMMUNICATION_DRIVER_HINTS = {
    "communication","clarity","contact","reach","responsive","responsiveness",
    "availability","access","relationship",
}

def candidate_text(r):
    return " ".join([
        str(r.get("KPI_Name") or ""),
        str(r.get("Formula") or ""),
        str(r.get("Ingredients") or ""),
        str(r.get("Source_Field") or ""),
    ]).lower()

def is_non_measure_candidate(r):
    txt = candidate_text(r)
    driver_txt = (" ".join(words(driver))).lower()
    source_field = str(r.get("Source_Field") or "")
    ingredients_text = str(r.get("Ingredients") or "")

    # Hard stop for identifier-like fields being turned into measures.
    id_like = False
    for raw in [source_field] + [
        x.split(":")[-1].strip()
        for x in ingredients_text.split(";")
        if x.strip()
    ]:
        if not raw:
            continue
        if re.search(r"(^Id$|Id$|ID__c$|_ID__c$|Identifier)", raw, flags=re.I):
            id_like = True
            break

    # Case Number is a legitimate event-count denominator even though it is an
    # identifier-like value. It is explicitly exempted.
    if id_like and "case_number" not in ingredients_text.lower() and "case number" not in txt:
        return True

    # If the Driver is explicitly about communication/contact, allow contact/channel
    # fields to survive for downstream review.
    communication_context = any(x in driver_txt for x in COMMUNICATION_DRIVER_HINTS)

    hits = [h for h in NON_MEASURE_HINTS if re.search(rf"\b{re.escape(h)}\b", txt)]
    if not hits:
        return False

    meaningful = any(x in txt for x in (
        "case number","opportunity age","response","resolution","renewal",
        "forecast","probability","severity","root cause","bug","sla","escalat",
    ))
    if meaningful:
        return False

    if communication_context and any(x in txt for x in ("email","phone","contact")):
        return False

    return True

def concept_family(r):
    txt = candidate_text(r)
    arch = str(r.get("Metric_Archetype") or "").upper()

    rules = [
        ("RESOLUTION_RATE", ("resolution rate","resolved rate","% resolved","resolved cases")),
        ("RESOLUTION_TIME", ("time to resolution","ttr","resolution days")),
        ("OPEN_CASE_AGE", ("ageing of open","aging of open","open case age")),
        ("SLA", ("sla","slt","service level violation")),
        ("FIRST_RESPONSE", ("first response",)),
        ("ESCALATION", ("escalat",)),
        ("ROOT_CAUSE_MIX", ("root cause","ticket type - customer environment",
                            "ticket type - documentation","% defect tickets")),
        ("BUG_DEFECT", ("bug rate","defect rate","bug","defect")),
        ("SEVERITY_MIX", ("severity","critical","major","mission critical")),
        ("SUPPORT_TIER", ("support level","free support","level 1","level 2")),
        ("PRODUCT_BREADTH", ("product breadth","product line breadth","ticket types present")),
        ("RENEWAL_PROBABILITY", ("renewal probability","probability")),
        ("FORECAST", ("forecast",)),
        ("ENGAGEMENT", ("engagement type","open activity","activity rate","interaction frequency","meeting","call duration")),
        ("OPPORTUNITY_AGE", ("opportunity age","age days")),
        ("COMMERCIAL_VALUE", ("arr","renewal dollars","total renewal due","average acv","amount")),
        ("RENEWAL_TIMING", ("renewal due","estimated close","created date","renewal timing")),
        ("CASE_CLOSURE", ("case closed rate","case.isclosed")),
        ("TASK_COMPLETION", ("task closed rate","task.isclosed")),
        ("OPPORTUNITY_CLOSE", ("opportunity closed rate","opportunity.isclosed")),
        ("OPPORTUNITY_WIN", ("won rate","opportunity.iswon")),
    ]
    for family, phrases in rules:
        if any(p in txt for p in phrases):
            return family

    # Fall back to archetype + primary ingredient to avoid duplicate generic variants.
    ingredients = [x.strip() for x in str(r.get("Ingredients") or "").split(";") if x.strip()]
    base = ingredients[0] if ingredients else re.sub(r"\W+","_",str(r.get("KPI_Name") or "").upper())
    return f"{arch or 'MEASURE'}::{base}"

# Remove candidates that are not plausible measures at all.
candidate_rows = [r for r in candidate_rows if not is_non_measure_candidate(r)]

for r in candidate_rows:
    r["Concept_Family"] = concept_family(r)


# ---------------------------------------------------------------------------
# V6: object-aware semantics and contextual-slice downranking.
#
# Generic field names such as IsClosed mean different things on Case, Task, and
# Opportunity. Likewise, product/support-tier slices are useful segmentation
# context but should not outrank direct operational measures unless the Driver
# actually asks about that context.
# ---------------------------------------------------------------------------

CONTEXT_SLICE_TERMS = {
    "support subscription",
    "support level",
    "support tier",
    "free support",
    "product line",
    "product family",
    "tickets for ",
    "tickets under ",
    "by product",
    "product mix",
}

def current_stage_key():
    s = " ".join(words(stage)).lower()
    for key in ("support","renewal","implementation","onboarding","sales","purchase"):
        if key in s:
            return key
    return ""

def driver_requests_context():
    d = " ".join(words(driver)).lower()
    return any(
        phrase in d
        for phrase in (
            "product","service level","support level","support tier","subscription",
            "segment","region","industry","package","plan","edition"
        )
    )

def object_semantic_penalty(r):
    obj = candidate_object(r)
    field = str(r.get("Source_Field") or "").lower()
    name = str(r.get("KPI_Name") or "").lower()
    stage_key = current_stage_key()

    penalty = 0.0
    warnings = []

    # "Closed Rate" is only semantically aligned to support resolution when it
    # comes from Case. Task.IsClosed means task completion; Opportunity.IsClosed
    # means commercial close. The same API-name pattern must not be treated as
    # one universal experience measure.
    if field == "isclosed" or name == "closed rate":
        if stage_key == "support" and obj != "Case":
            penalty += 0.32
            warnings.append("OBJECT_SEMANTIC_MISMATCH")
        elif stage_key == "renewal" and obj == "Task":
            penalty += 0.24
            warnings.append("OBJECT_SEMANTIC_MISMATCH")
        elif stage_key in {"implementation","onboarding"} and obj == "Opportunity":
            penalty += 0.22
            warnings.append("OBJECT_SEMANTIC_MISMATCH")

    # Opportunity win/loss is a commercial result. It can be useful context for
    # Renewal but is too close to an outcome to be a strong generic Direct
    # Experience candidate without temporal validation.
    if obj == "Opportunity" and field in {"iswon","isclosed"}:
        penalty += 0.08
        warnings.append("COMMERCIAL_OUTCOME_PROXIMITY")

    return min(0.40, penalty), warnings

def contextual_slice_penalty(r):
    txt = candidate_text(r)
    if driver_requests_context():
        return 0.0, []

    hits = [term for term in CONTEXT_SLICE_TERMS if term in txt]
    if not hits:
        return 0.0, []

    # Historical product/support slices remain available as explanatory drill
    # dimensions, but they should not dominate the primary KPI shortlist.
    return min(0.22, 0.10 + 0.04 * len(hits)), ["CONTEXTUAL_SLICE"]

cleaned_rows = []
for r in candidate_rows:
    obj_penalty, obj_warn = object_semantic_penalty(r)
    ctx2_penalty, ctx2_warn = contextual_slice_penalty(r)

    score = float(r["Candidate_Score"])
    score = clamp(score - obj_penalty - ctx2_penalty)

    existing_penalty = float(r.get("Context_Penalty") or 0.0)
    r["Context_Penalty"] = round(
        min(0.60, existing_penalty + obj_penalty + ctx2_penalty), 4
    )

    existing_warnings = [
        x for x in str(r.get("Quality_Warnings") or "").split(";") if x
    ]
    r["Quality_Warnings"] = ";".join(
        list(dict.fromkeys(existing_warnings + obj_warn + ctx2_warn))
    )
    r["Candidate_Score"] = round(score, 4)

    # Hard suppress clear object-semantic mismatches when a directly relevant
    # object exists for the current stage. This removes Task/Opportunity
    # "Closed Rate" from Support without banning those fields globally.
    if "OBJECT_SEMANTIC_MISMATCH" in obj_warn and obj_penalty >= 0.30:
        continue

    cleaned_rows.append(r)

candidate_rows = cleaned_rows


# ---------------------------------------------------------------------------
# V7: suppress contact-coordinate / person-attribute pseudo-KPIs.
#
# Examples: ContactMobile, SuppliedPhone, email address, mailing address.
# These may be useful for linkage or communication-channel context, but they
# should not become standalone Direct Experience KPIs.
# ---------------------------------------------------------------------------

CONTACT_COORDINATE_TERMS = {
    "email","phone","mobile","fax","street","postal","zipcode","zip code",
    "address","website","url",
}

def is_contact_coordinate_pseudo_kpi(r):
    txt = candidate_text(r)
    field = str(r.get("Source_Field") or "").lower()
    label = str(r.get("KPI_Name") or "").lower()
    driver_txt = " ".join(words(driver)).lower()

    # If the Driver explicitly concerns communication channel availability,
    # retain for review; otherwise suppress as a KPI measure.
    explicit_channel_driver = any(
        phrase in driver_txt
        for phrase in (
            "communication channel",
            "contactability",
            "reachability",
            "phone",
            "email",
            "channel availability",
        )
    )
    if explicit_channel_driver:
        return False

    if any(term in field for term in CONTACT_COORDINATE_TERMS):
        return True

    if any(term in label for term in CONTACT_COORDINATE_TERMS):
        return True

    # Also catch generated generic names such as "Contact Mobile KPI".
    if re.search(r"\bcontact\b.*\b(email|phone|mobile|fax|address)\b", txt):
        return True

    return False

candidate_rows = [
    r for r in candidate_rows
    if not is_contact_coordinate_pseudo_kpi(r)
]

# Dedupe semantically similar proposals.
def canonical_candidate_key(r):
    name = " ".join(words(r["KPI_Name"]))
    formula = re.sub(r"\s+"," ",str(r["Formula"]).lower()).strip()
    ingredients_key = ";".join(sorted(
        x.strip() for x in str(r["Ingredients"]).split(";") if x.strip()
    ))
    return (name, formula, ingredients_key)

best = {}
for r in candidate_rows:
    key = canonical_candidate_key(r)
    old = best.get(key)
    if old is None or float(r["Candidate_Score"]) > float(old["Candidate_Score"]):
        best[key] = r
candidate_rows = list(best.values())

# Keep useful thematic diversity rather than letting one family dominate.
candidate_rows.sort(
    key=lambda r: (
        -float(r["Candidate_Score"]),
        0 if r["Candidate_Source"]=="HISTORICAL_RECIPE_PRIOR" else 1,
        r["KPI_Name"],
    )
)

selected = []
theme_counts = Counter()
source_object_counts = Counter()
family_counts = Counter()

for r in candidate_rows:
    if len(selected) >= top_n:
        break

    theme = r["Primary_Theme"]
    obj = r["Source_Object"] or "RECIPE"
    family = r.get("Concept_Family") or concept_family(r)

    # Strong family diversity: one representative per concept family in the
    # first pass. This prevents root-cause or forecast variants from consuming
    # most of the list.
    if family_counts[family] >= 1:
        continue

    if theme_counts[theme] >= max(4, math.ceil(top_n * 0.40)):
        continue
    if source_object_counts[obj] >= max(6, math.ceil(top_n * 0.55)):
        continue

    selected.append(r)
    theme_counts[theme] += 1
    source_object_counts[obj] += 1
    family_counts[family] += 1

# Second pass permits at most two variants from a family if needed to fill the
# requested list.
if len(selected) < top_n:
    chosen = {canonical_candidate_key(r) for r in selected}
    for r in candidate_rows:
        if len(selected) >= top_n:
            break
        key = canonical_candidate_key(r)
        if key in chosen:
            continue
        family = r.get("Concept_Family") or concept_family(r)
        if family_counts[family] >= 2:
            continue
        selected.append(r)
        chosen.add(key)
        family_counts[family] += 1

# Rank numbers and fit labels.
for i,r in enumerate(selected, start=1):
    r["Rank"] = i
    s = float(r["Candidate_Score"])
    r["Recommendation"] = (
        "STRONG_CANDIDATE" if s >= 0.70
        else "CANDIDATE" if s >= 0.55
        else "REVIEW"
    )

# Desired signal families are intent-level gaps, not hardcoded current KPIs.
# They tell Customer AI what it would ideally like to measure even when SFDC
# cannot currently support the measurement.
DESIRED_SIGNAL_FAMILIES = {
    "resolution": [
        ("RESOLUTION_RATE","Resolution success / closure effectiveness","PROCESS"),
        ("RESOLUTION_TIME","Time to resolution","TIME"),
        ("SLA","SLA / service-level failure rate","TIME"),
        ("FIRST_RESPONSE","First-response responsiveness","TIME"),
        ("ESCALATION","Escalation rate","PROCESS"),
        ("ROOT_CAUSE_MIX","Root-cause mix","PRODUCT_SERVICE"),
        ("SEVERITY_MIX","Critical / major issue mix","PRODUCT_SERVICE"),
        ("REOPEN_RATE","Reopen / repeat-resolution rate","PROCESS"),
    ],
    "value": [
        ("COMMERCIAL_VALUE","Commercial value / renewal amount","VALUE"),
        ("RENEWAL_PROBABILITY","Renewal confidence / probability","VALUE"),
        ("FORECAST","Commercial forecast confidence","VALUE"),
        ("ENGAGEMENT","Relationship engagement / activity","PEOPLE"),
        ("PRODUCT_USAGE","Product usage / adoption depth","PRODUCT_SERVICE"),
        ("VALUE_REALIZATION","Realized customer outcomes / ROI","VALUE"),
        ("SUPPORT_BURDEN","Support burden / friction","PROCESS"),
        ("RENEWAL_TIMING","Renewal timing / recency","TIME"),
    ],
    "confidence": [
        ("RENEWAL_PROBABILITY","Renewal confidence / probability","VALUE"),
        ("ENGAGEMENT","Relationship engagement / activity","PEOPLE"),
        ("PRODUCT_USAGE","Product usage / adoption depth","PRODUCT_SERVICE"),
        ("VALUE_REALIZATION","Realized customer outcomes / ROI","VALUE"),
        ("FORECAST","Commercial forecast confidence","VALUE"),
        ("SUPPORT_BURDEN","Support burden / friction","PROCESS"),
    ],
}

desired = []
driver_norm_for_gaps = " ".join(words(driver)).lower()
for trigger, families in DESIRED_SIGNAL_FAMILIES.items():
    if trigger in driver_norm_for_gaps:
        desired.extend(families)

# De-duplicate desired families while preserving order.
seen_desired = set()
desired_unique = []
for family,label,theme in desired:
    if family not in seen_desired:
        seen_desired.add(family)
        desired_unique.append((family,label,theme))

selected_families = {r.get("Concept_Family") for r in selected}
pool_families = {r.get("Concept_Family") for r in candidate_rows}

support_component_families = {
    "RESOLUTION_RATE",
    "RESOLUTION_TIME",
    "OPEN_CASE_AGE",
    "SLA",
    "FIRST_RESPONSE",
    "ESCALATION",
    "ROOT_CAUSE_MIX",
    "BUG_DEFECT",
    "SEVERITY_MIX",
}
support_component_count = len(pool_families & support_component_families)
if support_component_count >= 2:
    pool_families.add("SUPPORT_BURDEN")

target_gaps = []
for family,label,theme in desired_unique:
    if family in selected_families or family in pool_families:
        continue
    target_gaps.append({
        "Concept_Family": family,
        "Desired_Signal": label,
        "Primary_Theme": theme,
        "Availability": "TARGET_NOT_YET_AVAILABLE",
        "Reason": (
            "No current Salesforce ingredient/recipe family sufficiently supports "
            "this desired signal for the Stage + Driver."
        ),
    })

if target_gaps:
    with (out/"target-signal-gaps.csv").open("w",encoding="utf-8",newline="") as f:
        w=csv.DictWriter(
            f,
            fieldnames=["Concept_Family","Desired_Signal","Primary_Theme","Availability","Reason"],
            lineterminator="\n",
        )
        w.writeheader()
        w.writerows(target_gaps)

fields = [
    "Rank","Recommendation","KPI_Name","Stage","Driver","Primary_Theme",
    "Concept_Family","Candidate_Source","Ingredients","Formula","Metric_Archetype","Grain","Window",
    "Availability","Empirical_Status","Candidate_Score","Original_Prior_Score",
    "Driver_Fit_Score","Stage_Object_Fit","Causal_Proximity","Context_Penalty",
    "Quality_Warnings","Theme_Fit","Semantic_Score","Predictive_Prior",
    "Historical_Prior","Data_Coverage_Score","Explainability","Actionability",
    "Direction_Hypothesis","Rationale","Historical_Evidence","Source_Object",
    "Source_Field",
]

with (out/"ranked-kpi-candidates.csv").open("w",encoding="utf-8",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n",extrasaction="ignore")
    w.writeheader()
    w.writerows(selected)

with (out/"ranked-ingredients.csv").open("w",encoding="utf-8",newline="") as f:
    rows=[]
    for rank,(score,r,parts) in enumerate(ingredient_rank, start=1):
        rows.append({
            "Rank":rank,
            "Canonical_Field_Key__c":r.get("Canonical_Field_Key__c",""),
            "Field_Label__c":r.get("Field_Label__c",""),
            "Primary_Theme__c":r.get("Primary_Theme__c",""),
            "Metric_Archetypes__c":r.get("Metric_Archetypes__c",""),
            "Coverage_Pct__c":r.get("Coverage_Pct__c",""),
            "Predictive_Prior_Score__c":r.get("Predictive_Prior_Score__c",""),
            "Explainability_Score__c":r.get("Explainability_Score__c",""),
            "Candidate_Ingredient_Score":round(score,4),
            "Stage_Driver_Text_Fit":round(parts["lexical"],4),
            "Theme_Fit":round(parts["semantic"],4),
        })
    if rows:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()),lineterminator="\n")
        w.writeheader(); w.writerows(rows)

summary = {
    "stage": stage,
    "driver": driver,
    "source_ingredients_considered": len(ingredients),
    "historical_templates_considered": len(templates),
    "candidate_pool_size": len(candidate_rows),
    "candidates_returned": len(selected),
    "active_themes": [
        {"theme":t,"score":round(s,4)}
        for t,s in ranked_themes
    ],
    "availability_counts": dict(Counter(r["Availability"] for r in selected)),
    "source_counts": dict(Counter(r["Candidate_Source"] for r in selected)),
    "theme_counts": dict(Counter(r["Primary_Theme"] for r in selected)),
    "concept_family_counts": dict(Counter(r.get("Concept_Family","") for r in selected)),
    "target_gap_count": len(target_gaps),
    "target_gaps": target_gaps,
    "empirical_status": "NOT_TESTED",
}
(out/"discovery-summary.json").write_text(
    json.dumps(summary,indent=2)+"\n",
    encoding="utf-8"
)

# Human-readable report.
with (out/"ranked-kpi-candidates.md").open("w",encoding="utf-8") as f:
    f.write(f"# KPI candidates — {stage} / {driver}\n\n")
    f.write("**Empirical status: NOT TESTED.** Ranking is a candidate-generation prior, "
            "not proof of correlation.\n\n")
    f.write("## Inferred theme relevance\n\n")
    for t,s in ranked_themes:
        f.write(f"- {t}: {s:.2f}\n")
    f.write("\n## Ranked candidates\n\n")
    for r in selected:
        f.write(f"### {r['Rank']}. {r['KPI_Name']} — {r['Recommendation']}\n\n")
        f.write(f"- Theme: {r['Primary_Theme']}\n")
        f.write(f"- Score: {float(r['Candidate_Score']):.3f}\n")
        f.write(f"- Source: {r['Candidate_Source']}\n")
        f.write(f"- Availability: {r['Availability']}\n")
        f.write(f"- Ingredients: `{r['Ingredients']}`\n")
        f.write(f"- Formula: `{r['Formula']}`\n")
        f.write(f"- Window: {r['Window']}\n")
        f.write(f"- Rationale: {r['Rationale']}\n\n")

print("STAGE / DRIVER SEMANTIC PROFILE")
print("-------------------------------")
print("stage:", stage)
print("driver:", driver)
print("driver_tokens:", ", ".join(sorted(driver_tokens)) or "<none>")
print("activated_intents:", ", ".join(ACTIVE_INTENTS) or "<generic>")
print()
print("THEME RELEVANCE")
print("---------------")
for t,s in ranked_themes:
    marker = "*" if t in active_themes else " "
    print(f"{marker} {t:<18} {s:.3f}")

print()
print("DISCOVERY POOL")
print("--------------")
print("eligible_direct_experience_and_linkage_ingredients:", len(ingredients))
print("historical_direct_experience_templates:", len(templates))
print("candidate_pool_after_dedupe:", len(candidate_rows))
print("returned:", len(selected))

print()
print("RANKED KPI CANDIDATES")
print("---------------------")
for r in selected:
    print(
        f"{r['Rank']:>2}. "
        f"{r['Candidate_Score']:.4f}  "
        f"{r['Recommendation']:<16} "
        f"{r['Primary_Theme']:<16} "
        f"{r['Availability']:<16} "
        f"{r['KPI_Name']}"
    )
    print(f"    family:      {r.get('Concept_Family','')}"
    )
    print(
        f"    fit: driver={float(r.get('Driver_Fit_Score',0)):.2f} "
        f"object={float(r.get('Stage_Object_Fit',0)):.2f} "
        f"causal={float(r.get('Causal_Proximity',0)):.2f} "
        f"context_penalty={float(r.get('Context_Penalty',0)):.2f}"
    )
    print(f"    ingredients: {r['Ingredients']}")
    print(f"    formula:     {r['Formula']}")
    print(f"    evidence:    {r['Candidate_Source']} / empirical={r['Empirical_Status']}")
    if r.get("Quality_Warnings"):
        print(f"    warnings:    {r['Quality_Warnings']}")
    print()

if "SUPPORT_BURDEN" in {f for f,_,_ in desired_unique}:
    print("SUPPORT BURDEN SOURCE COVERAGE")
    print("------------------------------")
    print("support_component_families_available:", support_component_count)
    print("support_burden_source_status:", "DERIVABLE_FROM_COMPONENTS" if support_component_count >= 2 else "NOT_AVAILABLE")
    print()

if target_gaps:
    print("TARGET / NOT YET AVAILABLE SIGNAL GAPS")
    print("--------------------------------------")
    for g in target_gaps:
        print(f"- {g['Primary_Theme']:<16} {g['Concept_Family']:<22} {g['Desired_Signal']}")
    print()

print("IMPORTANT")
print("---------")
print("These scores are semantic/data/historical PRIORS.")
print("They do not prove correlation with the Driver.")
print("The next validation layer must compute each candidate on Account/time-window")
print("observations and test empirical relationship with the Driver outcome.")
PY

echo
echo "[5/5] Safety + artifact checks..."

python3 - "$OUT" <<'PY'
from pathlib import Path
import csv
import json
import re
import sys

out = Path(sys.argv[1])
csv_path = out/"ranked-kpi-candidates.csv"

with csv_path.open("r",encoding="utf-8-sig",newline="") as f:
    rows=list(csv.DictReader(f))

if not rows:
    raise SystemExit("ERROR: KPI discovery produced zero candidates.")

for r in rows:
    if r["Empirical_Status"] != "NOT_TESTED":
        raise SystemExit("ERROR: a candidate was incorrectly presented as empirically validated.")
    text=" ".join(r.values())
    if re.search(r"\bMarumba\b",text,re.I):
        raise SystemExit("ERROR: obsolete demo brand leaked into candidate output.")

    # Placeholder-bearing formulas are not executable yet and must never be
    # labeled DERIVABLE.
    if re.search(r"\{[^}]+\}|<[^>]+>", r.get("Formula","")) and r.get("Availability") == "DERIVABLE":
        raise SystemExit(
            "ERROR: placeholder-bearing formula incorrectly labeled DERIVABLE: "
            + r.get("KPI_Name","")
        )

# Conga can occur only if some old Salesforce metadata somehow survived the
# approved source intelligence seed. Treat that as a hard demo-facing leak.
for r in rows:
    text=" ".join(r.values())
    if re.search(r"\bConga\b",text,re.I):
        raise SystemExit("ERROR: legacy product/vendor label leaked into candidate output.")

summary=json.loads((out/"discovery-summary.json").read_text())
print("  candidates:", len(rows))
print("  availability:", summary["availability_counts"])
print("  themes:", summary["theme_counts"])
print("  sources:", summary["source_counts"])
print("  PASS: every candidate is explicitly NOT_TESTED.")
print("  PASS: no obsolete demo brand leaked into the output.")
PY

echo
echo "Artifacts:"
echo "  $OUT/discovery-summary.json"
echo "  $OUT/ranked-ingredients.csv"
echo "  $OUT/ranked-kpi-candidates.csv"
echo "  $OUT/ranked-kpi-candidates.md"
if [ -f "$OUT/target-signal-gaps.csv" ]; then
  echo "  $OUT/target-signal-gaps.csv"
fi
echo
echo "============================================================"
echo "STAGE / DRIVER KPI DISCOVERY PREFLIGHT COMPLETE"
echo "============================================================"
echo "NO SALESFORCE RECORDS OR METADATA WERE MODIFIED."
echo
echo "Recommended first two tests:"
echo "  $0 --stage \"Support\" --driver \"Effectiveness of Resolution\" --top 15"
echo "  $0 --stage \"Renewal\" --driver \"Confidence in Value\" --top 15"
echo "============================================================"
