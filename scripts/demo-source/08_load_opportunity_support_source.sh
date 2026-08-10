#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
DOWNLOADS="${DOWNLOADS:-$HOME/Downloads}"
OPPS_FILE="${OPPS_FILE:-$DOWNLOADS/All_Opportunities.csv}"
SUPPORT_FILE="${SUPPORT_FILE:-$DOWNLOADS/All_Support_Data.csv}"
MAPPING_FILE="${MAPPING_FILE:-}"
MODE="${1:-prepare}"

cd "$PROJECT"

MANIFEST="manifest/ocx-opportunity-support-source-data.xml"
PERMSET="force-app/main/default/permissionsets/OCX_Opportunity_Support_Source_Data.permissionset-meta.xml"
VERSIONED_SCRIPT="scripts/demo-source/08_load_opportunity_support_source.sh"
DOC="scripts/demo-source/OPPORTUNITY_SUPPORT_SOURCE.md"
RUN_ROOT="$PROJECT/.ocx/opportunity-support-source"

EXPECTED_OPPS=7618
EXPECTED_CASES=2994
EXPECTED_ACCOUNTS=7755

mkdir -p "$RUN_ROOT"

echo
echo "============================================================"
echo "OCX BONGO OPPORTUNITY + SUPPORT SOURCE LOADER"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Mode:    $MODE"
echo
echo "Source files:"
echo "  $OPPS_FILE"
echo "  $SUPPORT_FILE"
echo
echo "Design:"
echo "  - enrich existing 7,618 Opportunities; do not create Opportunities"
echo "  - enrich only linked Cases supported by same-account source rows; do not create Cases"
echo "  - match through the authoritative 7,755 Bongo Account identities"
echo "  - keep raw source vocabulary in dedicated Source_* fields"
echo "  - keep Support Product and PL as separate dimensions"
echo "  - normalize Product to approved Bongo labels"
echo "  - never load prototype person names"
echo "  - never write source data into downstream OCX analytics fields"
echo "  - leave unmatched Cases untouched when same-account source coverage is unavailable"
echo "============================================================"
echo

discover_mapping() {
  if [ -n "$MAPPING_FILE" ] && [ -f "$MAPPING_FILE" ]; then
    printf '%s\n' "$MAPPING_FILE"
    return
  fi

  python3 - "$DOWNLOADS" <<'PY'
import csv
import sys
from pathlib import Path

root = Path(sys.argv[1])
matches = []

for p in sorted(root.glob("*.csv")):
    try:
        with p.open("r", encoding="utf-8-sig", newline="") as f:
            header = next(csv.reader(f), [])
    except Exception:
        continue

    if "account_id_conga" not in header:
        continue

    mapped_ids = [
        c for c in header
        if c.startswith("account_id_") and c != "account_id_conga"
    ]
    mapped_names = [c for c in header if c.startswith("account_name_")]

    if len(mapped_ids) == 1 and len(mapped_names) == 1:
        matches.append(p)

if matches:
    print(matches[-1])
PY
}

write_field_text() {
  local object="$1" api="$2" label="$3" length="$4" desc="$5"
  local dir="force-app/main/default/objects/$object/fields"
  mkdir -p "$dir"
  cat > "$dir/${api}.field-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <description>${desc}</description>
    <label>${label}</label>
    <length>${length}</length>
    <type>Text</type>
</CustomField>
EOF
}

write_field_number() {
  local object="$1" api="$2" label="$3" precision="$4" scale="$5" desc="$6"
  local dir="force-app/main/default/objects/$object/fields"
  mkdir -p "$dir"
  cat > "$dir/${api}.field-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <description>${desc}</description>
    <label>${label}</label>
    <precision>${precision}</precision>
    <scale>${scale}</scale>
    <type>Number</type>
</CustomField>
EOF
}

write_field_currency() {
  local object="$1" api="$2" label="$3" desc="$4"
  local dir="force-app/main/default/objects/$object/fields"
  mkdir -p "$dir"
  cat > "$dir/${api}.field-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <description>${desc}</description>
    <label>${label}</label>
    <precision>18</precision>
    <scale>2</scale>
    <type>Currency</type>
</CustomField>
EOF
}

write_field_date() {
  local object="$1" api="$2" label="$3" desc="$4"
  local dir="force-app/main/default/objects/$object/fields"
  mkdir -p "$dir"
  cat > "$dir/${api}.field-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <description>${desc}</description>
    <label>${label}</label>
    <type>Date</type>
</CustomField>
EOF
}

write_field_checkbox() {
  local object="$1" api="$2" label="$3" desc="$4"
  local dir="force-app/main/default/objects/$object/fields"
  mkdir -p "$dir"
  cat > "$dir/${api}.field-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <defaultValue>false</defaultValue>
    <description>${desc}</description>
    <label>${label}</label>
    <type>Checkbox</type>
</CustomField>
EOF
}

