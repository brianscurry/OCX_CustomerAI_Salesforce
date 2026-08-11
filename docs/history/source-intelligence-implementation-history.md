# Source Intelligence Implementation History

This document records why the current repository/data state looks the way it does. It is intentionally detailed so a new coding agent does not repeat already-solved mistakes or reinterpret reconstruction artifacts as product architecture.

## 1. Demo-source reconstruction

The Salesforce demo was reverse-built from existing OCX demo data, which itself originated from multiple real source extracts/reports/SFTP feeds, then was transformed, anonymized, and varied for the Bongo demo.

A critical realization was that the scratch Salesforce org contained both:

- legitimate upstream-like source data; and
- downstream OCX analytics/model outputs that had been loaded for demo purposes.

Therefore the project stopped treating "field exists in Salesforce" as equivalent to "field is valid Salesforce source evidence."

### Source-data upgrade

Raw upstream-style fields were added/deployed so the demo could represent realistic source ingredients.

Examples include:

#### Account

- `Customer_Since_Date__c`
- `Customer_Segment__c`
- `Region__c`
- `Source_ACV__c` as the source-profile ACV boundary

#### Opportunity

- `ARR__c`
- `Annual_Renewal__c`
- `Territory__c`

#### Case

- `Time_to_Resolution_Days__c`
- `Ageing_of_Open_Cases_Days__c`
- `Support_Level__c`
- `Root_Cause__c`
- `SLA_Violation__c`
- `Product_Line__c`
- `Support_Category__c`
- plus additional source-tracking fields added during reconstruction

Permission set:

- `OCX_Demo_Source_Data`

Important historical counts during reconstruction included:

- Opportunities: 7,618
- Cases: 2,996 total
- Cases linked to Account/source evidence: 2,994
- 2 Cases lacked Account/source matching and were intentionally not given borrowed evidence
- 1,514 Cases could be enriched from same-account source rows without duplicating/borrowing
- 1,480 unmatched Cases remained untouched

The authoritative current Bongo Account population is later fixed at 7,755; do not use an earlier transient count to recreate removed Accounts.

An earlier source-reconstruction commit was:

- `6d02861 Add Bongo opportunity and support source reconstruction`

Verify the commit exists before relying on the hash.

## 2. Source Intelligence foundation

Seven custom objects were created:

- `OCX_CX_Theme__c`
- `OCX_CX_Concept__c`
- `OCX_Feature_Template__c`
- `OCX_Source_Intelligence_Run__c`
- `OCX_Source_Ingredient__c`
- `OCX_Feature_Definition__c`
- `OCX_Feature_Ingredient__c`

Permission set:

- `OCX_CX_Source_Intelligence`

Manifest:

- `manifest/ocx-cx-source-intelligence-foundation.xml`

Versioned source-intelligence seeds/scripts include themes, concepts, profile features, profile-feature links, source ingredients, feature templates, and historical recipe templates.

### Immutable source catalog run

Known run ID:

- `a0HAs0000040k2DMAQ`

Known completed counts:

- Source Ingredients: 304
- Feature Definitions: 21
- Profile Feature Count: 21
- Direct Experience Count: 0
- Cohort Derived Count: 0

Known role inventory:

- DIRECT_EXPERIENCE_INPUT / ELIGIBLE: 116
- IDENTIFIER / REVIEW: 12
- IGNORE / EXCLUDE: 44
- LINKAGE / ELIGIBLE: 7
- OCX_DERIVED / EXCLUDE: 35
- OUTCOME / OUTCOME_ONLY: 2
- PROFILE_INPUT / ELIGIBLE: 88

Known Profile feature inventory:

- ATTRIBUTE / AVAILABLE: 14
- BAND / DERIVABLE: 4
- DERIVED_ATTRIBUTE / DERIVABLE: 3

`Account.Source_ACV__c` is the upstream Profile ACV source. `Account.OCX_ACV__c` is downstream/excluded.

Downstream OCX fields remain visible in the catalog for completeness but are excluded as source predictors.

Historical recipe-prior recovery was about 87.86%. Old Driver labels are context, not current mappings.

A known foundation commit was:

- `e745663 feat: add Customer AI source intelligence foundation`

Verify the commit exists before relying on the hash.

## 3. Frozen Stage/Driver discovery V7

Several heuristic versions were iterated before freezing V7 in:

- `scripts/source-intelligence/03_stage_driver_kpi_discovery_preflight.sh`

Known commit:

- `3c9b61a feat: add Stage Driver KPI discovery preflight`

### V7 semantics

V7:

- consumes Source Intelligence and historical priors
- scores CX-theme fit
- scores Driver intent/causal fit
- scores Stage-to-object fit
- uses historical/data priors
- promotes concept-family diversity
- suppresses identifier/contact-coordinate pseudo-KPIs
- applies object-aware semantics
- downranks context/Profile slices unless requested by the Driver
- marks unresolved historical-formula placeholders `MAPPING_REQUIRED`
- emits explicit target gaps
- leaves empirical status `NOT_TESTED`

### Regression: Support / Effectiveness of Resolution

The ranked set became resolution-specific and removed common false positives. Representative concepts included:

- severity/major-ticket measures
- average open-case ageing
- support ticket volume
- first-time-right historical concept as mapping-required when unresolved
- source first-response violation rate
- source bug/root-cause measures
- Case closure/resolution rate
- average call duration where available
- timing/age measures when contextually justified

Explicit target gap:

- reopen/repeat-resolution rate

Contact-mobile/coordinate pseudo-KPIs were removed. Task/Opportunity closure semantics were prevented from polluting Case resolution semantics.

