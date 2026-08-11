# Feature Architecture and Lifecycle

## Why this exists

Customer AI must distinguish three different questions:

1. What *could* matter semantically to a Driver?
2. What can actually be built from the customer's connected data?
3. What has later been empirically shown to carry useful signal?

These are different stages. Do not collapse them into one score or one synchronous workflow.

## Feature classes

### DIRECT_EXPERIENCE

Operational measurements, usually Account + time-window based.

Examples:

- number of support tickets
- average resolution time
- escalation rate
- SLA violation rate
- case severity mix
- engagement frequency
- implementation duration
- product usage/adoption depth when the required source is connected

### PROFILE

Account attributes used for descriptive context and peer/cohort construction.

Examples:

- Region
- Country
- State
- Industry
- Customer Segment
- Account Type
- Support Tier
- Source ACV
- Company Revenue
- Employees
- Customer Tenure
- Product Family
- Product Breadth
- Renewal Timing

### COHORT_DERIVED

OCX-calculated peer benchmarks derived from Profile membership plus operational/outcome measures.

Examples:

- peer average resolution time
- difference from peer escalation rate
- peer outcome average
- percentile within peer cohort

## Availability semantics

Salesforce storage currently uses these concepts:

- `AVAILABLE`
- `DERIVABLE`
- `MAPPING_REQUIRED`
- `TARGET_NOT_YET_AVAILABLE`

The vendor-neutral OCX v1 contract normalizes the last value to:

- `TARGET_NOT_AVAILABLE`

Meaning:

### AVAILABLE

The desired measure/attribute is directly available with adequate source semantics.

### DERIVABLE

The desired feature is not a single field but can be calculated from currently mapped source ingredients.

### MAPPING_REQUIRED

The concept is plausible, but a required ingredient, formula placeholder, mapping, or semantic resolution is incomplete.

### TARGET_NOT_AVAILABLE

The concept is useful for the Driver but the connected source universe does not currently contain what is required.

Do not fabricate data or substitute a semantically different field to eliminate a gap.

## Source proposal status versus OCX decision status

Salesforce currently stores source-side proposal state such as:

- `Human_Status__c = PROPOSED`
- `Empirical_Status__c = NOT_TESTED`

Once OCX owns the human-tuning lifecycle, do not interpret Salesforce `Human_Status__c` as the authoritative user decision.

Use separate concepts:

### Source proposal state

Examples:

- PROPOSED
- source-side persisted candidate snapshot

### OCX decision state

Future examples:

- PROPOSED
- APPROVED
- REJECTED
- MODIFIED

OCX owns this lifecycle and its version history.

## Candidate identity versus final feature identity

Keep source candidates and OCX definitions separate.

Recommended conceptual identities:

- `sourceCandidateId`
- `sourceCandidateFingerprint`
- `ocxFeatureDefinitionId`
- `ocxFeatureDefinitionVersion`

A source candidate may be approved unchanged, rejected, or used as the provenance ancestor of a modified OCX definition.

Salesforce record IDs can be carried in diagnostics/provenance, but should not be the primary vendor-neutral identity.

## Candidate fingerprint

The exact algorithm may be finalized during REST implementation, but it should be deterministic and based on stable semantic content rather than a random record ID. Candidate components may include:

- source system/catalog version
- normalized Stage
- normalized Driver
- measurement concept/name
- normalized formula semantics
- source ingredient identity set
- grain/window semantics

If changing one of these materially changes the meaning of the feature, it should generally change the fingerprint.

## Stage/Driver discovery behavior

The frozen V7 discovery logic currently:

- uses Source Intelligence plus historical recipe priors
- scores CX-theme fit
- scores Driver intent/causal fit
- scores Stage-to-object fit
- uses historical/data priors
- promotes concept-family diversity
- suppresses identifiers/contact-coordinate pseudo-KPIs
- applies object-aware semantics
- downranks Profile/context fields unless the Driver explicitly asks for them
- marks historical formulas with unresolved placeholders as `MAPPING_REQUIRED`
- emits explicit `TARGET_NOT_YET_AVAILABLE` gaps
- leaves every proposed candidate `Empirical_Status = NOT_TESTED`

The discovery result should be a curated candidate set, roughly the best 10-20 plausible options, not every vaguely related field.

## Current verified regression examples

### Support -> Effectiveness of Resolution

The frozen discovery produces a resolution-focused set including concepts such as:

- resolution/closure rate
- escalation/SLA measures
- resolution/open-case ageing time
- severity
- ticket volume
- first-response violation
- root cause/bug measures
- call duration where relevant

It includes an explicit gap for reopen/repeat-resolution behavior when the required source signal does not exist.

Identifier/contact-coordinate candidates were deliberately suppressed.

### Renewal -> Confidence in Value

The set is intentionally different and includes concepts such as:

- forecast/renewal opportunity signals
- engagement
- opportunity age/timing
- overdue activities
- support burden as a derived component family

Known target gaps include:

- product usage/adoption depth
- realized customer outcomes/ROI

This demonstrates that discovery is Driver-specific rather than a generic field-ranking pass.

## Chat-time versus later empirical validation

Full signal testing is deliberately **not** in the live guided-chat path.

During chat, use cheap data-fitness checks such as:

- field exists
- mapped/eligible
- coverage/population
- variance
- cardinality
- date availability
- formula executability

Then persist/return candidates as:

- source proposal state: PROPOSED
- empirical state: NOT_TESTED

Later, asynchronously, OCX can evaluate actual signal.

## Later type-aware empirical validation

Do not implement this in the current REST phase, but preserve the architecture for it.

Possible tests depend on predictor/outcome type:

- numeric -> numeric/ordinal: Spearman/Pearson, regression, Kruskal-Wallis/ordinal regression, mutual information
- categorical -> numeric: ANOVA/Welch ANOVA/Kruskal-Wallis plus effect sizes such as eta/omega squared
- categorical -> categorical: Chi-square plus Cramer's V
- binary -> numeric: t-test/Mann-Whitney/point-biserial
- binary outcome: logistic modeling/AUC
- nonlinear relationships: mutual information/model-based lift

Prioritize:

- effect size
- out-of-sample predictive lift
- temporal stability
- cohort stability
- redundancy
- leakage prevention

Do not rank future features by p-value alone.

## Profile/Cohort principle

Keep useful Profile features with reasonable coverage even when cardinality is high. A high-cardinality attribute may still be valuable for descriptive slicing or future cohort logic. Do not discard it merely because it is not suitable for naive one-hot modeling.

Cohort construction belongs later on the OCX side and should use minimum-size and suitability rules to prevent unstable peer groups.
