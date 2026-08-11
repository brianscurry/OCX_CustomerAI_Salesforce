#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-$HOME/Downloads/ocx-migration/ocx-salesforce}"
ORG="${ORG:-OCXDemo}"
MODE="${1:-audit}"

cd "$PROJECT"

BASE="force-app/main/default"
MANIFEST="manifest/ocx-cx-source-intelligence-foundation.xml"
PERMSET="$BASE/permissionsets/OCX_CX_Source_Intelligence.permissionset-meta.xml"
SCRIPT_DIR="scripts/source-intelligence"
SEED_DIR="$SCRIPT_DIR/seeds"
VERSIONED_SCRIPT="$SCRIPT_DIR/01_create_foundation.sh"
DOC="$SCRIPT_DIR/README.md"

OBJECTS=(
  OCX_CX_Theme__c
  OCX_CX_Concept__c
  OCX_Feature_Template__c
  OCX_Source_Intelligence_Run__c
  OCX_Source_Ingredient__c
  OCX_Feature_Definition__c
  OCX_Feature_Ingredient__c
)

echo
echo "============================================================"
echo "OCX CX SOURCE INTELLIGENCE FOUNDATION v2"
echo "============================================================"
echo "Project: $PROJECT"
echo "Org:     $ORG"
echo "Mode:    $MODE"
echo
echo "Feature classes:"
echo "  DIRECT_EXPERIENCE"
echo "  PROFILE"
echo "  COHORT_DERIVED"
echo "============================================================"
echo

audit() {
  echo "READ ONLY audit."
  echo
  echo "Target Salesforce objects:"
  for o in "${OBJECTS[@]}"; do
    if sf sobject describe --target-org "$ORG" --sobject "$o" --json >/dev/null 2>&1; then
      echo "  EXISTS:      $o"
    else
      echo "  NOT PRESENT: $o"
    fi
  done

  echo
  echo "Current related Git status:"
  git status --short -- \
    "$SCRIPT_DIR" \
    "$PERMSET" \
    "$MANIFEST" \
    "$BASE/objects/OCX_CX_Theme__c" \
    "$BASE/objects/OCX_CX_Concept__c" \
    "$BASE/objects/OCX_Feature_Template__c" \
    "$BASE/objects/OCX_Source_Intelligence_Run__c" \
    "$BASE/objects/OCX_Source_Ingredient__c" \
    "$BASE/objects/OCX_Feature_Definition__c" \
    "$BASE/objects/OCX_Feature_Ingredient__c" || true

  echo
  echo "AUDIT COMPLETE - nothing modified."
}

