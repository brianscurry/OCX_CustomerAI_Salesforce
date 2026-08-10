#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-help}"
LOADER_VERSION="2026-08-10-name-join-v4"
PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
EXPECTED_DEMO_ACCOUNTS="${EXPECTED_DEMO_ACCOUNTS:-7755}"
DOWNLOADS="${DOWNLOADS:-$HOME/Downloads}"
PROFILE_2024="${PROFILE_2024:-$DOWNLOADS/profile_2024.csv}"
PROFILE_2025="${PROFILE_2025:-$DOWNLOADS/profile_2025.csv}"
MAPPING_FILE="${MAPPING_FILE:-}"

if [ -z "$MAPPING_FILE" ]; then
  MAPPING_FILE="$(find "$DOWNLOADS" -maxdepth 1 -type f -name 'conga_to_marumba_account_mapping*.csv' -print | sort | tail -1 || true)"
fi

if [ ! -d "$PROJECT" ] || [ ! -f "$PROJECT/sfdx-project.json" ]; then
  echo "ERROR: Salesforce project not found: $PROJECT" >&2
  exit 1
fi
cd "$PROJECT"

STAMP="$(date +%Y%m%d_%H%M%S)"
ROOT="$PROJECT/.ocx/profile-source"
RUN="$ROOT/runs/$STAMP"
mkdir -p "$RUN"

usage() {
  cat <<'EOF'
OCX profile source loader

Usage:
  15_load_profile_source_to_ocxdemo.sh build-local
  15_load_profile_source_to_ocxdemo.sh schema-dry-run
  15_load_profile_source_to_ocxdemo.sh schema-apply
  15_load_profile_source_to_ocxdemo.sh preflight
  15_load_profile_source_to_ocxdemo.sh apply
  15_load_profile_source_to_ocxdemo.sh rollback [rollback.csv]

Environment overrides:
  PROJECT=/path/to/ocx-salesforce
  ORG=OCXDemo
  DOWNLOADS=$HOME/Downloads
  PROFILE_2024=/path/profile_2024.csv
  PROFILE_2025=/path/profile_2025.csv
  MAPPING_FILE=/path/conga_to_marumba_account_mapping.csv

Safety / provenance rules:
  * profile_2025 is authoritative when an Account exists in both snapshots.
  * profile_2024 is used only for mapped Accounts absent from 2025.
  * Primary Account identity is translated through the provided Conga -> Marumba mapping.
  * The mapped Marumba Account ID and Account name are authoritative for loaded Accounts.
  * If a targeted class/value is not represented by the mapping file, its source value is passed through unchanged.
  * No additional pseudonymization, perturbation, category remapping, or synthetic transformation is applied.
  * Person/manager names therefore pass through unchanged because the current mapping does not map them.
  * C1 Account ID, TEST_ACCOUNT_C1, and SYSTEMMODSTAMP are not loaded because they are technical identifiers/audit fields, not feature ingredients for this demo.
  * Empty source values are written as #N/A so this behaves as a source snapshot,
    rather than leaving older synthetic/demo values in the targeted source fields.
  * A rollback CSV is created before every apply.
EOF
}

require_sources() {
  [ -f "$PROFILE_2024" ] || { echo "ERROR: missing $PROFILE_2024" >&2; exit 1; }
  [ -f "$PROFILE_2025" ] || { echo "ERROR: missing $PROFILE_2025" >&2; exit 1; }
  [ -n "$MAPPING_FILE" ] && [ -f "$MAPPING_FILE" ] || {
    echo "ERROR: could not find conga_to_marumba_account_mapping*.csv in $DOWNLOADS" >&2
    exit 1
  }
}

write_field() {
  local api="$1" label="$2" type="$3" extra="$4"
  local file="force-app/main/default/objects/Account/fields/${api}.field-meta.xml"
  if [ -f "$file" ]; then
    echo "  EXISTS: Account.$api"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${api}</fullName>
    <label>${label}</label>
    <type>${type}</type>
${extra}
</CustomField>
EOF
  echo "  CREATED: Account.$api"
}

cleanup_legacy_metadata() {
  local legacy_files=(
    "force-app/main/default/objects/Account/fields/Customer_Manager_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/New_Account_Owner_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/Previous_Account_Owner_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/Renewals_Manager_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/Source_Owner_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/Territory_Manager_Key__c.field-meta.xml"
    "force-app/main/default/objects/Account/fields/Source_Secondary_Account_ID__c.field-meta.xml"
  )
  local f
  for f in "${legacy_files[@]}"; do
    if [ -f "$f" ]; then
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        echo "ERROR: legacy profile-source field is tracked; refusing to delete automatically: $f" >&2
        exit 1
      fi
      rm -f "$f"
      echo "  REMOVED LEGACY GENERATED FILE: $f"
    fi
  done

  local perm="force-app/main/default/permissionsets/OCX_Profile_Source_Data.permissionset-meta.xml"
  if [ -f "$perm" ] && grep -Eq '(_Key__c|Source_Secondary_Account_ID__c)' "$perm"; then
    if git ls-files --error-unmatch "$perm" >/dev/null 2>&1; then
      echo "ERROR: stale OCX_Profile_Source_Data permission set is tracked; refusing to delete automatically: $perm" >&2
      exit 1
    fi
    rm -f "$perm"
    echo "  REMOVED LEGACY GENERATED FILE: $perm"
  fi
}