OPP_NEW_FIELDS=(
  Source_Opportunity_ID__c Source_Stage__c Source_Type__c
  Source_Forecast_Category__c Source_Probability__c Source_Age_Days__c
  Source_Average_ACV__c Source_Renewal_Dollars__c Source_Total_Renewal_Due__c
  Source_Renewal_Due__c Source_Renewal_Due_Date__c Source_CSM_Sentiment__c
  Source_Engagement_Type__c Source_Owner_Role__c Source_Lead_Source__c
  Source_Sub_Type__c Source_Created_Date__c Source_Estimated_Close_Date__c
  Source_Region__c Source_Segment__c Source_Account_Segment__c
  Source_Owner_Name__c Source_Territory_Manager_Name__c
)

CASE_NEW_FIELDS=(
  Source_Case_Number__c Source_Opened_Date__c Source_Resolution_Date__c
  Source_Support_Level__c Source_Product__c Source_Severity__c Source_State__c
  Source_Status__c Source_Overall_Case_Satisfaction__c Source_Bug__c
  Source_Special_Attention__c Source_Root_Cause__c
  Source_First_Response_Violated__c
)

prepare() {
  echo "[1/6] Creating Opportunity source metadata..."

  write_field_text Opportunity Source_Opportunity_ID__c "Source Opportunity ID" 80 "Original upstream Opportunity identifier retained for source lineage."
  write_field_text Opportunity Source_Stage__c "Source Stage" 80 "Raw upstream opportunity stage; kept separate from Salesforce StageName."
  write_field_text Opportunity Source_Type__c "Source Opportunity Type" 120 "Raw upstream opportunity type; kept separate from restricted Salesforce Type."
  write_field_text Opportunity Source_Forecast_Category__c "Source Forecast Category" 80 "Raw upstream forecast category."
  write_field_number Opportunity Source_Probability__c "Source Probability" 5 2 "Raw upstream opportunity probability percentage."
  write_field_number Opportunity Source_Age_Days__c "Source Opportunity Age Days" 18 2 "Raw upstream opportunity age in days."
  write_field_currency Opportunity Source_Average_ACV__c "Source Average ACV" "Raw upstream average ACV ingredient."
  write_field_currency Opportunity Source_Renewal_Dollars__c "Source Renewal Dollars" "Raw upstream renewal dollars ingredient."
  write_field_currency Opportunity Source_Total_Renewal_Due__c "Source Total Renewal Due" "Raw upstream total renewal due ingredient."
  write_field_currency Opportunity Source_Renewal_Due__c "Source Renewal Due" "Raw upstream renewal due ingredient."
  write_field_date Opportunity Source_Renewal_Due_Date__c "Source Renewal Due Date" "Raw upstream renewal due date."
  write_field_text Opportunity Source_CSM_Sentiment__c "Source CSM Sentiment" 40 "Raw upstream CSM sentiment value."
  write_field_text Opportunity Source_Engagement_Type__c "Source Engagement Type" 80 "Raw upstream engagement type with legacy branding replaced by Bongo."
  write_field_text Opportunity Source_Owner_Role__c "Source Owner Role" 255 "Raw upstream opportunity owner role; prototype person name is not retained."
  write_field_text Opportunity Source_Lead_Source__c "Source Lead Source" 255 "Raw upstream lead source."
  write_field_text Opportunity Source_Sub_Type__c "Source Opportunity Sub-Type" 255 "Raw upstream opportunity sub-type."
  write_field_date Opportunity Source_Created_Date__c "Source Created Date" "Raw upstream business created date."
  write_field_date Opportunity Source_Estimated_Close_Date__c "Source Estimated Close Date" "Raw upstream estimated close date."
  write_field_text Opportunity Source_Region__c "Source Region" 80 "Raw upstream opportunity region."
  write_field_text Opportunity Source_Segment__c "Source Segment" 80 "Raw upstream opportunity segment."
  write_field_text Opportunity Source_Account_Segment__c "Source Account Segment" 80 "Raw upstream account segment carried on the opportunity."
  write_field_text Opportunity Source_Owner_Name__c "Source Owner Name" 80 "Bongo demo identity replacing the prototype opportunity owner name."
  write_field_text Opportunity Source_Territory_Manager_Name__c "Source Territory Manager Name" 80 "Bongo demo identity replacing the prototype territory manager name."

  echo "[2/6] Creating Case source metadata..."

  write_field_text Case Source_Case_Number__c "Source Case Number" 80 "Original upstream support case identifier retained for source lineage."
  write_field_date Case Source_Opened_Date__c "Source Opened Date" "Raw upstream support case opened date."
  write_field_date Case Source_Resolution_Date__c "Source Resolution Date" "Raw upstream support case resolution date."
  write_field_text Case Source_Support_Level__c "Source Support Level" 120 "Raw upstream support level; kept separate from restricted Salesforce picklist."
  write_field_text Case Source_Product__c "Source Product" 120 "Support Product normalized to the approved Bongo demo product label."
  write_field_text Case Source_Severity__c "Source Severity" 80 "Raw upstream support severity."
  write_field_text Case Source_State__c "Source State" 80 "Raw upstream support state."
  write_field_text Case Source_Status__c "Source Status" 120 "Raw upstream support status; kept separate from Salesforce Case.Status."
  write_field_number Case Source_Overall_Case_Satisfaction__c "Source Overall Case Satisfaction" 18 2 "Raw upstream case satisfaction value."
  write_field_checkbox Case Source_Bug__c "Source Bug" "Raw upstream bug indicator."
  write_field_text Case Source_Special_Attention__c "Source Special Attention" 255 "Raw upstream special-attention classification with legacy branding normalized."
  write_field_text Case Source_Root_Cause__c "Source Root Cause" 255 "Raw upstream root-cause value; kept separate from restricted Salesforce picklist."
  write_field_checkbox Case Source_First_Response_Violated__c "Source First Response Violated" "Raw upstream first-response violation indicator."

  echo "[3/6] Creating permission set..."
  {
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>OCX Opportunity Support Source Data</label>
EOF
    for f in "${OPP_NEW_FIELDS[@]}" ARR__c Annual_Renewal__c Territory__c; do
      cat <<EOF
    <fieldPermissions>
        <editable>true</editable>
        <field>Opportunity.${f}</field>
        <readable>true</readable>
    </fieldPermissions>
EOF
    done
    for f in "${CASE_NEW_FIELDS[@]}" Time_to_Resolution_Days__c Ageing_of_Open_Cases_Days__c SLA_Violation__c Product_Line__c Support_Category__c; do
      cat <<EOF
    <fieldPermissions>
        <editable>true</editable>
        <field>Case.${f}</field>
        <readable>true</readable>
    </fieldPermissions>
EOF
    done
    cat <<'EOF'
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Opportunity</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Case</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
</PermissionSet>
EOF
  } > "$PERMSET"

  echo "[4/6] Creating deployment manifest..."
  mkdir -p manifest
  {
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
EOF
    for f in "${OPP_NEW_FIELDS[@]}"; do echo "        <members>Opportunity.${f}</members>"; done
    for f in "${CASE_NEW_FIELDS[@]}"; do echo "        <members>Case.${f}</members>"; done
    cat <<'EOF'
        <name>CustomField</name>
    </types>
    <types>
        <members>OCX_Opportunity_Support_Source_Data</members>
        <name>PermissionSet</name>
    </types>
    <version>67.0</version>
</Package>
EOF
  } > "$MANIFEST"

  echo "[5/6] Versioning loader + documentation..."
  mkdir -p scripts/demo-source
  SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  TARGET_PATH="$(cd "$(dirname "$VERSIONED_SCRIPT")" && pwd)/$(basename "$VERSIONED_SCRIPT")"
  if [ "$SELF_PATH" != "$TARGET_PATH" ]; then
    cp "$0" "$VERSIONED_SCRIPT"
  fi
  chmod +x "$VERSIONED_SCRIPT"

  cat > "$DOC" <<'EOF'
# Opportunity + Support Source Reconstruction

This workflow enriches the existing OCXDemo Salesforce records with upstream
Opportunity and Support ingredients from the original source extracts.

It does not create the production-scale source populations. It targets the
existing demo population: 7,618 Opportunities and 2,994 linked Cases, with only the source-supported Case subset enriched, linked through
the 7,755 authoritative Bongo Accounts.

## Opportunity

The loader selects deterministic source rows for the same Bongo Account,
ranking Renewal rows first and then newer source rows. Standard/restricted
Salesforce Stage, Type, and Forecast Category are not overwritten; raw values
are stored in dedicated Source_* fields. ARR__c, Annual_Renewal__c, and
Territory__c are upstream-style fields and are populated from source.

Prototype owner names are never loaded. Marcus Webb is used for the demo
Opportunity owner / territory-manager identity.

## Support

The loader selects recent source support rows for the same Bongo Account. Raw
source vocabulary is kept in dedicated fields rather than forced into
restricted Salesforce picklists.

Actual source values populate Time_to_Resolution_Days__c,
Ageing_of_Open_Cases_Days__c, SLA_Violation__c, Product_Line__c (PL), and
Support_Category__c.

### Product versus PL

Product is the individual/legacy product name and is normalized to approved
Bongo demo labels in Source_Product__c. PL is a separate source rollup and is
stored unchanged in Product_Line__c.

Product normalization includes Composer -> Write Up; Sign variants -> Sign
Here; Grid -> Matrix; X-Author -> Write Up Enterprise; Contracts -> Agreements;
CLM -> Contracta; CPQ/Quote Generation/Turbo -> QuoteFlow; Orchestrate/Conductor
-> Conductor; Billing/Invoice/Revenue Management -> Billing; Collaborate ->
Collab; Digital Commerce -> Online Seller; Order Management -> Order Pro; Doc
Gen/Mail Merge/Merge Service -> Write Up; Approvals/Batch/Trigger -> Other; any
remaining Product containing Community -> Community; every other remaining
Product -> Other. The catch-all never applies to PL.

### Case matching limitation

The existing demo Case population does not preserve source Case-number lineage.
A read-only diagnostic confirmed zero Case-number matches between the 2,994
linked Salesforce Cases and `All_Support_Data.csv`.

The loader therefore performs a controlled source overlay rather than claiming
record-level lineage: source Support rows must belong to the same Bongo Account,
each source row is used at most once, closed Cases pair only with resolved source
rows, open Cases pair only with unresolved source rows, and unmatched Cases are
left untouched.

## Demo boundary

These are upstream source ingredients for Customer AI discovery and retrieval.
They are not yet used to build generative CX models.
EOF

  echo "[6/6] Validating XML..."
  python3 - "$MANIFEST" "$PERMSET" <<'PY'
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    ET.parse(path)
    print(f"XML OK: {path}")
PY

  echo
  echo "Prepared local source. No Salesforce metadata or records were modified."
  echo "Next: $0 schema-dry-run"
}

