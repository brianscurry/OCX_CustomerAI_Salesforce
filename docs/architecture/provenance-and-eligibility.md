# Provenance and Predictor Eligibility

## Core rule

This demo Salesforce org was reconstructed from multiple original sources and also contains downstream OCX outputs. Therefore:

> A field being physically present in Salesforce does not mean Salesforce was its original upstream system, and it does not mean the field is legitimate source evidence for prediction.

Source Intelligence classification is authoritative for eligibility.

## Role taxonomy

The architecture distinguishes at least:

- `PROFILE_INPUT`
- `DIRECT_EXPERIENCE_INPUT`
- `OUTCOME`
- `OCX_DERIVED`
- `MODEL_OUTPUT`
- `IDENTIFIER`
- `LINKAGE`
- `IGNORE`

Operational policy concepts used in the seeded catalog include:

- eligible predictor inputs
- review-only identifiers
- outcome-only variables
- excluded downstream/ignored variables

## Last known source-role inventory

The immutable Source Intelligence catalog run `a0HAs0000040k2DMAQ` had:

- DIRECT_EXPERIENCE_INPUT / ELIGIBLE: 116
- PROFILE_INPUT / ELIGIBLE: 88
- LINKAGE / ELIGIBLE: 7
- IDENTIFIER / REVIEW: 12
- OUTCOME / OUTCOME_ONLY: 2
- OCX_DERIVED / EXCLUDE: 35
- IGNORE / EXCLUDE: 44

Total Source Ingredients: 304.

Verify these counts before using them as live assertions.

## Known original-source provenance

The demo was reconstructed from source files/data that originally came from more than Salesforce.

Known provenance conventions:

- Account source population -> Salesforce-origin data.
- Opportunity source population -> Salesforce-origin data.
- Support source population -> originally ServiceNow; for this demo it is represented as Salesforce Service Cloud/Case data.
- Professional-services/project data -> not Salesforce-origin.
- Training data -> not Salesforce-origin.
- Product usage data -> not Salesforce-origin.
- Conversations DB -> separate upstream, pre-model source; not Salesforce even if selected metadata or reconstruction records are also represented in the demo org.
- NPS/Journey SAT/Driver SAT, propensity, and other model/analytics outputs -> downstream OCX; never source predictors.

## Conversation/activity boundary

The intended architecture is:

- Salesforce API discovers lightweight Account/activity metadata.
- Full conversation payload remains in the Conversations DB or a future conversation-system connector.
- External interaction IDs provide the canonical join spine.

Task fields:

- `Task.OCX_Activity_ID__c` — legitimate linkage identifier.
- `Task.OCX_Channel__c` — legitimate source/context field.
- `Task.OCX_Driver__c` — do not use as source evidence; likely OCX-derived classification.
- `Task.OCX_Sentiment__c` — do not use as source evidence; likely OCX-derived classification.

A reconstructed `OCX_Customer_Interaction__c` object in the demo does not prove that full transcripts are natively stored in Salesforce. Do not design the production architecture around that artifact.

## ACV separation

Keep pre-analytics source ACV physically and semantically separate from downstream OCX ACV.

Authoritative upstream profile ingredient:

- `Account.Source_ACV__c`

Downstream/excluded field:

- `Account.OCX_ACV__c`

Future/reproducible loaders should write source-profile ACV to `Source_ACV__c`, never `OCX_ACV__c`.

Existing historical live data does not need to be rewritten solely because values happen to match; the important rule is future semantic separation and predictor eligibility.

## Leakage prevention

Never use downstream outcomes/model outputs as predictors merely because they correlate strongly.

Examples of disallowed predictor categories include:

- OCX propensity/model scores
- downstream Driver classifications
- downstream satisfaction targets being predicted
- analytics outputs derived from the same target period

The discovery layer should be able to see excluded fields for catalog completeness, but it must not promote them as candidate predictor ingredients.

## Identifiers and linkage

Identifiers are not automatically useless; they may be important for joins and reconstruction. But they are not candidate KPIs simply because they are populated.

Examples:

- Account IDs
- Case IDs
- external activity IDs
- contact coordinates
- email/phone fields

The frozen discovery logic intentionally suppresses identifier/contact-coordinate pseudo-KPIs.

## Object semantics matter

A common field name does not imply a common KPI meaning.

For example:

- `Case.IsClosed` can support a Support resolution/closure concept.
- `Task.IsClosed` means activity completion, not support resolution.
- `Opportunity.IsClosed` means sales opportunity closure, not support resolution.

Source Intelligence and discovery must preserve object/domain meaning rather than applying naive name matching.

## Unmapped/missing data

When the ideal concept is absent, return a gap:

- `MAPPING_REQUIRED` when the concept may be derivable after resolving a missing mapping/placeholder.
- `TARGET_NOT_AVAILABLE` in the vendor-neutral contract when the source universe currently lacks the required signal.

Do not substitute an unrelated field just to avoid returning a gap.