prepare_schema_files() {
  echo "Preparing source-profile field metadata..."

  write_field "C1_Account_Rank__c" "C1 Account Rank" "Text" "    <length>10</length>"
  write_field "Source_Account_Type__c" "Account Type (Source)" "Text" "    <length>40</length>"
  write_field "Geo_Name__c" "Geo Name" "Text" "    <length>40</length>"
  write_field "Division_Name__c" "Division Name" "Text" "    <length>80</length>"
  write_field "Source_Owner_Name__c" "Source Owner Name" "Text" "    <length>80</length>"
  write_field "Customer_Manager_Name__c" "Customer Manager Name" "Text" "    <length>80</length>"
  write_field "CS_Division_Stamp__c" "CS Division Stamp" "Text" "    <length>40</length>"
  write_field "Territory_Manager_Name__c" "Territory Manager Name" "Text" "    <length>80</length>"
  write_field "Renewals_Manager_Name__c" "Renewals Manager Name" "Text" "    <length>80</length>"
  write_field "Renewal_Date__c" "Renewal Date" "Date" ""
  write_field "DNB_Location_Type__c" "DNB Location Type" "Text" "    <length>40</length>"
  write_field "Billing_State_Code__c" "Billing State Code (Source)" "Text" "    <length>10</length>"
  write_field "Shipping_State_Code__c" "Shipping State Code (Source)" "Text" "    <length>10</length>"
  write_field "Billing_Country_Code__c" "Billing Country Code (Source)" "Text" "    <length>10</length>"
  write_field "Shipping_Country_Code__c" "Shipping Country Code (Source)" "Text" "    <length>10</length>"
  write_field "DNB_Zip_Postal_Code__c" "DNB Zip Postal Code" "Text" "    <length>30</length>"
  write_field "Source_Currency_Conversion_Rate__c" "Currency Conversion Rate (Source)" "Number" "    <precision>18</precision>\n    <scale>6</scale>"
  write_field "Source_Currency__c" "Currency (Source)" "Text" "    <length>3</length>"
  write_field "ACV_In_Currency__c" "ACV in Source Currency" "Number" "    <precision>18</precision>\n    <scale>2</scale>"
  write_field "Source_Industry__c" "Industry (Source)" "Text" "    <length>255</length>"
  write_field "Mintigo_Score__c" "Mintigo Score" "Number" "    <precision>6</precision>\n    <scale>2</scale>"
  write_field "DNB_SIC4_Description__c" "DNB SIC4 Description" "Text" "    <length>255</length>"
  write_field "Source_Created_Date__c" "Created Date (Source)" "Date" ""
  write_field "DNB_Out_Of_Business_Status__c" "DNB Out of Business Status" "Text" "    <length>40</length>"
  write_field "New_Account_Owner__c" "New Account Owner" "Text" "    <length>80</length>"
  write_field "Previous_Account_Owner__c" "Previous Account Owner" "Text" "    <length>80</length>"
  write_field "Customer_Health__c" "Customer Health" "Text" "    <length>40</length>"
  write_field "Account_Support_Level__c" "Support Level" "Text" "    <length>40</length>"
  write_field "Product_Family_List__c" "Product Family List" "Text" "    <length>255</length>"
  write_field "Product_Family_Number__c" "Product Family Number" "Number" "    <precision>6</precision>\n    <scale>0</scale>"
  write_field "CS_Experience__c" "CS Experience" "Text" "    <length>40</length>"
  write_field "Account_Escalation_Status__c" "Account Escalation Status" "Text" "    <length>80</length>"
  write_field "Community_Users__c" "Community Users" "Number" "    <precision>12</precision>\n    <scale>0</scale>"
  write_field "Super_Users__c" "Super Users" "Number" "    <precision>12</precision>\n    <scale>0</scale>"
  write_field "Super_User_Ratio__c" "Super User Ratio" "Number" "    <precision>8</precision>\n    <scale>4</scale>"
  write_field "Last_Login_Date__c" "Last Login Date" "Date" ""

  local perm="force-app/main/default/permissionsets/OCX_Profile_Source_Data.permissionset-meta.xml"
  if [ ! -f "$perm" ]; then
    python3 - "$perm" <<'PY'
import sys
from pathlib import Path
fields = [
"C1_Account_Rank__c","Source_Account_Type__c","Geo_Name__c","Division_Name__c",
"Source_Owner_Name__c","Customer_Manager_Name__c","CS_Division_Stamp__c","Territory_Manager_Name__c","Renewals_Manager_Name__c",
"Renewal_Date__c","DNB_Location_Type__c","Billing_State_Code__c","Shipping_State_Code__c","Billing_Country_Code__c",
"Shipping_Country_Code__c","DNB_Zip_Postal_Code__c","Source_Currency_Conversion_Rate__c","Source_Currency__c","ACV_In_Currency__c",
"Source_Industry__c","Mintigo_Score__c","DNB_SIC4_Description__c","Source_Created_Date__c","DNB_Out_Of_Business_Status__c",
"New_Account_Owner__c","Previous_Account_Owner__c","Customer_Health__c","Account_Support_Level__c","Product_Family_List__c",
"Product_Family_Number__c","CS_Experience__c","Account_Escalation_Status__c","Community_Users__c","Super_Users__c",
"Super_User_Ratio__c","Last_Login_Date__c"
]
p=Path(sys.argv[1]); p.parent.mkdir(parents=True, exist_ok=True)
parts=['<?xml version="1.0" encoding="UTF-8"?>','<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">']
for f in fields:
    parts += ['    <fieldPermissions>','        <editable>true</editable>',f'        <field>Account.{f}</field>','        <readable>true</readable>','    </fieldPermissions>']
parts += ['    <label>OCX Profile Source Data</label>','</PermissionSet>']
p.write_text('\n'.join(parts)+'\n')
PY
    echo "  CREATED: OCX_Profile_Source_Data permission set"
  else
    echo "  EXISTS: OCX_Profile_Source_Data permission set"
  fi

  local manifest="manifest/ocx-profile-source-data.xml"
  mkdir -p manifest
  python3 - "$manifest" <<'PY'
import sys
from pathlib import Path
fields = [
"C1_Account_Rank__c","Source_Account_Type__c","Geo_Name__c","Division_Name__c",
"Source_Owner_Name__c","Customer_Manager_Name__c","CS_Division_Stamp__c","Territory_Manager_Name__c","Renewals_Manager_Name__c",
"Renewal_Date__c","DNB_Location_Type__c","Billing_State_Code__c","Shipping_State_Code__c","Billing_Country_Code__c",
"Shipping_Country_Code__c","DNB_Zip_Postal_Code__c","Source_Currency_Conversion_Rate__c","Source_Currency__c","ACV_In_Currency__c",
"Source_Industry__c","Mintigo_Score__c","DNB_SIC4_Description__c","Source_Created_Date__c","DNB_Out_Of_Business_Status__c",
"New_Account_Owner__c","Previous_Account_Owner__c","Customer_Health__c","Account_Support_Level__c","Product_Family_List__c",
"Product_Family_Number__c","CS_Experience__c","Account_Escalation_Status__c","Community_Users__c","Super_Users__c",
"Super_User_Ratio__c","Last_Login_Date__c"
]
p=Path(sys.argv[1]); p.parent.mkdir(parents=True, exist_ok=True)
lines=['<?xml version="1.0" encoding="UTF-8"?>','<Package xmlns="http://soap.sforce.com/2006/04/metadata">','    <types>']
for f in fields: lines.append(f'        <members>Account.{f}</members>')
lines += ['        <name>CustomField</name>','    </types>','    <types>','        <members>OCX_Profile_Source_Data</members>','        <name>PermissionSet</name>','    </types>','    <version>67.0</version>','</Package>']
p.write_text('\n'.join(lines)+'\n')
PY
  echo "  WROTE: $manifest"
}