schema_dry_run() {
  sf project deploy start --target-org "$ORG" --manifest "$MANIFEST" --dry-run --test-level NoTestRun --wait 30
}

schema_apply() {
  sf project deploy start --target-org "$ORG" --manifest "$MANIFEST" --test-level NoTestRun --wait 30
  sf org assign permset --target-org "$ORG" --name OCX_Opportunity_Support_Source_Data
}

latest_preflight() {
  find "$RUN_ROOT" -type f -name PRECHECK_OK -print 2>/dev/null | sed 's#/PRECHECK_OK$##' | sort | tail -1
}

preflight() {
  [ -f "$OPPS_FILE" ] || { echo "ERROR: Missing $OPPS_FILE"; exit 1; }
  [ -f "$SUPPORT_FILE" ] || { echo "ERROR: Missing $SUPPORT_FILE"; exit 1; }

  MAPPING_FILE="$(discover_mapping)"
  [ -f "$MAPPING_FILE" ] || { echo "ERROR: Could not find account identity mapping CSV."; exit 1; }

  STAMP="$(date +%Y%m%d_%H%M%S)"
  RUN_DIR="$RUN_ROOT/$STAMP"
  mkdir -p "$RUN_DIR"

  echo "Using mapping: $MAPPING_FILE"
  echo "Run: $RUN_DIR"

  OPP_FIELDS="Id,Name,AccountId,Account.Name,ARR__c,Annual_Renewal__c,Territory__c"
  for f in "${OPP_NEW_FIELDS[@]}"; do OPP_FIELDS="$OPP_FIELDS,$f"; done
  CASE_FIELDS="Id,CaseNumber,AccountId,Account.Name,IsClosed,Time_to_Resolution_Days__c,Ageing_of_Open_Cases_Days__c,SLA_Violation__c,Product_Line__c,Support_Category__c"
  for f in "${CASE_NEW_FIELDS[@]}"; do CASE_FIELDS="$CASE_FIELDS,$f"; done

  echo "[1/4] Reading existing Salesforce Opportunities and Cases..."
  sf data query --target-org "$ORG" --query "SELECT $OPP_FIELDS FROM Opportunity WHERE AccountId != null ORDER BY Account.Name,Id" --result-format csv --output-file "$RUN_DIR/live_opportunities_before.csv"
  sf data query --target-org "$ORG" --query "SELECT $CASE_FIELDS FROM Case WHERE AccountId != null ORDER BY Account.Name,Id" --result-format csv --output-file "$RUN_DIR/live_cases_before.csv"

  echo "[2/4] Building deterministic source selections and rollback CSVs..."

  python3 - "$MAPPING_FILE" "$OPPS_FILE" "$SUPPORT_FILE" "$RUN_DIR/live_opportunities_before.csv" "$RUN_DIR/live_cases_before.csv" "$RUN_DIR" "$EXPECTED_ACCOUNTS" "$EXPECTED_OPPS" "$EXPECTED_CASES" <<'PY'
import csv, json, re, sys
from collections import defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

mapping_path=Path(sys.argv[1]); opps_path=Path(sys.argv[2]); support_path=Path(sys.argv[3])
live_opps_path=Path(sys.argv[4]); live_cases_path=Path(sys.argv[5]); out=Path(sys.argv[6])
EXPECTED_ACCOUNTS=int(sys.argv[7]); EXPECTED_OPPS=int(sys.argv[8]); EXPECTED_CASES=int(sys.argv[9])

def read(path):
    with path.open('r',encoding='utf-8-sig',newline='') as f: return list(csv.DictReader(f))
def clean(v): return (v or '').strip()
def null(v):
    s=clean(v); return s if s else '#N/A'
def text(v):
    s=clean(v)
    if not s: return '#N/A'
    return s.replace('Conga','Bongo').replace('Mar'+'umba','Bongo')
def number(v):
    s=clean(v)
    if not s: return '#N/A'
    try: return format(Decimal(s),'f')
    except InvalidOperation: raise ValueError(f'Invalid numeric value: {s!r}')
def date(v):
    s=clean(v); return s[:10] if s else '#N/A'
def boolean(v, true_values=('true','yes','1','violation')):
    return 'true' if clean(v).lower() in true_values else 'false'
def parse_date(v):
    s=clean(v)
    if not s: return datetime.min
    try: return datetime.strptime(s[:10],'%Y-%m-%d')
    except Exception: return datetime.min

def product_demo(raw):
    v=clean(raw)
    if not v: return '#N/A'
    low=v.lower()
    if 'community' in low: return 'Community'
    if 'composer' in low or low in {'doc gen','mail merge','merge server','merge service'}: return 'Write Up'
    if low in {'sign','conga sign','conga sign / api','docusign integration','adobe sign integration','echosign'} or 'sign integration' in low: return 'Sign Here'
    if low=='grid' or 'conga grid' in low: return 'Matrix'
    if 'x-author' in low: return 'Write Up Enterprise'
    if low in {'contracts','conga contracts','contracts for salesforce','contracts - salesforce','contract for salesforce'}: return 'Agreements'
    if low in {'clm','conga clm','apttus clm','clm suite','contract intelligence','conga clm connector'}: return 'Contracta'
    if low in {'cpq','configure, price, quote','conga quote generation','turbo pricing','turbo config','turbo engines','deal maximizer'} or 'quote generation' in low: return 'QuoteFlow'
    if low in {'orchestrate','conga orchestrate','conductor 7','workflow 7'}: return 'Conductor'
    if low in {'billing','conga billing','invoice generation','conga invoice generation','revenue recognition'} or low.startswith('revenue management'): return 'Billing'
    if low in {'collaborate','conga collaborate'}: return 'Collab'
    if low in {'digital commerce','conga digital commerce'}: return 'Online Seller'
    if low in {'conga order management','order management','asset based ordering'}: return 'Order Pro'
    if 'approval' in low or low in {'batch trigger','batch','trigger','advanced approvals','approvals api'}: return 'Other'
    if low=='support': return 'Support'
    return 'Other'

mapping=read(mapping_path); mh=list(mapping[0].keys())
source_id_col='account_id_conga'
mapped_names=[c for c in mh if c.startswith('account_name_')]
mapped_ids=[c for c in mh if c.startswith('account_id_') and c!=source_id_col]
if source_id_col not in mh or len(mapped_names)!=1 or len(mapped_ids)!=1: raise SystemExit('ERROR: Invalid account mapping shape.')
mapped_name_col=mapped_names[0]
name_to_source={}
for r in mapping:
    sid=clean(r.get(source_id_col)); name=clean(r.get(mapped_name_col))
    if not sid or not name or name.upper()=='#N/A': continue
    if name in name_to_source: raise SystemExit(f'ERROR: Duplicate mapped demo Account name: {name}')
    name_to_source[name]=sid
if len(name_to_source)!=EXPECTED_ACCOUNTS: raise SystemExit(f'ERROR: Expected {EXPECTED_ACCOUNTS} active mapped Accounts; found {len(name_to_source)}.')

live_opps=read(live_opps_path); live_cases=read(live_cases_path)
if len(live_opps)!=EXPECTED_OPPS: raise SystemExit(f'ERROR: Expected {EXPECTED_OPPS} Opportunities; found {len(live_opps)}.')
if len(live_cases)!=EXPECTED_CASES: raise SystemExit(f'ERROR: Expected {EXPECTED_CASES} Cases; found {len(live_cases)}.')

opp_sf=defaultdict(list)
for r in live_opps:
    name=clean(r.get('Account.Name')); sid=name_to_source.get(name)
    if not sid: raise SystemExit(f'ERROR: Opportunity Account not in mapping: {name!r}')
    opp_sf[sid].append(r)
case_sf=defaultdict(list)
for r in live_cases:
    name=clean(r.get('Account.Name')); sid=name_to_source.get(name)
    if not sid: raise SystemExit(f'ERROR: Case Account not in mapping: {name!r}')
    case_sf[sid].append(r)
for rows in opp_sf.values(): rows.sort(key=lambda r:r['Id'])
for rows in case_sf.values(): rows.sort(key=lambda r:r['Id'])

source_opps=defaultdict(list)
with opps_path.open('r',encoding='utf-8-sig',newline='') as f:
    for r in csv.DictReader(f):
        sid=clean(r.get('Account ID'))
        if sid in opp_sf: source_opps[sid].append(r)
source_cases=defaultdict(list)
with support_path.open('r',encoding='utf-8-sig',newline='') as f:
    for r in csv.DictReader(f):
        sid=clean(r.get('Account ID'))
        if sid in case_sf: source_cases[sid].append(r)

def opp_rank(r):
    return (1 if clean(r.get('C2_TYPE')).lower()=='renewal' else 0, parse_date(r.get('CREATED_DATE')), parse_date(r.get('RENEWAL_DUE_DATE')), clean(r.get('OPPORTUNITY_ID')))
for sid in source_opps: source_opps[sid].sort(key=opp_rank,reverse=True)
def case_rank(r): return (parse_date(r.get('Date/Time Opened')),clean(r.get('Case Number')))
for sid in source_cases: source_cases[sid].sort(key=case_rank,reverse=True)

bad=[(sid,len(sf),len(source_opps.get(sid,[]))) for sid,sf in opp_sf.items() if len(source_opps.get(sid,[]))<len(sf)]
if bad: raise SystemExit(f'ERROR: Insufficient Opportunity source rows. Sample: {bad[:10]}')
case_source_deficits=[(sid,len(sf),len(source_cases.get(sid,[])),len(sf)-len(source_cases.get(sid,[]))) for sid,sf in case_sf.items() if len(source_cases.get(sid,[]))<len(sf)]

opp_updates=[]; opp_rollback=[]; opp_selection=[]
for sid,sf_rows in opp_sf.items():
    for sf,src in zip(sf_rows,source_opps[sid][:len(sf_rows)]):
        u={'Id':sf['Id'],'ARR__c':number(src.get('ARR')),'Annual_Renewal__c':number(src.get('ANNUAL_RENEWAL')),'Territory__c':text(src.get('TERRITORY')),
           'Source_Opportunity_ID__c':null(src.get('OPPORTUNITY_ID')),'Source_Stage__c':text(src.get('C2_STAGE')),'Source_Type__c':text(src.get('C2_TYPE')),
           'Source_Forecast_Category__c':text(src.get('FORECAST_CATEGORY')),'Source_Probability__c':number(src.get('PROBABILITY')),'Source_Age_Days__c':number(src.get('AGE_DAYS')),
           'Source_Average_ACV__c':number(src.get('AVERAGE_ACV')),'Source_Renewal_Dollars__c':number(src.get('RENEWAL_DOLLARS')),'Source_Total_Renewal_Due__c':number(src.get('TOTAL_RENEWAL_DUE')),
           'Source_Renewal_Due__c':number(src.get('RENEWAL_DUE')),'Source_Renewal_Due_Date__c':date(src.get('RENEWAL_DUE_DATE')),'Source_CSM_Sentiment__c':text(src.get('CSM_SENTIMENT')),
           'Source_Engagement_Type__c':text(src.get('ENAGEMENT_TYPE')),'Source_Owner_Role__c':text(src.get('OWNER_ROLE')),'Source_Lead_Source__c':text(src.get('LEAD_SOURCE')),
           'Source_Sub_Type__c':text(src.get('SUB_TYPE')),'Source_Created_Date__c':date(src.get('CREATED_DATE')),'Source_Estimated_Close_Date__c':date(src.get('ESTIMATED_CLOSE_DATE')),
           'Source_Region__c':text(src.get('REGION')),'Source_Segment__c':text(src.get('SEGMENT')),'Source_Account_Segment__c':text(src.get('ACCOUNT_SEGMENT')),
           'Source_Owner_Name__c':'Marcus Webb','Source_Territory_Manager_Name__c':'Marcus Webb'}
        opp_updates.append(u)
        opp_rollback.append({k:('#N/A' if not clean(sf.get(k)) else clean(sf.get(k))) for k in u})
        opp_selection.append({'Salesforce_Opportunity_Id':sf['Id'],'Bongo_Account_Name':sf['Account.Name'],'Source_Opportunity_ID':clean(src.get('OPPORTUNITY_ID')),'Source_Type':clean(src.get('C2_TYPE')),'Source_Stage':clean(src.get('C2_STAGE')),'Source_Created_Date':clean(src.get('CREATED_DATE'))})

case_updates=[]; case_rollback=[]; case_selection=[]
case_match_stats={'linked_salesforce_cases':len(live_cases),'source_enriched_cases':0,'linked_cases_left_untouched':0,'closed_cases_enriched':0,'open_cases_enriched':0,'accounts_with_source_row_deficit':len(case_source_deficits),'raw_same_account_row_deficit':sum(x[3] for x in case_source_deficits)}
for sid,sf_rows in case_sf.items():
    src_rows=source_cases.get(sid,[])
    sf_closed=[r for r in sf_rows if clean(r.get('IsClosed')).lower()=='true']
    sf_open=[r for r in sf_rows if clean(r.get('IsClosed')).lower()!='true']
    src_closed=[r for r in src_rows if clean(r.get('Resolution Date'))]
    src_open=[r for r in src_rows if not clean(r.get('Resolution Date'))]
    account_pairs=[]
    for match_method,sf_group,src_group in [('SAME ACCOUNT + RESOLVED',sf_closed,src_closed),('SAME ACCOUNT + OPEN',sf_open,src_open)]:
        n=min(len(sf_group),len(src_group))
        account_pairs.extend((match_method,sf,src) for sf,src in zip(sf_group[:n],src_group[:n]))
    case_match_stats['source_enriched_cases']+=len(account_pairs)
    case_match_stats['linked_cases_left_untouched']+=len(sf_rows)-len(account_pairs)
    case_match_stats['closed_cases_enriched']+=sum(1 for method,_,_ in account_pairs if method=='SAME ACCOUNT + RESOLVED')
    case_match_stats['open_cases_enriched']+=sum(1 for method,_,_ in account_pairs if method=='SAME ACCOUNT + OPEN')
    for match_method,sf,src in account_pairs:
        special=text(src.get('Special Attention'))
        if special!='#N/A': special=special.replace('Composer','Write Up')
        u={'Id':sf['Id'],'Time_to_Resolution_Days__c':number(src.get('TTR')),'Ageing_of_Open_Cases_Days__c':number(src.get('Ageing of Open Cases')),
           'SLA_Violation__c':boolean(src.get('SLT Violation')),'Product_Line__c':null(src.get('PL')),'Support_Category__c':text(src.get('Case Category')),
           'Source_Case_Number__c':null(src.get('Case Number')),'Source_Opened_Date__c':date(src.get('Date/Time Opened')),'Source_Resolution_Date__c':date(src.get('Resolution Date')),
           'Source_Support_Level__c':text(src.get('Support Level')),'Source_Product__c':product_demo(src.get('Product')),'Source_Severity__c':text(src.get('Severity')),
           'Source_State__c':text(src.get('State')),'Source_Status__c':text(src.get('Status')),'Source_Overall_Case_Satisfaction__c':number(src.get('Overall Case Satisfaction')),
           'Source_Bug__c':boolean(src.get('Bug?')),'Source_Special_Attention__c':special,'Source_Root_Cause__c':text(src.get('Root Cause')),
           'Source_First_Response_Violated__c':boolean(src.get('First Response Violated'))}
        case_updates.append(u)
        case_rollback.append({k:('#N/A' if not clean(sf.get(k)) else clean(sf.get(k))) for k in u})
        case_selection.append({'Salesforce_Case_Id':sf['Id'],'Bongo_Account_Name':sf['Account.Name'],'Match_Method':match_method,'Source_Case_Number':clean(src.get('Case Number')),'Source_Product':clean(src.get('Product')),'Bongo_Product':product_demo(src.get('Product')),'PL':clean(src.get('PL')),'Opened':clean(src.get('Date/Time Opened')),'Resolution_Date':clean(src.get('Resolution Date'))})

def write_csv(path,rows):
    with path.open('w',encoding='utf-8',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()),lineterminator='\n'); w.writeheader(); w.writerows(rows)