prepare() {
  mkdir -p "$SCRIPT_DIR" "$SEED_DIR" manifest

  python3 - "$PROJECT" <<'PY'
from pathlib import Path
from xml.sax.saxutils import escape
import csv
import sys

project = Path(sys.argv[1])
base = project / "force-app/main/default"
objects_root = base / "objects"
permsets_root = base / "permissionsets"
manifest_root = project / "manifest"
seed_root = project / "scripts/source-intelligence/seeds"

for p in (objects_root, permsets_root, manifest_root, seed_root):
    p.mkdir(parents=True, exist_ok=True)

NS = "http://soap.sforce.com/2006/04/metadata"

def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")

def custom_object(api, label, plural, name_label, auto=None, description=""):
    if auto:
        name_field = f"""    <nameField>
        <displayFormat>{escape(auto)}</displayFormat>
        <label>{escape(name_label)}</label>
        <type>AutoNumber</type>
    </nameField>"""
    else:
        name_field = f"""    <nameField>
        <label>{escape(name_label)}</label>
        <type>Text</type>
    </nameField>"""

    write(
        objects_root / api / f"{api}.object-meta.xml",
        f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="{NS}">
    <deploymentStatus>Deployed</deploymentStatus>
    <description>{escape(description)}</description>
    <enableActivities>false</enableActivities>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <label>{escape(label)}</label>
{name_field}
    <pluralLabel>{escape(plural)}</pluralLabel>
    <sharingModel>{"ControlledByParent" if api in {
        "OCX_Source_Ingredient__c",
        "OCX_Feature_Definition__c",
        "OCX_Feature_Ingredient__c",
    } else "ReadWrite"}</sharingModel>
</CustomObject>
"""
    )

def field(obj, api, label, kind, **kw):
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<CustomField xmlns="{NS}">',
        f'    <fullName>{api}</fullName>',
    ]

    if kw.get("description"):
        parts.append(f'    <description>{escape(kw["description"])}</description>')

    if kind == "Text":
        if kw.get("externalId"):
            parts.append("    <externalId>true</externalId>")
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append(f'    <length>{kw.get("length",255)}</length>')
        parts.append("    <type>Text</type>")
        if kw.get("unique"):
            parts.append("    <unique>true</unique>")

    elif kind == "LongTextArea":
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append(f'    <length>{kw.get("length",32768)}</length>')
        parts.append("    <type>LongTextArea</type>")
        parts.append(f'    <visibleLines>{kw.get("visibleLines",5)}</visibleLines>')

    elif kind == "Number":
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append(f'    <precision>{kw.get("precision",18)}</precision>')
        parts.append(f'    <scale>{kw.get("scale",2)}</scale>')
        parts.append("    <type>Number</type>")

    elif kind == "Checkbox":
        parts.append(f'    <defaultValue>{str(kw.get("default",False)).lower()}</defaultValue>')
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append("    <type>Checkbox</type>")

    elif kind in ("Date", "DateTime"):
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append(f'    <type>{kind}</type>')

    elif kind in ("Lookup", "MasterDetail"):
        parts.append(f'    <label>{escape(label)}</label>')
        parts.append(f'    <referenceTo>{kw["referenceTo"]}</referenceTo>')
        parts.append(f'    <relationshipLabel>{escape(kw["relationshipLabel"])}</relationshipLabel>')
        parts.append(f'    <relationshipName>{kw["relationshipName"]}</relationshipName>')
        parts.append(f'    <type>{kind}</type>')
        if kind == "MasterDetail":
            parts.append("    <writeRequiresMasterRead>false</writeRequiresMasterRead>")

    else:
        raise ValueError(kind)

    parts.append("</CustomField>")
    write(objects_root / obj / "fields" / f"{api}.field-meta.xml",
          "\n".join(parts) + "\n")

# -------------------------------------------------------------------
# Objects
# -------------------------------------------------------------------
custom_object(
    "OCX_CX_Theme__c",
    "CX Theme",
    "CX Themes",
    "Theme Name",
    description="Stable top-level CX measurement theme."
)
custom_object(
    "OCX_CX_Concept__c",
    "CX Measurement Concept",
    "CX Measurement Concepts",
    "Concept Name",
    description="Reusable CX measurement concept beneath a theme."
)
custom_object(
    "OCX_Feature_Template__c",
    "Feature Template",
    "Feature Templates",
    "Template Name",
    description="Reusable formula/archetype for Direct Experience, Profile, and Cohort-derived features."
)
custom_object(
    "OCX_Source_Intelligence_Run__c",
    "Source Intelligence Run",
    "Source Intelligence Runs",
    "Run Number",
    auto="SIR-{000000}",
    description="Run-level lineage and purge boundary for generated source intelligence."
)
custom_object(
    "OCX_Source_Ingredient__c",
    "Source Ingredient",
    "Source Ingredients",
    "Ingredient Name",
    description="Normalized source field with provenance, CX semantics, feature-class priors, and profiling evidence."
)
custom_object(
    "OCX_Feature_Definition__c",
    "Feature Definition",
    "Feature Definitions",
    "Feature Name",
    description="Generalized Direct Experience, Profile, or Cohort-derived feature definition."
)
custom_object(
    "OCX_Feature_Ingredient__c",
    "Feature Ingredient",
    "Feature Ingredients",
    "Feature Ingredient Number",
    auto="FI-{000000}",
    description="Field-level recipe lineage connecting a feature definition to source ingredients."
)

# -------------------------------------------------------------------
# Theme
# -------------------------------------------------------------------
theme_fields = [
    ("Theme_Key__c","Theme Key","Text",dict(length=80,externalId=True,unique=True)),
    ("Description__c","Description","LongTextArea",dict()),
    ("Sort_Order__c","Sort Order","Number",dict(precision=3,scale=0)),
    ("Active__c","Active","Checkbox",dict(default=True)),
    ("Dictionary_Version__c","Dictionary Version","Text",dict(length=40)),
]
for spec in theme_fields:
    field("OCX_CX_Theme__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Concept
# -------------------------------------------------------------------
concept_fields = [
    ("Concept_Key__c","Concept Key","Text",dict(length=120,externalId=True,unique=True)),
    ("Theme_Key__c","Theme Key","Text",dict(length=80)),
    ("Description__c","Description","LongTextArea",dict()),
    ("Signal_Patterns__c","Signal Patterns","LongTextArea",dict()),
    ("Default_Archetypes__c","Default Metric Archetypes","Text",dict(length=255)),
    ("Active__c","Active","Checkbox",dict(default=True)),
    ("Dictionary_Version__c","Dictionary Version","Text",dict(length=40)),
]
for spec in concept_fields:
    field("OCX_CX_Concept__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Feature Template
# -------------------------------------------------------------------
template_fields = [
    ("Template_Key__c","Template Key","Text",dict(length=120,externalId=True,unique=True)),
    ("Target_Feature_Class__c","Target Feature Class","Text",dict(length=80)),
    ("Feature_Type__c","Feature Type","Text",dict(length=80)),
    ("Archetype__c","Metric Archetype","Text",dict(length=80)),
    ("Primary_Theme_Key__c","Primary Theme Key","Text",dict(length=80)),
    ("Measurement_Concept_Key__c","Measurement Concept Key","Text",dict(length=120)),
    ("Description__c","Description","LongTextArea",dict()),
    ("Formula_Template__c","Formula Template","LongTextArea",dict()),
    ("Required_Ingredient_Roles__c","Required Ingredient Roles","LongTextArea",dict()),
    ("Default_Windows__c","Default Windows","Text",dict(length=120)),
    ("Default_Bucketing_Strategy__c","Default Bucketing Strategy","Text",dict(length=255)),
    ("Direction_Hypothesis__c","Direction Hypothesis","Text",dict(length=80)),
    ("Explainability_Prior__c","Explainability Prior","Number",dict(precision=5,scale=2)),
    ("Predictive_Prior__c","Predictive Prior","Number",dict(precision=5,scale=2)),
    ("Cohort_Suitability_Prior__c","Cohort Suitability Prior","Number",dict(precision=5,scale=2)),
    ("Historical_Prior_Score__c","Historical Prior Score","Number",dict(precision=5,scale=2)),
    ("Evidence_Basis__c","Evidence Basis","LongTextArea",dict()),
    ("Active__c","Active","Checkbox",dict(default=True)),
    ("Dictionary_Version__c","Dictionary Version","Text",dict(length=40)),
]
for spec in template_fields:
    field("OCX_Feature_Template__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
run_fields = [
    ("Run_Type__c","Run Type","Text",dict(length=80)),
    ("Status__c","Status","Text",dict(length=40)),
    ("Source_System__c","Source System","Text",dict(length=80)),
    ("Scope__c","Scope","LongTextArea",dict()),
    ("Started_At__c","Started At","DateTime",dict()),
    ("Completed_At__c","Completed At","DateTime",dict()),
    ("Schema_Version__c","Schema Version","Text",dict(length=40)),
    ("Dictionary_Version__c","Dictionary Version","Text",dict(length=40)),
    ("Ingredient_Count__c","Ingredient Count","Number",dict(precision=18,scale=0)),
    ("Feature_Definition_Count__c","Feature Definition Count","Number",dict(precision=18,scale=0)),
    ("Direct_Experience_Count__c","Direct Experience Count","Number",dict(precision=18,scale=0)),
    ("Profile_Feature_Count__c","Profile Feature Count","Number",dict(precision=18,scale=0)),
    ("Cohort_Derived_Count__c","Cohort Derived Count","Number",dict(precision=18,scale=0)),
    ("Notes__c","Notes","LongTextArea",dict()),
]
for spec in run_fields:
    field("OCX_Source_Intelligence_Run__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Source Ingredient
# -------------------------------------------------------------------
field(
    "OCX_Source_Ingredient__c",
    "OCX_Run__c",
    "Source Intelligence Run",
    "MasterDetail",
    referenceTo="OCX_Source_Intelligence_Run__c",
    relationshipLabel="Source Ingredients",
    relationshipName="Source_Ingredients"
)

ingredient_fields = [
    ("Ingredient_Key__c","Ingredient Key","Text",dict(length=255,externalId=True,unique=True)),
    ("Canonical_Field_Key__c","Canonical Field Key","Text",dict(length=255)),
    ("Access_Source__c","Access Source","Text",dict(length=80)),
    ("Origin_System__c","Origin System","Text",dict(length=80)),
    ("Source_Object__c","Source Object","Text",dict(length=120)),
    ("Source_Field__c","Source Field","Text",dict(length=120)),
    ("Field_Label__c","Field Label","Text",dict(length=255)),
    ("Field_Type__c","Field Type","Text",dict(length=80)),
    ("Grain__c","Grain","Text",dict(length=80)),
    ("Account_Path__c","Account Path","Text",dict(length=255)),
    ("Business_Concept__c","Business Concept","Text",dict(length=255)),
    ("Observation_Type__c","Observation Type","Text",dict(length=80)),
    ("Primary_Theme__c","Primary Theme","Text",dict(length=80)),
    ("Secondary_Themes__c","Secondary Themes","Text",dict(length=255)),
    ("Measurement_Concepts__c","Measurement Concepts","Text",dict(length=255)),
    ("Primary_Source_Role__c","Primary Source Role","Text",dict(length=120)),
    ("Source_Roles__c","Source Roles","Text",dict(length=255)),
    ("Provenance_Role__c","Provenance Role","Text",dict(length=160)),
    ("Metric_Archetypes__c","Metric Archetypes","Text",dict(length=255)),
    ("Direction_Hypothesis__c","Direction Hypothesis","Text",dict(length=80)),
    ("Windowable__c","Windowable","Checkbox",dict(default=False)),
    ("Aggregatable__c","Aggregatable","Checkbox",dict(default=False)),
    ("Cohort_Suitable__c","Cohort Suitable","Checkbox",dict(default=False)),
    ("Cohort_Dimension_Type__c","Cohort Dimension Type","Text",dict(length=80)),
    ("Bucketing_Strategy__c","Bucketing Strategy","Text",dict(length=255)),
    ("Explainability_Score__c","Explainability Score","Number",dict(precision=5,scale=2)),
    ("Predictive_Prior_Score__c","Predictive Prior Score","Number",dict(precision=5,scale=2)),
    ("Actionability_Score__c","Actionability Score","Number",dict(precision=5,scale=2)),
    ("Controllability_Score__c","Controllability Score","Number",dict(precision=5,scale=2)),
    ("Cohort_Suitability_Score__c","Cohort Suitability Score","Number",dict(precision=5,scale=2)),
    ("Stability_Prior_Score__c","Stability Prior Score","Number",dict(precision=5,scale=2)),
    ("Cardinality_Suitability_Score__c","Cardinality Suitability Score","Number",dict(precision=5,scale=2)),
    ("Peer_Group_Utility_Score__c","Peer Group Utility Score","Number",dict(precision=5,scale=2)),
    ("Leakage_Risk_Score__c","Leakage Risk Score","Number",dict(precision=5,scale=2)),
    ("Source_Confidence_Score__c","Source Confidence Score","Number",dict(precision=5,scale=2)),
    ("Coverage_Pct__c","Coverage Percent","Number",dict(precision=5,scale=2)),
    ("Populated_Count__c","Populated Count","Number",dict(precision=18,scale=0)),
    ("Distinct_Count__c","Distinct Count","Number",dict(precision=18,scale=0)),
    ("Earliest_Date__c","Earliest Business Date","Date",dict()),
    ("Latest_Date__c","Latest Business Date","Date",dict()),
    ("Sample_Values__c","Sample Values","LongTextArea",dict()),
    ("Profile_Summary__c","Profile Summary","LongTextArea",dict()),
    ("Eligibility_Status__c","Eligibility Status","Text",dict(length=80)),
    ("Exclusion_Reason__c","Exclusion Reason","LongTextArea",dict()),
    ("Classification_Basis__c","Classification Basis","LongTextArea",dict()),
    ("Reference_Evidence__c","Reference Dictionary Evidence","LongTextArea",dict()),
    ("Last_Profiled_At__c","Last Profiled At","DateTime",dict()),
]
for spec in ingredient_fields:
    field("OCX_Source_Ingredient__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Feature Definition
# -------------------------------------------------------------------
field(
    "OCX_Feature_Definition__c",
    "OCX_Run__c",
    "Source Intelligence Run",
    "MasterDetail",
    referenceTo="OCX_Source_Intelligence_Run__c",
    relationshipLabel="Feature Definitions",
    relationshipName="Feature_Definitions"
)

feature_fields = [
    ("Feature_Key__c","Feature Key","Text",dict(length=255,externalId=True,unique=True)),
    ("Feature_Class__c","Feature Class","Text",dict(length=80)),
    ("Feature_Type__c","Feature Type","Text",dict(length=80)),
    ("Stage_Key__c","Stage Key","Text",dict(length=120)),
    ("Stage_Name__c","Stage Name","Text",dict(length=255)),
    ("Driver_Key__c","Driver Key","Text",dict(length=120)),
    ("Driver_Name__c","Driver Name","Text",dict(length=255)),
    ("Primary_Theme__c","Primary Theme","Text",dict(length=80)),
    ("Secondary_Themes__c","Secondary Themes","Text",dict(length=255)),
    ("Measurement_Concept__c","Measurement Concept","Text",dict(length=120)),
    ("Metric_Archetype__c","Metric Archetype","Text",dict(length=80)),
    ("Formula_Expression__c","Formula Expression","LongTextArea",dict()),
    ("Window_Days__c","Window Days","Number",dict(precision=6,scale=0)),
    ("Grain__c","Grain","Text",dict(length=80)),
    ("Direction_Hypothesis__c","Direction Hypothesis","Text",dict(length=80)),
    ("Availability_Status__c","Availability Status","Text",dict(length=80)),
    ("Cohort_Suitable__c","Cohort Suitable","Checkbox",dict(default=False)),
    ("Cohort_Dimension_Type__c","Cohort Dimension Type","Text",dict(length=80)),
    ("Bucketing_Strategy__c","Bucketing Strategy","LongTextArea",dict()),
    ("Minimum_Cohort_Size__c","Minimum Cohort Size","Number",dict(precision=8,scale=0)),
    ("Predictive_Prior_Score__c","Predictive Prior Score","Number",dict(precision=5,scale=2)),
    ("Empirical_Predictive_Score__c","Empirical Predictive Score","Number",dict(precision=5,scale=2)),
    ("Explainability_Score__c","Explainability Score","Number",dict(precision=5,scale=2)),
    ("Actionability_Score__c","Actionability Score","Number",dict(precision=5,scale=2)),
    ("Cohort_Suitability_Score__c","Cohort Suitability Score","Number",dict(precision=5,scale=2)),
    ("Stability_Score__c","Stability Score","Number",dict(precision=5,scale=2)),
    ("Cardinality_Suitability_Score__c","Cardinality Suitability Score","Number",dict(precision=5,scale=2)),
    ("Peer_Group_Utility_Score__c","Peer Group Utility Score","Number",dict(precision=5,scale=2)),
    ("Leakage_Risk_Score__c","Leakage Risk Score","Number",dict(precision=5,scale=2)),
    ("Data_Coverage_Pct__c","Data Coverage Percent","Number",dict(precision=5,scale=2)),
    ("Correlation__c","Correlation","Number",dict(precision=8,scale=5)),
    ("Mutual_Information__c","Mutual Information","Number",dict(precision=8,scale=5)),
    ("Model_Contribution__c","Model Contribution","Number",dict(precision=8,scale=5)),
    ("Empirical_Status__c","Empirical Status","Text",dict(length=80)),
    ("Human_Status__c","Human Status","Text",dict(length=80)),
    ("Human_Notes__c","Human Notes","LongTextArea",dict()),
    ("Generated_Rationale__c","Generated Rationale","LongTextArea",dict()),
    ("Origin__c","Feature Origin","Text",dict(length=80)),
]
for spec in feature_fields:
    field("OCX_Feature_Definition__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Feature Ingredient
# -------------------------------------------------------------------
field(
    "OCX_Feature_Ingredient__c",
    "OCX_Feature_Definition__c",
    "Feature Definition",
    "MasterDetail",
    referenceTo="OCX_Feature_Definition__c",
    relationshipLabel="Feature Ingredients",
    relationshipName="Feature_Ingredients"
)
field(
    "OCX_Feature_Ingredient__c",
    "OCX_Source_Ingredient__c",
    "Source Ingredient",
    "Lookup",
    referenceTo="OCX_Source_Ingredient__c",
    relationshipLabel="Feature Uses",
    relationshipName="Feature_Uses"
)

feature_ing_fields = [
    ("Ingredient_Role__c","Ingredient Role","Text",dict(length=80)),
    ("Sequence__c","Sequence","Number",dict(precision=4,scale=0)),
    ("Transform__c","Transform","LongTextArea",dict()),
    ("Is_Time_Field__c","Is Time Field","Checkbox",dict(default=False)),
    ("Is_Grouping_Field__c","Is Grouping Field","Checkbox",dict(default=False)),
    ("Is_Filter_Field__c","Is Filter Field","Checkbox",dict(default=False)),
    ("Is_Cohort_Dimension__c","Is Cohort Dimension","Checkbox",dict(default=False)),
    ("Is_Benchmark_Feature__c","Is Benchmark Feature","Checkbox",dict(default=False)),
]
for spec in feature_ing_fields:
    field("OCX_Feature_Ingredient__c", *spec[:3], **spec[3])

# -------------------------------------------------------------------
# Seeds
# -------------------------------------------------------------------
themes = [
    ("People","PEOPLE","Human capability, expertise, qualifications, role, tenure, continuity, capacity, ownership, and engagement.",1,"true","2.0"),
    ("Process","PROCESS","How things happen: effort, friction, steps, handoffs, exceptions, escalation, rework, clarity, completion, and compliance.",2,"true","2.0"),
    ("Time","TIME","Speed, response, waiting, duration, recency, predictability, lateness, and variability.",3,"true","2.0"),
    ("Information","INFORMATION","Accuracy, clarity, completeness, consistency, availability, communication, guidance, and documentation.",4,"true","2.0"),
    ("Product / Service","PRODUCT_SERVICE","Usage, adoption, reliability, defects, quality, usability, functionality, integration, and performance.",5,"true","2.0"),
    ("Value","VALUE","Outcomes, realization, ROI, adoption benefit, commercial growth, renewal, expansion, and relationship durability.",6,"true","2.0"),
]
with (seed_root/"themes.csv").open("w",encoding="utf-8",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow(["Name","Theme_Key__c","Description__c","Sort_Order__c","Active__c","Dictionary_Version__c"])
    w.writerows(themes)

concepts = []
def add(theme,key,name,desc,signals,arch):
    concepts.append((name,key,theme,desc,signals,arch,"true","2.0"))

# People
add("PEOPLE","PEOPLE_CAPABILITY","Capability","Ability of people to perform the work successfully.","skill, capability, competency, qualification","RATE;BREADTH;STATE")
add("PEOPLE","PEOPLE_CERTIFICATION","Certification","Formal certifications or validated qualifications.","certification, certified, credential","RATE;COUNT;BREADTH")
add("PEOPLE","PEOPLE_TRAINING","Training","Training completed, required, assigned, or consumed.","training, course, learning, LMS","COUNT;RATE;RECENCY")
add("PEOPLE","PEOPLE_EXPERTISE","Expertise","Specialized knowledge or experience relevant to the customer interaction.","expertise, specialist, experience, skill","STATE;BREADTH;RATE")
add("PEOPLE","PEOPLE_ROLE","Role","Functional role of the person serving or interacting with the customer.","role, title, function","STATE;BREADTH")
add("PEOPLE","PEOPLE_AUTHORITY","Authority","Seniority or decision authority available in the relationship.","seniority, executive, manager, authority","STATE;RATE")
add("PEOPLE","PEOPLE_TENURE","Tenure","Length of time a person has been in role or relationship.","tenure, start date, years in role","DURATION;TREND")
add("PEOPLE","PEOPLE_CONTINUITY","Continuity","Stability of assigned people over time.","owner change, turnover, continuity, reassignment","TRANSITION;COUNT;RATE")
add("PEOPLE","PEOPLE_CAPACITY","Capacity","Availability or workload of people serving the customer.","capacity, workload, queue, utilization, staffing","RATIO;COUNT;RATE")
add("PEOPLE","PEOPLE_OWNERSHIP","Ownership","Who owns the customer, case, opportunity, project, or activity.","owner, assigned, assignee","STATE;TRANSITION;COUNT")
add("PEOPLE","PEOPLE_HANDOFF","People Handoffs","Transitions between people or teams serving the customer.","handoff, transfer, reassignment, owner change","TRANSITION;COUNT;RATE")
add("PEOPLE","PEOPLE_ENGAGEMENT","Engagement","Frequency and recency of human interaction with the customer.","meeting, email, call, touch, activity, engagement","FREQUENCY;RECENCY;COUNT")
add("PEOPLE","PEOPLE_RELATIONSHIP_COVERAGE","Relationship Coverage","Breadth and depth of people involved in the customer relationship.","contacts, stakeholders, executives, roles engaged","BREADTH;COUNT;RATE")

# Process
add("PROCESS","PROCESS_EFFORT","Effort","Amount of work or number of interactions required to complete something.","steps, attempts, touches, submissions, effort","COUNT;DURATION;RATE")
add("PROCESS","PROCESS_FRICTION","Friction","Obstacles, blockers, failures, or complications in a process.","friction, blocker, failure, issue, problem","COUNT;RATE;TREND")
add("PROCESS","PROCESS_STEPS","Steps","Number or sequence of steps required.","stage, step, milestone, status","COUNT;TRANSITION;DURATION")
add("PROCESS","PROCESS_HANDOFF","Process Handoffs","Transitions between teams, states, systems, or owners.","handoff, transfer, transition, reassignment","TRANSITION;COUNT;RATE")
add("PROCESS","PROCESS_EXCEPTION","Exceptions","Deviations from the normal path.","exception, override, special attention, outlier","COUNT;RATE")
add("PROCESS","PROCESS_ESCALATION","Escalation","Movement into an escalated or higher-attention path.","escalated, escalation, critical","COUNT;RATE;TREND")
add("PROCESS","PROCESS_REWORK","Rework","Repeated, reopened, or backward-moving work.","reopen, repeat, rework, retry","COUNT;RATE;TRANSITION")
add("PROCESS","PROCESS_CLARITY","Process Clarity","Evidence that steps and expectations are clear and understandable.","clarity, instruction, defined, expected, next step","STATE;RATE")
add("PROCESS","PROCESS_COMPLETION","Completion","Successful completion of a process or milestone.","closed, completed, resolved, won, complete","RATE;DURATION;STATE_SHARE")
add("PROCESS","PROCESS_COMPLIANCE","Compliance","Adherence to required process or service commitments.","SLA, violation, compliance, required","RATE;COUNT")
add("PROCESS","PROCESS_ABANDONMENT","Abandonment","Processes started but not completed.","abandon, cancel, lost, withdrawn","RATE;COUNT")
add("PROCESS","PROCESS_FIRST_TIME_RIGHT","First-Time-Right","Completion without rework, repeat contact, or correction.","first contact, first time, no reopen, no rework","RATE")

# Time
add("TIME","TIME_SPEED","Speed","How quickly work progresses.","speed, fast, elapsed, cycle","DURATION;TREND")
add("TIME","TIME_RESPONSE","Response Time","Time until a first or subsequent response.","response time, first response, reply","DURATION;THRESHOLD_RATE")
add("TIME","TIME_WAIT","Wait Time","Time the customer waits between process events.","wait, queue, pending, idle","DURATION;VARIABILITY")
add("TIME","TIME_DURATION","Duration","Elapsed time from start to completion.","duration, time to resolution, age days, ageing, cycle time","DURATION;TREND;VARIABILITY")
add("TIME","TIME_RECENCY","Recency","Time since the most recent relevant event.","last, recent, activity date, login date","RECENCY")
add("TIME","TIME_PREDICTABILITY","Predictability","Consistency of timing or ability to meet expected dates.","predictable, due date, estimated close, forecast","VARIABILITY;THRESHOLD_RATE")
add("TIME","TIME_LATENESS","Lateness","Whether actual timing exceeds commitments or due dates.","late, overdue, violation, missed date","RATE;DURATION")
add("TIME","TIME_VARIABILITY","Time Variability","Dispersion or inconsistency in elapsed times.","variance, deviation, spread, p90","VARIABILITY")

# Information
add("INFORMATION","INFO_ACCURACY","Accuracy","Correctness of information provided.","accuracy, correct, error, mismatch","RATE;COUNT")
add("INFORMATION","INFO_CLARITY","Information Clarity","Ease of understanding communications or guidance.","clarity, clear, understandable","RATE;STATE")
add("INFORMATION","INFO_COMPLETENESS","Completeness","Whether required information is present.","complete, missing, required fields","RATE;COUNT")
add("INFORMATION","INFO_CONSISTENCY","Consistency","Consistency of information across interactions or systems.","consistent, conflicting, mismatch","RATE;VARIABILITY")
add("INFORMATION","INFO_AVAILABILITY","Availability","Whether useful information is available when needed.","available, knowledge, access, article","COUNT;RATE;RECENCY")
add("INFORMATION","INFO_COMMUNICATION","Communication","Frequency, channel, and responsiveness of communications.","email, call, meeting, message, channel","FREQUENCY;RECENCY;BREADTH")
add("INFORMATION","INFO_GUIDANCE","Guidance","Help, instruction, recommendations, or direction provided.","guidance, advice, instruction, next step","COUNT;RATE")
add("INFORMATION","INFO_DOCUMENTATION","Documentation","Use and quality of documents, knowledge, or written artifacts.","documentation, article, document, guide, knowledge","COUNT;RATE;RECENCY")

# Product / Service
add("PRODUCT_SERVICE","PRODUCT_USAGE","Usage","Observed use of the product or service.","usage, active user, login, event","FREQUENCY;COUNT;RECENCY")
add("PRODUCT_SERVICE","PRODUCT_ADOPTION","Adoption","Breadth/depth of capabilities adopted.","adoption, feature usage, enabled, activated","BREADTH;RATE;TREND")
add("PRODUCT_SERVICE","PRODUCT_RELIABILITY","Reliability","Stability and successful operation.","reliability, outage, failure, incident","RATE;COUNT;TREND")
add("PRODUCT_SERVICE","PRODUCT_DEFECTS","Defects","Product defects or bugs experienced.","bug, defect, error","COUNT;RATE;TREND")
add("PRODUCT_SERVICE","PRODUCT_QUALITY","Quality","Overall service/product quality signals.","quality, severity, satisfaction, root cause","RATE;STATE_SHARE")
add("PRODUCT_SERVICE","PRODUCT_USABILITY","Usability","Ease of using the product or service.","usability, ease, clicks, attempts","COUNT;RATE;DURATION")
add("PRODUCT_SERVICE","PRODUCT_FUNCTIONALITY","Functionality","Capabilities/features available and used.","feature, function, capability, product","BREADTH;COUNT;RATE")
add("PRODUCT_SERVICE","PRODUCT_INTEGRATION","Integration","Quality and health of integrations.","integration, connector, API, sync","RATE;COUNT;TREND")
add("PRODUCT_SERVICE","PRODUCT_PERFORMANCE","Performance","Operational product/service performance.","performance, latency, throughput, response","DURATION;RATE;TREND")

# Value
add("VALUE","VALUE_OUTCOMES","Outcomes","Business or customer outcomes achieved.","outcome, result, goal, success","RATE;MONETARY;TREND")
add("VALUE","VALUE_REALIZATION","Value Realization","Evidence that expected value is being achieved.","realization, benefit, achieved, success plan","RATE;TREND")
add("VALUE","VALUE_ROI","ROI","Return relative to cost or investment.","ROI, return, savings, cost","RATIO;MONETARY")
add("VALUE","VALUE_ADOPTION_BENEFIT","Adoption Benefit","Benefit associated with actual adoption/use.","adoption, benefit, usage value","RATIO;TREND")
add("VALUE","VALUE_COMMERCIAL_GROWTH","Commercial Growth","Growth in commercial relationship.","ARR, ACV, revenue, growth","MONETARY;TREND;RATIO")
add("VALUE","VALUE_RENEWAL","Renewal","Renewal exposure, likelihood, and completion.","renewal, renewal due, probability","MONETARY;RATE;RECENCY")
add("VALUE","VALUE_EXPANSION","Expansion","Expansion or upsell potential/realization.","expansion, upsell, cross-sell","MONETARY;RATE;TREND")
add("VALUE","VALUE_RELATIONSHIP_DURABILITY","Relationship Durability","Length and persistence of the customer relationship.","customer since, tenure, retention","DURATION;RATE")

with (seed_root/"concepts.csv").open("w",encoding="utf-8",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow([
        "Name","Concept_Key__c","Theme_Key__c","Description__c",
        "Signal_Patterns__c","Default_Archetypes__c","Active__c",
        "Dictionary_Version__c"
    ])
    w.writerows(concepts)

templates = [
# Direct Experience
("Windowed Event Count","COUNT_WINDOW","DIRECT_EXPERIENCE","KPI","COUNT","ANY","",
 "Count events for an Account in a trailing window.",
 "COUNT({event} WHERE {account_join} AND {event_date} >= TODAY()-{window_days})",
 "event;account_join;event_date","30;90;365","","context dependent",0.95,0.70,0.10,0.50,"Generic CX measurement prior","true","2.0"),
("Windowed Event Rate","RATE_WINDOW","DIRECT_EXPERIENCE","KPI","RATE","ANY","",
 "Rate of events meeting a condition.",
 "COUNT({event} WHERE {condition} AND {window}) / COUNT({eligible_event} WHERE {window})",
 "event;condition;eligible_event;account_join;event_date","30;90;365","","context dependent",0.95,0.80,0.10,0.60,"Generic CX measurement prior","true","2.0"),
("Duration Summary","DURATION_SUMMARY","DIRECT_EXPERIENCE","KPI","DURATION","TIME","TIME_DURATION",
 "Summary of elapsed-time values; include robust/tail summaries.",
 "AGG({duration_measure} WHERE {window}); AGG in MEDIAN,P75,P90,MEAN",
 "duration_measure;account_join;business_date","30;90;365","","lower often better",1.00,0.90,0.10,0.70,"Time/process metrics frequently explain experience","true","2.0"),
("Recency","RECENCY","DIRECT_EXPERIENCE","KPI","RECENCY","TIME","TIME_RECENCY",
 "Days since most recent relevant event.",
 "TODAY()-MAX({event_date})",
 "event_date;account_join","30;90;365","","context dependent",0.95,0.80,0.10,0.60,"Generic CX measurement prior","true","2.0"),
("Interaction Frequency","FREQUENCY","DIRECT_EXPERIENCE","KPI","FREQUENCY","PEOPLE","PEOPLE_ENGAGEMENT",
 "Interaction frequency over a trailing window.",
 "COUNT({interaction})/{window_days}",
 "interaction;interaction_date;account_join","30;90","","context dependent",0.95,0.80,0.10,0.60,"Useful for engagement/relationship coverage","true","2.0"),
("Trend Delta","TREND_DELTA","DIRECT_EXPERIENCE","KPI","TREND","ANY","",
 "Change between recent and prior windows.",
 "METRIC({recent_window})-METRIC({prior_window})",
 "measure;business_date;account_join","30;90;365","","context dependent",0.90,0.80,0.10,0.50,"Generic CX measurement prior","true","2.0"),
("Variability","VARIABILITY","DIRECT_EXPERIENCE","KPI","VARIABILITY","TIME","TIME_VARIABILITY",
 "Dispersion/consistency of a measure.",
 "STDDEV({measure}) or P90({measure})-MEDIAN({measure})",
 "measure;business_date;account_join","90;365","","lower often better",0.90,0.80,0.10,0.60,"Useful for predictability","true","2.0"),
("Threshold Violation Rate","THRESHOLD_RATE","DIRECT_EXPERIENCE","KPI","THRESHOLD_RATE","PROCESS","PROCESS_COMPLIANCE",
 "Share exceeding a threshold or violating a commitment.",
 "COUNT({measure}>{threshold})/COUNT({measure})",
 "measure;threshold;account_join;business_date","30;90;365","","lower better",1.00,0.90,0.10,0.80,"Strong explanatory/actionable pattern","true","2.0"),
("State Share","STATE_SHARE","DIRECT_EXPERIENCE","KPI","STATE_SHARE","PROCESS","PROCESS_COMPLETION",
 "Share of records in a business state.",
 "COUNT({record} WHERE {state}={target_state})/COUNT({record})",
 "record;state;account_join;business_date","30;90;365","","context dependent",0.95,0.75,0.10,0.60,"Generic process prior","true","2.0"),
("Ratio","RATIO","DIRECT_EXPERIENCE","KPI","RATIO","ANY","",
 "Ratio between related quantities.",
 "SUM({numerator})/SUM({denominator})",
 "numerator;denominator;account_join","90;365","","context dependent",0.90,0.75,0.10,0.60,"Generic CX measurement prior","true","2.0"),
("Breadth","BREADTH","DIRECT_EXPERIENCE","KPI","BREADTH","ANY","",
 "Distinct products, people, roles, channels, or capabilities represented.",
 "COUNT_DISTINCT({dimension})",
 "dimension;account_join;business_date","90;365","","context dependent",0.90,0.75,0.20,0.60,"Useful for coverage/adoption","true","2.0"),
("Concentration","CONCENTRATION","DIRECT_EXPERIENCE","KPI","CONCENTRATION","ANY","",
 "Degree to which activity/value is concentrated in one category.",
 "MAX(COUNT_BY({dimension}))/COUNT({record})",
 "dimension;record;account_join;business_date","90;365","","context dependent",0.80,0.65,0.10,0.40,"Generic CX measurement prior","true","2.0"),
("Transition Rate","TRANSITION_RATE","DIRECT_EXPERIENCE","KPI","TRANSITION","PROCESS","PROCESS_HANDOFF",
 "Frequency of state/owner/team transitions.",
 "COUNT({transition})/COUNT({eligible_record})",
 "transition;eligible_record;account_join;business_date","90;365","","lower often better; context dependent",0.95,0.80,0.10,0.70,"Useful for handoffs/rework/continuity","true","2.0"),
("First-Time-Right Rate","FIRST_TIME_RIGHT","DIRECT_EXPERIENCE","KPI","RATE","PROCESS","PROCESS_FIRST_TIME_RIGHT",
 "Share completed without reopen/rework/repeat contact.",
 "COUNT({completed_without_rework})/COUNT({completed})",
 "completed;rework_indicator;account_join;business_date","30;90;365","","higher better",1.00,0.90,0.10,0.90,"Strong process/explanation prior","true","2.0"),

# Profile
("Profile Passthrough","PROFILE_PASSTHROUGH","PROFILE","ATTRIBUTE","STATE","","",
 "Stable Account attribute used directly as a profile feature.",
 "{account_field}",
 "account_field","","DIRECT_CATEGORY_WITH_MIN_COHORT_SIZE","contextual",0.90,0.60,0.80,0.50,"Profile/cohort prior","true","2.0"),
("Profile Numeric Band","PROFILE_NUMERIC_BAND","PROFILE","BAND","BAND","","",
 "Numeric/currency Account attribute converted to a cohort-friendly band.",
 "BUCKET({account_measure})",
 "account_measure","","BUSINESS_BANDS_OR_QUANTILES","contextual",0.90,0.60,0.90,0.60,"Profile/cohort prior","true","2.0"),
("Customer Tenure","PROFILE_TENURE","PROFILE","DERIVED_ATTRIBUTE","DURATION","VALUE","VALUE_RELATIONSHIP_DURABILITY",
 "Customer tenure derived from a customer-since/start date.",
 "DATEDIFF(TODAY(),{customer_since_date})",
 "customer_since_date","","TENURE_YEARS","contextual",0.95,0.65,0.80,0.60,"Profile/cohort prior","true","2.0"),
("Customer Tenure Band","PROFILE_TENURE_BAND","PROFILE","BAND","BAND","VALUE","VALUE_RELATIONSHIP_DURABILITY",
 "Cohort-friendly band derived from customer tenure.",
 "BUCKET(DATEDIFF(TODAY(),{customer_since_date}))",
 "customer_since_date","","TENURE_BANDS","contextual",0.95,0.65,0.95,0.70,"Profile/cohort prior","true","2.0"),
("Categorical Cohort Dimension","PROFILE_CATEGORY","PROFILE","COHORT_DIMENSION","STATE","","",
 "Categorical Account attribute used as a peer-cohort dimension when cardinality is appropriate.",
 "{account_category}",
 "account_category","","DIRECT_CATEGORY_WITH_MIN_COHORT_SIZE","contextual",0.95,0.55,0.95,0.60,"Profile/cohort prior","true","2.0"),

# Cohort-derived
("Cohort Delta","COHORT_DELTA","COHORT_DERIVED","BENCHMARK","DELTA","","",
 "Difference between an Account Direct Experience Feature and its cohort benchmark.",
 "{account_feature}-{cohort_benchmark}",
 "account_feature;cohort_benchmark","","","context dependent",1.00,0.85,0.95,0.70,"Peer-comparison prior","true","2.0"),
("Cohort Ratio","COHORT_RATIO","COHORT_DERIVED","BENCHMARK","RATIO","","",
 "Ratio of an Account Direct Experience Feature to its cohort benchmark.",
 "{account_feature}/{cohort_benchmark}",
 "account_feature;cohort_benchmark","","","context dependent",1.00,0.85,0.95,0.70,"Peer-comparison prior","true","2.0"),
("Cohort Percentile","COHORT_PERCENTILE","COHORT_DERIVED","BENCHMARK","PERCENTILE","","",
 "Peer percentile for an Account Direct Experience Feature.",
 "PERCENTILE_RANK({account_feature} WITHIN {cohort})",
 "account_feature;cohort_dimensions","","","context dependent",1.00,0.90,0.95,0.80,"Peer-comparison prior","true","2.0"),
("Cohort Z-Score","COHORT_ZSCORE","COHORT_DERIVED","BENCHMARK","ZSCORE","","",
 "Standardized distance from the peer cohort when statistically appropriate.",
 "({account_feature}-{cohort_mean})/{cohort_stddev}",
 "account_feature;cohort_mean;cohort_stddev","","","context dependent",0.80,0.80,0.75,0.50,"Peer-comparison prior","true","2.0"),
]

with (seed_root/"feature_templates.csv").open("w",encoding="utf-8",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow([
        "Name","Template_Key__c","Target_Feature_Class__c","Feature_Type__c",
        "Archetype__c","Primary_Theme_Key__c","Measurement_Concept_Key__c",
        "Description__c","Formula_Template__c","Required_Ingredient_Roles__c",
        "Default_Windows__c","Default_Bucketing_Strategy__c",
        "Direction_Hypothesis__c","Explainability_Prior__c",
        "Predictive_Prior__c","Cohort_Suitability_Prior__c",
        "Historical_Prior_Score__c","Evidence_Basis__c","Active__c",
        "Dictionary_Version__c"
    ])
    w.writerows(templates)

# -------------------------------------------------------------------
# Permission set
# -------------------------------------------------------------------
object_apis = [
    "OCX_CX_Theme__c",
    "OCX_CX_Concept__c",
    "OCX_Feature_Template__c",
    "OCX_Source_Intelligence_Run__c",
    "OCX_Source_Ingredient__c",
    "OCX_Feature_Definition__c",
    "OCX_Feature_Ingredient__c",
]

master_detail_fields = {
    "OCX_Source_Ingredient__c.OCX_Run__c",
    "OCX_Feature_Definition__c.OCX_Run__c",
    "OCX_Feature_Ingredient__c.OCX_Feature_Definition__c",
}

field_map = {}
for obj in object_apis:
    fld_dir = objects_root / obj / "fields"
    field_map[obj] = sorted(
        p.name.replace(".field-meta.xml","")
        for p in fld_dir.glob("*.field-meta.xml")
    )

lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<PermissionSet xmlns="{NS}">',
    '    <label>OCX CX Source Intelligence</label>',
]
for obj in object_apis:
    for fld in field_map[obj]:
        if f"{obj}.{fld}" in master_detail_fields:
            continue
        lines += [
            '    <fieldPermissions>',
            '        <editable>true</editable>',
            f'        <field>{obj}.{fld}</field>',
            '        <readable>true</readable>',
            '    </fieldPermissions>',
        ]

for obj in object_apis:
    lines += [
        '    <objectPermissions>',
        '        <allowCreate>true</allowCreate>',
        '        <allowDelete>true</allowDelete>',
        '        <allowEdit>true</allowEdit>',
        '        <allowRead>true</allowRead>',
        '        <modifyAllRecords>false</modifyAllRecords>',
        f'        <object>{obj}</object>',
        '        <viewAllRecords>false</viewAllRecords>',
        '    </objectPermissions>',
    ]

lines.append('</PermissionSet>')
write(
    permsets_root/"OCX_CX_Source_Intelligence.permissionset-meta.xml",
    "\n".join(lines)+"\n"
)

# -------------------------------------------------------------------
# Manifest
# -------------------------------------------------------------------
manifest = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<Package xmlns="{NS}">',
    '    <types>',
]
for obj in object_apis:
    manifest.append(f'        <members>{obj}</members>')
manifest += [
    '        <name>CustomObject</name>',
    '    </types>',
    '    <types>',
    '        <members>OCX_CX_Source_Intelligence</members>',
    '        <name>PermissionSet</name>',
    '    </types>',
    '    <version>67.0</version>',
    '</Package>',
]
write(
    manifest_root/"ocx-cx-source-intelligence-foundation.xml",
    "\n".join(manifest)+"\n"
)

print(f"Generated {len(object_apis)} custom objects.")
print(f"Seed themes: {len(themes)}")
print(f"Seed concepts: {len(concepts)}")
print(f"Seed feature templates: {len(templates)}")
PY

  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  TARGET="$(cd "$(dirname "$VERSIONED_SCRIPT")" && pwd)/$(basename "$VERSIONED_SCRIPT")"
  if [ "$SELF" != "$TARGET" ]; then
    cp "$0" "$VERSIONED_SCRIPT"
  fi
  chmod +x "$VERSIONED_SCRIPT"

  cat > "$DOC" <<'EOF'
# CX Source Intelligence

Salesforce-resident semantic/source-intelligence layer for Customer AI.

The foundation explicitly supports three feature classes:

- DIRECT_EXPERIENCE
- PROFILE
- COHORT_DERIVED

Generated records are grouped under `OCX_Source_Intelligence_Run__c`, which is
the purge/rebuild boundary. Stable theme/concept/template records are seeded
independently and are not purged with a discovery run.

## Modes

    scripts/source-intelligence/01_create_foundation.sh audit
    scripts/source-intelligence/01_create_foundation.sh prepare
    scripts/source-intelligence/01_create_foundation.sh schema-dry-run
    scripts/source-intelligence/01_create_foundation.sh schema-apply
    scripts/source-intelligence/01_create_foundation.sh seed
    scripts/source-intelligence/01_create_foundation.sh verify
    scripts/source-intelligence/01_create_foundation.sh commit

Always run `schema-dry-run` before `schema-apply`.
EOF

  echo "Validating generated XML..."

  python3 - "$BASE" "$MANIFEST" "$PERMSET" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

base = Path(sys.argv[1])
manifest = Path(sys.argv[2])
permset = Path(sys.argv[3])

roots = [
    "OCX_CX_Theme__c",
    "OCX_CX_Concept__c",
    "OCX_Feature_Template__c",
    "OCX_Source_Intelligence_Run__c",
    "OCX_Source_Ingredient__c",
    "OCX_Feature_Definition__c",
    "OCX_Feature_Ingredient__c",
]

targets = [manifest, permset]
for root in roots:
    targets.extend((base/"objects"/root).rglob("*.xml"))

for p in targets:
    ET.parse(p)

print(f"XML OK: {len(targets)} files")
PY

  bash -n "$VERSIONED_SCRIPT"

  git diff --check -- \
    "$SCRIPT_DIR" \
    "$PERMSET" \
    "$MANIFEST" \
    "$BASE/objects/OCX_CX_Theme__c" \
    "$BASE/objects/OCX_CX_Concept__c" \
    "$BASE/objects/OCX_Feature_Template__c" \
    "$BASE/objects/OCX_Source_Intelligence_Run__c" \
    "$BASE/objects/OCX_Source_Ingredient__c" \
    "$BASE/objects/OCX_Feature_Definition__c" \
    "$BASE/objects/OCX_Feature_Ingredient__c"

  echo
  echo "Prepared local foundation."
  echo "No Salesforce records or metadata were modified."
  echo
  echo "Next:"
  echo "  $0 schema-dry-run"
}

schema_dry_run() {
  sf project deploy start \
    --target-org "$ORG" \
    --manifest "$MANIFEST" \
    --dry-run \
    --test-level NoTestRun \
    --wait 30
}

schema_apply() {
  sf project deploy start \
    --target-org "$ORG" \
    --manifest "$MANIFEST" \
    --test-level NoTestRun \
    --wait 30

  sf org assign permset \
    --target-org "$ORG" \
    --name OCX_CX_Source_Intelligence
}

seed() {
  for f in \
    "$SEED_DIR/themes.csv" \
    "$SEED_DIR/concepts.csv" \
    "$SEED_DIR/feature_templates.csv"
  do
    if [ ! -f "$f" ]; then
      echo "ERROR: Missing seed file: $f"
      exit 1
    fi
  done

  echo "Upserting CX themes..."
  sf data upsert bulk \
    --target-org "$ORG" \
    --sobject OCX_CX_Theme__c \
    --file "$SEED_DIR/themes.csv" \
    --external-id Theme_Key__c \
    --line-ending LF \
    --wait 10

  echo "Upserting CX concepts..."
  sf data upsert bulk \
    --target-org "$ORG" \
    --sobject OCX_CX_Concept__c \
    --file "$SEED_DIR/concepts.csv" \
    --external-id Concept_Key__c \
    --line-ending LF \
    --wait 10

  echo "Upserting feature templates..."
  sf data upsert bulk \
    --target-org "$ORG" \
    --sobject OCX_Feature_Template__c \
    --file "$SEED_DIR/feature_templates.csv" \
    --external-id Template_Key__c \
    --line-ending LF \
    --wait 10

  "$0" verify
}

verify() {
  echo
  echo "Reference counts:"
  sf data query \
    --target-org "$ORG" \
    --query "SELECT COUNT() FROM OCX_CX_Theme__c WHERE Active__c = true"

  sf data query \
    --target-org "$ORG" \
    --query "SELECT COUNT() FROM OCX_CX_Concept__c WHERE Active__c = true"

  sf data query \
    --target-org "$ORG" \
    --query "SELECT COUNT() FROM OCX_Feature_Template__c WHERE Active__c = true"

  echo
  echo "Theme inventory:"
  sf data query \
    --target-org "$ORG" \
    --query "SELECT Theme_Key__c,Name,Sort_Order__c FROM OCX_CX_Theme__c WHERE Active__c = true ORDER BY Sort_Order__c" \
    --result-format human

  echo
  echo "Feature-template inventory by class:"
  sf data query \
    --target-org "$ORG" \
    --query "SELECT Target_Feature_Class__c,COUNT(Id) qty FROM OCX_Feature_Template__c WHERE Active__c = true GROUP BY Target_Feature_Class__c ORDER BY Target_Feature_Class__c" \
    --result-format human

  echo
  echo "Object availability:"
  for o in "${OBJECTS[@]}"; do
    sf sobject describe --target-org "$ORG" --sobject "$o" --json >/dev/null
    echo "  OK: $o"
  done

  echo
  echo "VERIFY COMPLETE"
}

commit_changes() {
  paths=(
    "$SCRIPT_DIR"
    "$PERMSET"
    "$MANIFEST"
    "$BASE/objects/OCX_CX_Theme__c"
    "$BASE/objects/OCX_CX_Concept__c"
    "$BASE/objects/OCX_Feature_Template__c"
    "$BASE/objects/OCX_Source_Intelligence_Run__c"
    "$BASE/objects/OCX_Source_Ingredient__c"
    "$BASE/objects/OCX_Feature_Definition__c"
    "$BASE/objects/OCX_Feature_Ingredient__c"
  )

  git add -- "${paths[@]}"

  UNRELATED="force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml"
  if git diff --cached --name-only | grep -Fxq "$UNRELATED"; then
    git restore --staged "$UNRELATED"
    echo "ERROR: Unrelated Portfolio Explorer change was staged."
    exit 1
  fi

  echo "STAGED FILES"
  git diff --cached --name-status
  echo
  echo "STAGED STAT"
  git diff --cached --stat
  git diff --cached --check

  git commit -m "Add CX source intelligence foundation"

  echo
  echo "Commit:"
  git rev-parse --short HEAD
  echo
  echo "Remaining worktree changes:"
  git status --short
  echo
  echo "No push was performed."
}

case "$MODE" in
  audit) audit ;;
  prepare) prepare ;;
  schema-dry-run) schema_dry_run ;;
  schema-apply) schema_apply ;;
  seed) seed ;;
  verify) verify ;;
  commit) commit_changes ;;
  *)
    echo "Usage:"
    echo "  $0 audit"
    echo "  $0 prepare"
    echo "  $0 schema-dry-run"
    echo "  $0 schema-apply"
    echo "  $0 seed"
    echo "  $0 verify"
    echo "  $0 commit"
    exit 1
    ;;
esac
