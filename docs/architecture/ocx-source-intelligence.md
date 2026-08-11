# OCX Source Intelligence Architecture

## Purpose

OCX Customer AI should not reason directly over a raw Salesforce field dump. The raw schema is too large, too ambiguous, and in this demo physically mixes legitimate upstream source data with downstream OCX-derived data.

Source Intelligence is the interpretation layer between connected systems and Customer AI.

Its job is to answer:

1. What source data exists?
2. What does each source ingredient mean?
3. Is it legitimate as a predictor, a profile attribute, linkage, outcome, or excluded downstream data?
4. Is the data populated and usable enough to consider?
5. What feature/KPI concepts can be built from it?
6. For a specific Stage + Driver, what Direct Experience candidates are plausible?
7. What source ingredients and formulas support each candidate?
8. What useful concepts are missing or still require mapping?

## Guided Customer AI flow

The intended product flow is:

`Journey -> Stages -> Drivers`

Once a Driver is accepted:

`Driver approved -> Source Intelligence retrieval/discovery -> ranked candidate Direct Experience KPIs + Profile/Cohort attributes -> human tuning -> OCX-approved feature definitions`

The system should generate a strong first draft, not force the user to build every feature definition manually.

## Six CX themes

Driver and feature reasoning uses six experience themes:

- **People** — human roles and measures: engagement/assignment, certifications, training, roles, tenure, team involvement.
- **Process** — how things happen: effort, friction, clarity of steps, workflows, handoffs, escalations, rework.
- **Time** — speed, responsiveness, duration, predictability, ageing, time to milestone.
- **Information** — clarity, accuracy, helpfulness, completeness of communications, documentation, guidance.
- **Product/Service** — features, usability, reliability, integration quality, service quality.
- **Value** — outcomes, ROI, realized benefit, long-term relationship value.

These themes are semantic lenses, not hard filters. A Driver may draw from more than one theme.

## Salesforce-side semantic model

The Salesforce foundation currently uses seven custom objects:

- `OCX_CX_Theme__c`
- `OCX_CX_Concept__c`
- `OCX_Feature_Template__c`
- `OCX_Source_Intelligence_Run__c`
- `OCX_Source_Ingredient__c`
- `OCX_Feature_Definition__c`
- `OCX_Feature_Ingredient__c`

Permission set:

- `OCX_CX_Source_Intelligence`

Versioned manifest:

- `manifest/ocx-cx-source-intelligence-foundation.xml`

The semantic foundation is intentionally source-aware and provenance-aware. The raw Salesforce schema is not itself the contract presented to Customer AI.

## Three feature classes

### 1. Direct Experience

Operational/customer-experience measurements at an Account and time-window grain. Examples include:

- support ticket volume
- response time
- resolution time
- escalation rate
- SLA violations
- severity mix
- engagement activity
- implementation duration
- product usage/adoption measures when such a source exists

These are the main Stage/Driver explanatory candidates.

### 2. Profile

Relatively stable Account attributes used to characterize a customer and form peer groups. Examples include:

- geography
- industry
- segment
- product family
- support tier
- tenure
- ACV/ARR bands
- company size
- renewal timing

Profile attributes are not interchangeable with Direct Experience KPIs.

### 3. Cohort Derived

Benchmarks calculated by OCX from Profile cohort membership plus Direct Experience/outcome measures, for example:

- customer's average resolution time vs peer average
- customer's escalation rate vs peer average
- customer outcome vs peer outcome

Cohort-derived features are later OCX analytical features; they are not source-system fields.

## Ownership boundary

### Salesforce owns

- Salesforce source catalog and source metadata.
- Provenance/eligibility classification.
- Salesforce Profile-feature source catalog.
- Historical recipe evidence.
- Candidate-generation semantics and source evidence for Salesforce.
- Source lineage.
- Optional persisted proposal snapshots.

### OCX owns

- The accepted/rejected/modified feature definition after human tuning.
- Final OCX feature-definition identity and version.
- Final formula/window/name if edited.
- Cross-source orchestration.
- Materialized feature values.
- Cohort construction and benchmarks.
- Empirical signal validation.
- Predictive/analytical models.

The existing Salesforce `OCX_Feature_Definition__c` Stage/Driver proposal records are therefore **source-side proposal snapshots**, not the final OCX definition authority.

## Adapter architecture

Salesforce is the first adapter, not the permanent center of the universe.

Later sources may include ServiceNow, Gainsight, Gong/Staircase-style conversation systems, Pendo/product analytics, PSA, training systems, or other enterprise sources.

The Customer AI/analytics layers should speak one vendor-neutral Source Intelligence contract. A source-specific adapter maps each connected system into that contract.

This is why OCX should not issue raw SOQL against the Source Intelligence object model or expose Salesforce object/field structure directly throughout the application.

## Read-only REST v1 boundary

The next implementation phase is a Salesforce Apex REST facade over the already persisted intelligence.

Proposed routes:

- `GET /services/apexrest/ocx/source-intelligence/v1/profile`
- `POST /services/apexrest/ocx/source-intelligence/v1/candidates`
- `GET /services/apexrest/ocx/source-intelligence/v1/definitions/{candidateId}`

The first phase retrieves persisted intelligence only. It does not yet port the full V7 discovery engine behind Apex.

### `profile`

Returns the Salesforce Profile/Cohort attribute catalog with enough metadata for OCX to understand future cohort suitability.

### `candidates`

Accepts free-text Stage + Driver. If a matching persisted proposal snapshot exists, return it. A read request must not create a proposal run.

Until live discovery is implemented, a never-before-generated Stage/Driver should return an explicit `NOT_GENERATED` result rather than guessing or silently matching another Driver.

### `definition`

Returns expanded detail for a single source candidate: formula, source ingredients, lineage, rationale/evidence, statuses, and source identifiers.

## Retrieval versus generation

Keep these concepts separate:

- **Retrieval**: read previously generated Source Intelligence/proposal data. Must be idempotent and read-only.
- **Discovery/generation**: run the semantic ranking engine for a new Stage + Driver. This may be computationally heavier and is a later REST phase.
- **Persistence**: optionally save a source-side proposal snapshot. It must never happen merely because a read endpoint was called.

## Why historical recipes exist

The old historical feature dictionary is evidence, not current truth. Its role is to provide priors such as:

- a formula pattern has been useful before
- a concept historically aligned with similar outcomes
- certain source ingredients were historically combined

Historical Driver labels are context only. Do not treat old labels as current mappings, and do not allow historical priors to override current source availability or provenance rules.

## Why Source Intelligence is not the feature matrix

Salesforce Source Intelligence stores definitions/evidence. OCX later computes analytical values at the required Account/time-window grain.

A future analytical feature matrix may include:

- Direct Experience values
- Profile attributes
- Cohort membership
- Cohort-derived benchmarks
- Stage/Driver outcomes

That computation belongs in OCX/Gen Analytics, not in the read-only Source Intelligence REST phase.