build_local() {
  require_sources
  mkdir -p "$ROOT"

  python3 - "$PROFILE_2024" "$PROFILE_2025" "$MAPPING_FILE" "$RUN" <<'PY'
import csv, json, sys
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

p24, p25, pmap, run = map(Path, sys.argv[1:])
run.mkdir(parents=True, exist_ok=True)

EXPECTED = [
'Account ID','C1 Account ID','ACCOUNT_NAME','C1_ACCOUNT_RANK','TYPE','GEO_NAME','REGION_NAME','SEGMENT_NAME','DIVISION_NAME',
'OWNER_NAME','CUSTOMER_MANAGER_NAME','CS_DIVISION_STAMP','TERRITORY_MANAGER_NAME','RENEWALS_MANAGER_NAME','RENEWAL_DATE',
'NUMBER_OF_EMPLOYEES','ANNUAL_REVENUE','DNB_LOCATION_TYPE','BILLING_CITY','SHIPPING_CITY','BILLING_STATE',
'BILLING_STATE_CODE_ABBREVIATION','SHIPPING_STATE','SHIPPING_STATE_CODE','BILLING_COUNTRY','BILLING_COUNTRY_CODE',
'SHIPPING_COUNTRY','SHIPPING_COUNTRY_CODE','BILLING_ZIP_POSTAL_CODE','DNB_ZIP_POSTAL_CODE','SHIPPING_ZIP_POSTAL_CODE',
'CURRENCY_CONVERSION_RATE','CURRENCY','ACV_IN_CURRENCY','ACV','CUSTOMER_SINCE_DATE','INDUSTRY','MINTIGO_SCORE','DNB_SIC4_CODE1',
'CREATED_DATE','TEST_ACCOUNT_C1','DNB_OUTOFBUSINESSINDICATOR','NEW_ACCOUNT_OWNER','PREVIOUS_ACCOUNT_OWNER','CUSTOMER_HEALTH',
'SYSTEMMODSTAMP','SUPPORT_LEVEL','PRODUCT_FAMILY_LIST','PRODUCT_FAMILY_NUMBER','CS_EXPERIENCE','ACCOUNT_ESCALATION_STATUS',
'COMMUNITY_USERS','SUPER_USERS','SUPER_USER_RATIO','LAST LOGIN'
]

# IMPORTANT ANONYMIZATION RULE:
#   - Account ID and Account Name are the classes explicitly anonymized by the supplied mapping.
#   - For loaded Accounts, use ONLY the mapped Marumba identity.
#   - Every other targeted profile value passes through from the selected source snapshot unchanged,
#     except for type-safe formatting needed by Salesforce (numbers/dates).
#   - Do not invent any additional anonymization, perturbation, remapping, or pseudonyms.
TARGET_MAP = [
('C1_ACCOUNT_RANK','C1_Account_Rank__c','text'),
('TYPE','Source_Account_Type__c','text'),
('GEO_NAME','Geo_Name__c','text'),
('REGION_NAME','Region__c','text'),
('SEGMENT_NAME','Customer_Segment__c','text'),
('DIVISION_NAME','Division_Name__c','text'),
('OWNER_NAME','Source_Owner_Name__c','text'),
('CUSTOMER_MANAGER_NAME','Customer_Manager_Name__c','text'),
('CS_DIVISION_STAMP','CS_Division_Stamp__c','text'),
('TERRITORY_MANAGER_NAME','Territory_Manager_Name__c','text'),
('RENEWALS_MANAGER_NAME','Renewals_Manager_Name__c','text'),
('RENEWAL_DATE','Renewal_Date__c','date'),
('NUMBER_OF_EMPLOYEES','NumberOfEmployees','int'),
('ANNUAL_REVENUE','AnnualRevenue','decimal'),
('DNB_LOCATION_TYPE','DNB_Location_Type__c','text'),
('BILLING_CITY','BillingCity','text'),
('SHIPPING_CITY','ShippingCity','text'),
('BILLING_STATE','BillingState','text'),
('BILLING_STATE_CODE_ABBREVIATION','Billing_State_Code__c','text'),
('SHIPPING_STATE','ShippingState','text'),
('SHIPPING_STATE_CODE','Shipping_State_Code__c','text'),
('BILLING_COUNTRY','BillingCountry','text'),
('BILLING_COUNTRY_CODE','Billing_Country_Code__c','text'),
('SHIPPING_COUNTRY','ShippingCountry','text'),
('SHIPPING_COUNTRY_CODE','Shipping_Country_Code__c','text'),
('BILLING_ZIP_POSTAL_CODE','BillingPostalCode','text'),
('DNB_ZIP_POSTAL_CODE','DNB_Zip_Postal_Code__c','text'),
('SHIPPING_ZIP_POSTAL_CODE','ShippingPostalCode','text'),
('CURRENCY_CONVERSION_RATE','Source_Currency_Conversion_Rate__c','decimal'),
('CURRENCY','Source_Currency__c','text'),
('ACV_IN_CURRENCY','ACV_In_Currency__c','decimal'),
('ACV','OCX_ACV__c','decimal'),
('CUSTOMER_SINCE_DATE','Customer_Since_Date__c','date'),
('INDUSTRY','Source_Industry__c','text'),
('MINTIGO_SCORE','Mintigo_Score__c','decimal'),
('DNB_SIC4_CODE1','DNB_SIC4_Description__c','text'),
('CREATED_DATE','Source_Created_Date__c','date'),
('DNB_OUTOFBUSINESSINDICATOR','DNB_Out_Of_Business_Status__c','text'),
('NEW_ACCOUNT_OWNER','New_Account_Owner__c','text'),
('PREVIOUS_ACCOUNT_OWNER','Previous_Account_Owner__c','text'),
('CUSTOMER_HEALTH','Customer_Health__c','text'),
('SUPPORT_LEVEL','Account_Support_Level__c','text'),
('PRODUCT_FAMILY_LIST','Product_Family_List__c','text'),
('PRODUCT_FAMILY_NUMBER','Product_Family_Number__c','int'),
('CS_EXPERIENCE','CS_Experience__c','text'),
('ACCOUNT_ESCALATION_STATUS','Account_Escalation_Status__c','text'),
('COMMUNITY_USERS','Community_Users__c','int'),
('SUPER_USERS','Super_Users__c','int'),
('SUPER_USER_RATIO','Super_User_Ratio__c','decimal'),
('LAST LOGIN','Last_Login_Date__c','date'),
]

IGNORED = {
'Unnamed: 0':'export row index only',
'C1 Account ID':'legacy/secondary technical identifier; not used as a feature ingredient and no Marumba mapping is supplied for it',
'TEST_ACCOUNT_C1':'test/admin marker',
'SYSTEMMODSTAMP':'technical source-system audit timestamp; not a feature ingredient for this demo',
}

def read_csv(path):
    with path.open(newline='', encoding='utf-8-sig') as f:
        r = csv.DictReader(f)
        rows = list(r)
        return r.fieldnames or [], rows

h24, r24 = read_csv(p24)
h25, r25 = read_csv(p25)
hm, rm = read_csv(pmap)
for year, header in [('2024', h24), ('2025', h25)]:
    missing = [c for c in EXPECTED if c not in header]
    if missing:
        raise SystemExit(f'{year} profile missing expected columns: {missing}')
for c in ['account_id_marumba','account_id_conga','account_name_marumba']:
    if c not in hm:
        raise SystemExit(f'mapping missing {c}')

mapping_all = {
    x['account_id_conga'].strip(): x
    for x in rm
    if x.get('account_id_conga') and x.get('account_id_marumba') and x.get('account_name_marumba')
}
source_mapping_ids = [x.get('account_id_conga','').strip() for x in rm if x.get('account_id_conga')]
if len(mapping_all) != len(set(source_mapping_ids)):
    raise SystemExit('mapping contains duplicate or incomplete Conga Account IDs')

# The supplied mapping is authoritative for demo population as well as identity.
# A Marumba Account Name of #N/A means the prototype Account was intentionally
# removed from the demo population. Those rows must never be loaded or recreated.
removed_mapping = {
    k:v for k,v in mapping_all.items()
    if (v.get('account_name_marumba') or '').strip() == '#N/A'
}
mapping = {
    k:v for k,v in mapping_all.items()
    if (v.get('account_name_marumba') or '').strip() not in ('', '#N/A')
}

# Only active Accounts with an explicit Conga -> Marumba identity mapping are eligible to load.
# This prevents a removed/unmapped prototype Account identity from being written to the demo org.
def mapped_rows(rows, year):
    out = {}
    for row in rows:
        raw = (row.get('Account ID') or '').strip()
        if raw in mapping:
            rr = dict(row)
            rr['_source_year'] = year
            out[raw] = rr
    return out

m24 = mapped_rows(r24, '2024')
m25 = mapped_rows(r25, '2025')
latest = dict(m24)
latest.update(m25)  # 2025 wins; 2024 survives only when the mapped Account is absent from 2025.

def clean_text(v):
    return (v or '').strip()

def clean_int(v):
    v = clean_text(v)
    if not v:
        return ''
    try:
        return str(int(Decimal(v)))
    except Exception:
        raise ValueError(f'invalid integer {v!r}')

def clean_decimal(v):
    v = clean_text(v)
    if not v:
        return ''
    try:
        d = Decimal(v)
        s = format(d, 'f')
        if '.' in s:
            s = s.rstrip('0').rstrip('.')
        return s or '0'
    except InvalidOperation:
        raise ValueError(f'invalid decimal {v!r}')

def clean_date(v):
    v = clean_text(v)
    if not v:
        return ''
    datetime.strptime(v, '%Y-%m-%d')
    return v

def convert(kind, v):
    if kind == 'text':
        return clean_text(v)
    if kind == 'int':
        return clean_int(v)
    if kind == 'decimal':
        return clean_decimal(v)
    if kind == 'date':
        return clean_date(v)
    raise ValueError(kind)

fields = ['OCX_Account_ID__c', 'Name', 'Source_Snapshot_Year'] + [t for _, t, _ in TARGET_MAP]
out = []
for raw_account_id, row in latest.items():
    mp = mapping[raw_account_id]
    rec = {
        'OCX_Account_ID__c': clean_text(mp['account_id_marumba']),
        'Name': clean_text(mp['account_name_marumba']),
        'Source_Snapshot_Year': row['_source_year'],
    }
    for src, tgt, kind in TARGET_MAP:
        rec[tgt] = convert(kind, row.get(src, ''))
    out.append(rec)

out.sort(key=lambda x: x['OCX_Account_ID__c'])

with (run / 'mapped_latest_profile.csv').open('w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields, lineterminator='\n')
    w.writeheader()
    w.writerows(out)

with (run / 'field_mapping.csv').open('w', newline='', encoding='utf-8') as f:
    cols = ['source_column','salesforce_field','treatment','notes']
    w = csv.DictWriter(f, fieldnames=cols, lineterminator='\n')
    w.writeheader()
    w.writerow({
        'source_column':'Account ID',
        'salesforce_field':'OCX_Account_ID__c',
        'treatment':'mapped',
        'notes':'Use account_id_marumba from supplied Conga -> Marumba mapping for active demo Accounts only; Accounts whose mapped Marumba name is #N/A are intentionally removed and are not loaded.'
    })
    w.writerow({
        'source_column':'ACCOUNT_NAME',
        'salesforce_field':'Name',
        'treatment':'mapped',
        'notes':'Use account_name_marumba from supplied Conga -> Marumba mapping. A mapped name of #N/A marks an Account intentionally removed from the demo population.'
    })
    for src, tgt, kind in TARGET_MAP:
        note = 'Passed through from selected prototype source snapshot.'
        if kind in ('int','decimal','date'):
            note += ' Formatting is normalized only as required for the Salesforce field type; the underlying value is not transformed.'
        w.writerow({'source_column':src,'salesforce_field':tgt,'treatment':'pass-through','notes':note})
    for src, reason in IGNORED.items():
        w.writerow({'source_column':src,'salesforce_field':'','treatment':'ignored','notes':reason})

stats = {
    'mapping_rows_total': len(mapping_all),
    'mapping_rows_intentionally_removed_from_demo': len(removed_mapping),
    'active_demo_mapping_rows': len(mapping),
    'profile_2024_rows': len(r24),
    'profile_2025_rows': len(r25),
    'active_mapped_2024_accounts': len(m24),
    'active_mapped_2025_accounts': len(m25),
    'latest_active_mapped_accounts': len(out),
    'latest_from_2025': sum(1 for x in out if x['Source_Snapshot_Year'] == '2025'),
    'fallback_from_2024': sum(1 for x in out if x['Source_Snapshot_Year'] == '2024'),
    'active_mapping_accounts_without_profile': len(set(mapping) - set(latest)),
    'mapped_identity_classes': ['Account ID', 'Account Name'],
    'pass_through_profile_fields': len(TARGET_MAP),
    'ignored_columns': IGNORED,
    'additional_anonymization_applied': False,
}
(run / 'local_build_summary.json').write_text(json.dumps(stats, indent=2) + '\n')
print(json.dumps(stats, indent=2))
print(f"Mapped profile: {run / 'mapped_latest_profile.csv'}")
print(f"Field mapping:  {run / 'field_mapping.csv'}")
PY
}

latest_run_file() {
  local name="$1"
  find "$ROOT/runs" -type f -name "$name" -print 2>/dev/null | sort | tail -1
}

preflight() {
  require_sources
  build_local

  echo
  echo "Describing live Account schema..."
  sf sobject describe --sobject Account --target-org "$ORG" --json > "$RUN/account-describe.json"

  echo "Querying all demo Account identities..."
  sf data query \
    --target-org "$ORG" \
    --query "SELECT Id,Name,OCX_Account_ID__c FROM Account" \
    --result-format csv \
    --output-file "$RUN/org-account-identity.csv"

  python3 - "$RUN" "$EXPECTED_DEMO_ACCOUNTS" <<'PY'
import csv,json,sys
from collections import defaultdict
from pathlib import Path

run=Path(sys.argv[1])
expected=int(sys.argv[2])
source=list(csv.DictReader((run/'mapped_latest_profile.csv').open(newline='',encoding='utf-8')))
org=list(csv.DictReader((run/'org-account-identity.csv').open(newline='',encoding='utf-8-sig')))
desc=json.loads((run/'account-describe.json').read_text())
if isinstance(desc,dict) and 'result' in desc:
    desc=desc['result']
fields={f['name']:f for f in desc.get('fields',[])}

# Identity fields are join-only. This loader never changes them.
source_fields=[c for c in source[0].keys() if c not in ('OCX_Account_ID__c','Name','Source_Snapshot_Year')]
missing=[f for f in source_fields if f not in fields]
not_updateable=[f for f in source_fields if f in fields and not fields[f].get('updateable',False)]
if missing:
    print('ERROR: Salesforce fields missing:')
    for x in missing:
        print('  '+x)
    print('Run schema-dry-run, then schema-apply.')
    raise SystemExit(2)
if not_updateable:
    print('ERROR: Salesforce fields not updateable:')
    for x in not_updateable:
        print('  '+x)
    raise SystemExit(2)

def join_name(v):
    # Values are not transformed; only whitespace is normalized for matching.
    return ' '.join((v or '').strip().split())

source_by_name=defaultdict(list)
for i,s in enumerate(source):
    name=join_name(s.get('Name'))
    if name:
        source_by_name[name].append((i,s))

org_by_name=defaultdict(list)
for o in org:
    name=join_name(o.get('Name'))
    if name:
        org_by_name[name].append(o)

matched=[]
matched_pairs=[]
unmatched_org=[]
ambiguous_org=[]
used_source_indices=set()

for o in org:
    org_name=join_name(o.get('Name'))
    candidates=source_by_name.get(org_name,[])
    if len(candidates)==0:
        unmatched_org.append({
            'Id':o.get('Id',''),
            'Name':o.get('Name',''),
            'OCX_Account_ID__c':o.get('OCX_Account_ID__c',''),
        })
        continue
    if len(candidates)>1:
        ambiguous_org.append({
            'Id':o.get('Id',''),
            'Name':o.get('Name',''),
            'OCX_Account_ID__c':o.get('OCX_Account_ID__c',''),
            'candidate_count':len(candidates),
        })
        continue

    idx,s=candidates[0]
    used_source_indices.add(idx)
    rec={'Id':o['Id']}
    for f in source_fields:
        v=s.get(f,'')
        rec[f]=v if v!='' else '#N/A'
    matched.append(rec)
    matched_pairs.append({
        'Salesforce_Id':o.get('Id',''),
        'Salesforce_Name':o.get('Name',''),
        'Current_OCX_Account_ID__c':o.get('OCX_Account_ID__c',''),
        'Mapped_Profile_Account_ID':s.get('OCX_Account_ID__c',''),
        'Mapped_Profile_Name':s.get('Name',''),
        'Source_Snapshot_Year':s.get('Source_Snapshot_Year',''),
    })

extra_source=[]
for i,s in enumerate(source):
    if i not in used_source_indices:
        extra_source.append({
            'Mapped_Profile_Account_ID':s.get('OCX_Account_ID__c',''),
            'Mapped_Profile_Name':s.get('Name',''),
            'Source_Snapshot_Year':s.get('Source_Snapshot_Year',''),
        })

with (run/'account_updates.csv').open('w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=['Id']+source_fields,lineterminator='\n')
    w.writeheader(); w.writerows(matched)
with (run/'matched_account_pairs.csv').open('w',newline='',encoding='utf-8') as f:
    cols=['Salesforce_Id','Salesforce_Name','Current_OCX_Account_ID__c','Mapped_Profile_Account_ID','Mapped_Profile_Name','Source_Snapshot_Year']
    w=csv.DictWriter(f,fieldnames=cols,lineterminator='\n')
    w.writeheader(); w.writerows(matched_pairs)
with (run/'unmatched_org_accounts_excluded.csv').open('w',newline='',encoding='utf-8') as f:
    cols=['Id','Name','OCX_Account_ID__c']
    w=csv.DictWriter(f,fieldnames=cols,lineterminator='\n')
    w.writeheader(); w.writerows(unmatched_org)
with (run/'ambiguous_org_accounts.csv').open('w',newline='',encoding='utf-8') as f:
    cols=['Id','Name','OCX_Account_ID__c','candidate_count']
    w=csv.DictWriter(f,fieldnames=cols,lineterminator='\n')
    w.writeheader(); w.writerows(ambiguous_org)
with (run/'extra_source_profiles_ignored.csv').open('w',newline='',encoding='utf-8') as f:
    cols=['Mapped_Profile_Account_ID','Mapped_Profile_Name','Source_Snapshot_Year']
    w=csv.DictWriter(f,fieldnames=cols,lineterminator='\n')
    w.writeheader(); w.writerows(extra_source)

source_duplicate_names=sum(1 for rows in source_by_name.values() if len(rows)>1)
org_duplicate_names=sum(1 for rows in org_by_name.values() if len(rows)>1)
summary={
    'authoritative_demo_accounts_expected':expected,
    'org_account_rows_total':len(org),
    'available_mapped_source_profiles':len(source),
    'matched_demo_accounts_for_update':len(matched),
    'unmatched_org_accounts_excluded':len(unmatched_org),
    'ambiguous_org_accounts':len(ambiguous_org),
    'extra_source_profiles_ignored':len(extra_source),
    'duplicate_source_names_total':source_duplicate_names,
    'duplicate_salesforce_names_total':org_duplicate_names,
    'fields_to_update':len(source_fields),
    'account_name_will_be_updated':False,
    'ocx_account_id_will_be_updated':False,
}
(run/'preflight_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))

if len(matched)!=expected:
    print(f'ERROR: Expected exactly {expected} matched demo Accounts, found {len(matched)}.')
    raise SystemExit(3)
if ambiguous_org:
    print(f'ERROR: {len(ambiguous_org)} Salesforce Accounts have ambiguous source-name matches.')
    raise SystemExit(4)
PY

  FIELDS="$(python3 - "$RUN/account_updates.csv" <<'PY'
import csv,sys
with open(sys.argv[1],newline='',encoding='utf-8') as f:
    h=next(csv.reader(f))
print(','.join(h[1:]))
PY
)"

  echo
  echo "Querying current Account values for rollback..."
  sf data query \
    --target-org "$ORG" \
    --query "SELECT Id,$FIELDS FROM Account" \
    --result-format csv \
    --output-file "$RUN/rollback_all_account_values_raw.csv"

  python3 - "$RUN" <<'PY'
import csv,sys
from pathlib import Path
run=Path(sys.argv[1])
with (run/'account_updates.csv').open(newline='',encoding='utf-8') as f:
    updates=list(csv.DictReader(f))
ids={r['Id'] for r in updates}
with (run/'rollback_all_account_values_raw.csv').open(newline='',encoding='utf-8-sig') as f:
    rows=list(csv.DictReader(f))
header=list(rows[0].keys()) if rows else []
selected=[]
for r in rows:
    if r.get('Id') not in ids:
        continue
    out={}
    for k in header:
        v=r.get(k,'')
        out[k]=v if (k=='Id' or v!='') else '#N/A'
    selected.append(out)
if len(selected)!=len(ids):
    raise SystemExit(f'ERROR: rollback snapshot contains {len(selected)} records, expected {len(ids)}')
with (run/'rollback_account_values.csv').open('w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=header,lineterminator='\n')
    w.writeheader(); w.writerows(selected)
print(f'Rollback records prepared: {len(selected)}')
PY

  rm -f "$RUN/rollback_all_account_values_raw.csv"

  echo
  echo "============================================================"
  echo "PROFILE SOURCE PREFLIGHT COMPLETE"
  echo "============================================================"
  cat "$RUN/preflight_summary.json"
  echo
  echo "Matched pairs: $RUN/matched_account_pairs.csv"
  echo "Excluded org:  $RUN/unmatched_org_accounts_excluded.csv"
  echo "Ignored source:$RUN/extra_source_profiles_ignored.csv"
  echo "Update CSV:    $RUN/account_updates.csv"
  echo "Rollback CSV:  $RUN/rollback_account_values.csv"
  echo "No Salesforce records were modified."
}

apply_data() {
  preflight
  echo
  echo "Applying Account source snapshot with Bulk API 2.0..."
  sf data update bulk \
    --target-org "$ORG" \
    --sobject Account \
    --file "$RUN/account_updates.csv" \
    --line-ending LF \
    --wait 30

  echo
  echo "Verifying key source-field coverage..."
  sf data query --target-org "$ORG" --query "SELECT count() FROM Account WHERE OCX_Account_ID__c != null AND Customer_Since_Date__c != null" --result-format human
  sf data query --target-org "$ORG" --query "SELECT count() FROM Account WHERE OCX_Account_ID__c != null AND Source_Industry__c != null" --result-format human
  sf data query --target-org "$ORG" --query "SELECT count() FROM Account WHERE OCX_Account_ID__c != null AND Product_Family_Number__c != null" --result-format human
  sf data query --target-org "$ORG" --query "SELECT count() FROM Account WHERE OCX_Account_ID__c != null AND Last_Login_Date__c != null" --result-format human

  echo
  echo "============================================================"
  echo "PROFILE SOURCE LOAD COMPLETE"
  echo "============================================================"
  echo "Rollback file: $RUN/rollback_account_values.csv"
}

rollback_data() {
  local rb="${2:-}"
  if [ -z "$rb" ]; then
    rb="$(latest_run_file rollback_account_values.csv)"
  fi
  [ -n "$rb" ] && [ -f "$rb" ] || { echo "ERROR: rollback CSV not found" >&2; exit 1; }
  echo "Rolling back Account fields from: $rb"
  sf data update bulk --target-org "$ORG" --sobject Account --file "$rb" --line-ending LF --wait 30
  echo "Rollback submitted/completed."
}

echo "OCX profile source loader: $LOADER_VERSION"

case "$MODE" in
  help|-h|--help) usage ;;
  build-local)
    build_local
    ;;
  schema-dry-run)
    cleanup_legacy_metadata
    prepare_schema_files
    echo
    sf project deploy start --target-org "$ORG" --manifest manifest/ocx-profile-source-data.xml --dry-run --test-level NoTestRun --wait 30
    ;;
  schema-apply)
    cleanup_legacy_metadata
    prepare_schema_files
    echo
    sf project deploy start --target-org "$ORG" --manifest manifest/ocx-profile-source-data.xml --test-level NoTestRun --wait 30
    sf org assign permset --target-org "$ORG" --name OCX_Profile_Source_Data
    ;;
  preflight)
    preflight
    ;;
  apply)
    apply_data
    ;;
  rollback)
    rollback_data "$@"
    ;;
  *) echo "ERROR: unknown mode: $MODE" >&2; usage; exit 2 ;;
esac