write_csv(out/'opportunity_updates.csv',opp_updates); write_csv(out/'opportunity_rollback.csv',opp_rollback); write_csv(out/'opportunity_source_selection.csv',opp_selection)
write_csv(out/'case_updates.csv',case_updates); write_csv(out/'case_rollback.csv',case_rollback); write_csv(out/'case_source_selection.csv',case_selection)

for label,rows in [('Opportunity',opp_updates),('Case',case_updates)]:
    for row in rows:
        for field,value in row.items():
            if re.search(r'\b(Conga|Mar(?:umba))\b',str(value or ''),re.I): raise SystemExit(f'ERROR: Forbidden legacy brand in generated {label}.{field}: {value!r}')
if len(opp_updates)!=EXPECTED_OPPS: raise SystemExit('ERROR: Opportunity update row count mismatch.')
if not case_updates or len(case_updates)>EXPECTED_CASES: raise SystemExit('ERROR: Case source-enriched row count is outside allowed range.')
summary={'authoritative_demo_accounts':len(name_to_source),'salesforce_opportunities_targeted':len(opp_updates),'salesforce_linked_cases_seen':len(live_cases),'salesforce_cases_source_enriched':len(case_updates),'salesforce_linked_cases_left_untouched':len(live_cases)-len(case_updates),'source_enriched_closed_cases':case_match_stats['closed_cases_enriched'],'source_enriched_open_cases':case_match_stats['open_cases_enriched'],'accounts_with_source_row_deficit':case_match_stats['accounts_with_source_row_deficit'],'raw_same_account_source_row_deficit':case_match_stats['raw_same_account_row_deficit'],'source_accounts_used_for_opportunities':len(opp_sf),'source_accounts_used_for_cases':len(case_sf),'opportunity_records_created':0,'case_records_created':0,'forbidden_legacy_brand_values_generated':0,'prototype_person_names_loaded':0}
(out/'preflight-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('\nPREFLIGHT SUMMARY\n-----------------')
for k,v in summary.items(): print(f'{k}: {v}')
PY

  echo "[3/4] Checking generated CSV structure..."
  file "$RUN_DIR/opportunity_updates.csv"; file "$RUN_DIR/case_updates.csv"
  echo "Opportunity sample:"; head -3 "$RUN_DIR/opportunity_updates.csv"
  echo "Case sample:"; head -3 "$RUN_DIR/case_updates.csv"

  echo "[4/4] Marking passed preflight..."
  touch "$RUN_DIR/PRECHECK_OK"
  echo "PREFLIGHT PASSED - NO SALESFORCE RECORDS WERE MODIFIED."
  echo "Next: $0 apply"
}