### Regression: Renewal / Confidence in Value

The result intentionally differed from Support and included:

- forecast/renewal opportunity concepts
- engagement
- opportunity age/timing
- overdue tasks/activities
- support burden derived from multiple support component families

Known target gaps:

- product usage/adoption depth
- realized customer outcomes/ROI

The heuristics were considered good enough to freeze rather than continue tuning before the next product layers.

## 4. Product sequencing decision: signal testing later

A key architecture decision was made not to run full statistical signal testing while the user is in the guided ontology conversation.

Current intended flow:

`Source Intelligence -> Stage/Driver discovery -> proposal persistence -> retrieval/approval -> cohort-derived layer -> guided chat -> Gen Analytics -> later empirical validation`

Chat-time discovery may use cheap data fitness, but persisted candidates remain:

- proposal state: PROPOSED
- empirical state: NOT_TESTED

Type-aware empirical validation is intentionally asynchronous/later.

## 5. Support proposal preparation

A read-only proposal-preparation phase was built for:

- Stage: Support
- Driver: Effectiveness of Resolution
- top 15 ranked candidates plus one explicit target gap

Historical proposal directory on the original workstation before the repository move:

`/Users/briancurry/Downloads/ocx-migration/ocx-salesforce/.ocx/stage-driver-proposal-support-effectiveness-of-resolution-20260810_202757`

Current repo-relative equivalent:

`.ocx/stage-driver-proposal-support-effectiveness-of-resolution-20260810_202757`

The working preparation implementation dynamically resolved the optional explainability field to:

- `Explainability_Score__c`

Prepared package counts:

- Feature Definitions: 16
- Ingredient links: 19
- unresolved ingredient references: 0
- availability: 14 DERIVABLE; 1 MAPPING_REQUIRED; 1 TARGET_NOT_YET_AVAILABLE
- empirical state: NOT_TESTED
- lineage: 19 links across 13 unique source ingredients

The preparation itself made no Salesforce writes.

## 6. Proposal persistence failure and recovery

This history matters because it established the project's resume-safe write discipline.

### First persistence attempt

An initial script failed because `Scope__c` could not be filtered in a SOQL query. A second version worked around that by retrieving recent run records and comparing Scope locally.

### Partial apply failure

The first apply created a new proposal run, then used `sf data create record --values` for Feature Definitions. Complex formula/rationale text broke the CLI `key=value` parser.

Interrupted proposal run:

- `a0HAs0000040tGjMAI`

The run was left Running.

A recovery preflight later proved that despite the apparent failure:

- 2 Feature Definitions had already been created
- 0 ingredient links had been created

Therefore blindly rerunning the create path would have been wrong.

### Explainability mapping bug caught before apply

An intermediate recovery script looked for the wrong logical map key and would have omitted `Explainability_Score__c` on the 14 remaining Feature Definitions. Preflight caught this before writes.

### Final recovery approach

The canonical fix switched complex records to CSV + Bulk API and was resume-safe:

- reuse interrupted run; never create another run
- enrich the 2 partial Feature Definitions if needed
- insert only the 14 missing Feature Definitions
- refresh live IDs
- insert only missing ingredient links
- verify exact counts/statuses
- mark the existing run Complete only after verification

The final live result was:

- proposal run `a0HAs0000040tGjMAI` = Complete
- 16 Feature Definitions
- 16 Direct Experience definitions
- 19 ingredient links
- 0 Profile definitions on this proposal run
- 0 Cohort Derived definitions
- 14 DERIVABLE
- 1 MAPPING_REQUIRED
- 1 TARGET_NOT_YET_AVAILABLE
- all source-side PROPOSED
- all NOT_TESTED
- source catalog run `a0HAs0000040k2DMAQ` unchanged

The successful persistence scripts were canonicalized as:

- `scripts/source-intelligence/04_prepare_stage_driver_feature_proposals.sh`
- `scripts/source-intelligence/05_persist_stage_driver_feature_proposals.sh`

Known commit:

- `5ad2832 feat: persist Stage Driver feature proposals`

At the time of that commit, `main` and `origin/main` were aligned and unrelated working-tree files remained unstaged.

## 7. Current handoff boundary

The Salesforce side has now crossed from "schema discovery" into a persistent source-intelligence system:

`Salesforce source universe -> classified Source Ingredients -> Profile catalog -> Stage/Driver discovery -> persisted candidate proposal -> explicit source lineage`

The next task is not another data-seeding phase. It is the read-only API boundary that lets OCX consume this intelligence without knowing the Salesforce storage schema.

### Immediate next phase

Build and prove:

- `profile` REST retrieval
- persisted `candidates` REST retrieval for Stage + Driver
- `definition/{candidateId}` expanded lineage retrieval
- Apex tests
- live response fixtures from `OCXDemo`
- contract comparison/finalization

Do not port live arbitrary-Driver V7 discovery until this retrieval contract is proven.

## 8. Planned later phases

After REST v1 retrieval is proven:

1. Hand real schema + fixtures to the OCX implementation agent.
2. Build OCX read-only adapter/preflight.
3. Wire retrieval into guided chat only after contract validation.
4. Build OCX-owned feature-definition approval/version lifecycle.
5. Optionally build asynchronous Salesforce reconciliation/write-back endpoint.
6. Build Cohort Derived features/benchmarks in OCX.
7. Integrate approved features into Gen Analytics retrieval/computation.
8. Port/implement live arbitrary-Driver discovery behind the same candidates contract.
9. Add later asynchronous empirical signal validation.
10. Run end-to-end regression/reproducibility and harden multi-source adapter behavior.