verify_object() {
  local object="$1" update_csv="$2" output_csv="$3" where_clause="$4"
  local header fields
  header="$(head -1 "$update_csv")"; fields="${header#Id,}"
  sf data query --target-org "$ORG" --query "SELECT Id,$fields FROM $object WHERE $where_clause ORDER BY Id" --result-format csv --output-file "$output_csv"
}

apply_data() {
  RUN_DIR="$(latest_preflight)"
  [ -f "$RUN_DIR/PRECHECK_OK" ] || { echo "ERROR: No passed preflight found."; exit 1; }
  echo "Using preflight: $RUN_DIR"

  sf data update bulk --target-org "$ORG" --sobject Opportunity --file "$RUN_DIR/opportunity_updates.csv" --line-ending LF --wait 30
  sf data update bulk --target-org "$ORG" --sobject Case --file "$RUN_DIR/case_updates.csv" --line-ending LF --wait 30

  verify_object Opportunity "$RUN_DIR/opportunity_updates.csv" "$RUN_DIR/live_opportunities_after.csv" "AccountId != null"
  verify_object Case "$RUN_DIR/case_updates.csv" "$RUN_DIR/live_cases_after.csv" "AccountId != null"

  python3 - "$RUN_DIR/opportunity_updates.csv" "$RUN_DIR/live_opportunities_after.csv" "$RUN_DIR/case_updates.csv" "$RUN_DIR/live_cases_after.csv" "$RUN_DIR/verification-summary.json" <<'PY'
import csv,json,re,sys
from decimal import Decimal,InvalidOperation
from pathlib import Path

def read(path):
    with Path(path).open('r',encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def norm(v):
    s=(v or '').strip()
    if s=='#N/A': return ''
    if s.lower() in {'true','false'}: return s.lower()
    try:
        if s!='' and not any(ch.isalpha() for ch in s):
            x=format(Decimal(s).normalize(),'f')
            if '.' in x:x=x.rstrip('0').rstrip('.')
            return x
    except InvalidOperation: pass
    return s

def compare(e_rows,l_rows):
    e={r['Id']:r for r in e_rows}; l={r['Id']:r for r in l_rows}; fields=[f for f in e_rows[0] if f!='Id']; bad=[]
    for sfid,row in e.items():
        got=l.get(sfid)
        if got is None: bad.append((sfid,'<record>','missing')); continue
        for field in fields:
            if norm(row.get(field))!=norm(got.get(field)): bad.append((sfid,field,f"{norm(row.get(field))!r} != {norm(got.get(field))!r}"))
    return fields,bad

oe=read(sys.argv[1]); ol=read(sys.argv[2]); ce=read(sys.argv[3]); cl=read(sys.argv[4])
of,ob=compare(oe,ol); cf,cb=compare(ce,cl)
leaks=[]
for rows in (ol,cl):
    for r in rows:
        for f,v in r.items():
            if re.search(r'\b(Conga|Mar(?:umba))\b',v or '',re.I): leaks.append((r.get('Id'),f,v))
summary={'opportunity_records_expected':len(oe),'opportunity_records_read_back':len(ol),'opportunity_fields_verified':len(of),'opportunity_value_mismatches':len(ob),'case_records_expected':len(ce),'case_records_read_back':len(cl),'case_fields_verified':len(cf),'case_value_mismatches':len(cb),'forbidden_legacy_brand_values':len(leaks)}
Path(sys.argv[5]).write_text(json.dumps(summary,indent=2)+'\n')
print('\nVERIFICATION SUMMARY\n--------------------')
for k,v in summary.items():print(f'{k}: {v}')
if ob:print('Opportunity mismatch samples:',ob[:10])
if cb:print('Case mismatch samples:',cb[:10])
if leaks:print('Brand leak samples:',leaks[:10])
if len(oe)!=7618 or not ce or len(ce)>2994 or ob or cb or leaks:raise SystemExit('ERROR: Verification failed.')
print('\nPASS: Opportunity + Support source data verified.')
PY

  touch "$RUN_DIR/APPLY_VERIFIED"
  printf '%s\n' "$RUN_DIR" > "$RUN_ROOT/LAST_VERIFIED"
  echo "OPPORTUNITY + SUPPORT SOURCE LOAD COMPLETE"
}

commit_changes() {
  [ -f "$RUN_ROOT/LAST_VERIFIED" ] || { echo "ERROR: No verified load exists."; exit 1; }
  VERIFIED="$(cat "$RUN_ROOT/LAST_VERIFIED")"
  [ -f "$VERIFIED/APPLY_VERIFIED" ] || { echo "ERROR: Latest load is not verified."; exit 1; }

  paths=("$PERMSET" "$MANIFEST" "$VERSIONED_SCRIPT" "$DOC" "scripts/demo-source/07_repair_bongo_profile_anonymization.sh" "scripts/demo-source/BONGO_ANONYMIZATION.md")
  for f in "${OPP_NEW_FIELDS[@]}"; do paths+=("force-app/main/default/objects/Opportunity/fields/${f}.field-meta.xml"); done
  for f in "${CASE_NEW_FIELDS[@]}"; do paths+=("force-app/main/default/objects/Case/fields/${f}.field-meta.xml"); done
  existing=(); for p in "${paths[@]}"; do [ -e "$p" ] && existing+=("$p"); done
  git add -- "${existing[@]}"
  if git diff --cached --name-only | grep -Fxq "force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml"; then
    git restore --staged force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml
    echo "ERROR: Unrelated Portfolio Explorer change was staged."; exit 1
  fi
  echo "STAGED FILES"; git diff --cached --name-status
  echo "STAGED STAT"; git diff --cached --stat
  git diff --cached --check
  git commit -m "Add Bongo opportunity and support source reconstruction"
  echo "Commit: $(git rev-parse --short HEAD)"
  echo "Remaining worktree changes:"; git status --short
  echo "No push was performed."
}

case "$MODE" in
  prepare) prepare ;;
  schema-dry-run) schema_dry_run ;;
  schema-apply) schema_apply ;;
  preflight) preflight ;;
  apply) apply_data ;;
  commit) commit_changes ;;
  *) echo "Usage: $0 {prepare|schema-dry-run|schema-apply|preflight|apply|commit}"; exit 1 ;;
esac
