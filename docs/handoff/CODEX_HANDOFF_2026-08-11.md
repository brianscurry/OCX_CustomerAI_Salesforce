# Comprehensive Codex Handoff — OCX Salesforce Integration

Date: 2026-08-11

## Why this document exists

This project has been developed through a long architecture + CLI implementation conversation. The purpose of this handoff is to move the primary development thread into Codex without losing the reasoning, constraints, known-good state, or lessons behind the current repository.

The most important expectation is:

> Do not treat this as a greenfield Salesforce integration and do not "improve" the architecture by erasing boundaries that were deliberately established.

Codex should become the ongoing pair engineer: discuss architecture with the user, inspect the real repo/org, implement, test, deploy, diagnose routine failures, and continue the conversation. Durable architectural truth should increasingly live in the repository rather than only in chat history.

---

# 1. Product objective

OCX Customer AI guides a user through an experience ontology:

`Journey -> Stages -> Drivers`

Drivers represent what customers experience at a given lifecycle Stage. Once a Driver is accepted, Customer AI should help determine how that Driver can be measured from the customer's actual connected data.

The desired product flow is:

`Journey -> Stages -> Drivers -> inspect connected systems -> discover source ingredients -> propose KPIs/features -> human tuning -> approved OCX feature definitions -> later computation/cohorts/analytics`

The problem with the old path is that the chat could profile a raw Salesforce schema and ask an LLM to invent measures from field names. That allowed semantically bad proxies, such as choosing a sales probability field as evidence for customer satisfaction with a sales team.

Source Intelligence was built so Customer AI reasons over an interpreted, provenance-aware source universe instead of guessing from raw schema.

---

# 2. Semantic model: six CX themes

Driver/feature discovery uses six lenses:

1. **People** — human roles and measures: engagement/assignment, certifications, training, roles, tenure, team involvement.
2. **Process** — effort, friction, clarity of steps/workflows, handoffs, escalations, rework.
3. **Time** — speed, responsiveness, duration, predictability, ageing, time to milestone.
4. **Information** — clarity, accuracy, helpfulness, completeness of communications/docs/guidance.
5. **Product/Service** — features, usability, reliability, integration/service quality.
6. **Value** — outcomes, ROI, realized benefit, long-term relationship value.

These themes help explain what kinds of evidence may matter for a Driver. They are not a replacement for source semantics or Stage/domain context.

---

# 3. Feature architecture

There are three distinct feature classes.

## DIRECT_EXPERIENCE

Operational measurements at Account/time-window grain, such as:

- ticket volume
- response/resolution time
- escalation rate
- SLA violation rate
- severity mix
- activity/engagement
- implementation duration
- product usage/adoption when that source is connected

These are the main explanatory candidates for a Stage + Driver.

## PROFILE

Customer attributes used for context and peer/cohort construction, such as:

- geography
- industry
- segment
- support tier
- Source ACV
- company size
- tenure
- product family/breadth
- renewal timing

Do not treat Profile attributes as ordinary Direct Experience KPIs.

## COHORT_DERIVED

OCX-computed peer benchmarks based on Profile membership plus Direct Experience/outcome measures. These do not yet exist as a completed implementation and belong on the OCX side later.

---

# 4. Salesforce-versus-OCX ownership boundary

This boundary was explicitly chosen after coordination with the OCX coding agent.

## Salesforce owns

- Source Intelligence for Salesforce.
- Source/schema interpretation.
- Source Ingredient provenance and eligibility.
- Profile-feature source catalog.
- Historical recipe priors as evidence.
- Stage/Driver candidate-generation evidence.
- Formula/source lineage.
- Optional persisted source-side proposal snapshots.

## OCX owns

- accepted/rejected/modified feature definitions after human tuning;
- final OCX feature-definition ID/version;
- final edited name/formula/window;
- cross-source orchestration;
- feature computation across accounts/time windows;
- cohort construction and cohort-derived benchmarks;
- later empirical signal testing;
- predictive/analytical model consumption.

Therefore the 16 persisted `OCX_Feature_Definition__c` records for Support / Effectiveness of Resolution are not the final product-owned feature dictionary. They are source-side proposal/evidence snapshots.

Do not reinterpret Salesforce `Human_Status__c` as the future authoritative OCX user decision.

---

# 5. Why provenance is critical

The scratch org was reverse-built from an OCX demo that combined multiple original systems and downstream OCX outputs.

Physical Salesforce presence does not establish upstream provenance.

Known source provenance:

- Account data: Salesforce-origin.
- Opportunity data: Salesforce-origin.
- Support data: originally ServiceNow, represented as Salesforce Service Cloud/Case data for this demo.
- Professional services/project data: not Salesforce-origin.
- Training data: not Salesforce-origin.
- Product usage data: not Salesforce-origin.
- Conversations DB: separate upstream pre-model source, analogous to a future Gong/Staircase/Gainsight-style source.
- satisfaction targets, propensity, and other OCX/model outputs: downstream and excluded from source predictors.

The Source Intelligence role taxonomy includes:

- PROFILE_INPUT
- DIRECT_EXPERIENCE_INPUT
- OUTCOME
- OCX_DERIVED
- MODEL_OUTPUT
- IDENTIFIER
- LINKAGE
- IGNORE

Never use OUTCOME/OCX_DERIVED/MODEL_OUTPUT as source predictors.

---

# 6. Conversation/activity source boundary

The production intent is not to pretend Salesforce owns every conversation transcript.

Architecture:

- Salesforce exposes lightweight activity/account metadata.
- Full conversation payload stays in the Conversations DB or a future dedicated connector.
- external source interaction ID is the canonical join spine.

Task semantics:

- `OCX_Activity_ID__c` is legitimate linkage.
- `OCX_Channel__c` is legitimate source/context.
- `OCX_Driver__c` should not be used as source evidence; likely downstream classification.
- `OCX_Sentiment__c` should not be used as source evidence; likely downstream classification.

A reconstructed interaction object in the demo is not proof that production transcripts live in Salesforce.

---

# 7. ACV boundary

The source-profile ACV and downstream OCX ACV are deliberately separated even if current demo values happen to match.

Use:

- `Account.Source_ACV__c` — authoritative upstream source/profile ingredient.

Do not use as source evidence:

- `Account.OCX_ACV__c` — downstream OCX field.

Future loaders must write source ACV to `Source_ACV__c`.

---

# 8. Authoritative Bongo demo conventions

The authoritative demo customer/brand is **Bongo**.

The authoritative Account population is **7,755 Accounts**. It was intentionally reduced from a larger prototype/source population. Rows for removed Accounts should be ignored, not recreated.

Use the exact demo identities and product mappings in `docs/demo/bongo-data-conventions.md`. Do not invent replacements.

---

# 9. Source Intelligence foundation built in Salesforce

Seven custom objects exist:

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

Known foundation commit:

- `e745663 feat: add Customer AI source intelligence foundation`

Verify rather than blindly trusting the hash.

---

# 10. Immutable source catalog

Known completed Source Intelligence run:

- `a0HAs0000040k2DMAQ`

Known counts:

- Source Ingredients: 304
- Feature Definitions: 21
- Profile Features: 21
- Direct Experience: 0
- Cohort Derived: 0

Known role inventory:

- DIRECT_EXPERIENCE_INPUT / ELIGIBLE: 116
- PROFILE_INPUT / ELIGIBLE: 88
- LINKAGE / ELIGIBLE: 7
- IDENTIFIER / REVIEW: 12
- OUTCOME / OUTCOME_ONLY: 2
- OCX_DERIVED / EXCLUDE: 35
- IGNORE / EXCLUDE: 44

Known Profile inventory:

- ATTRIBUTE / AVAILABLE: 14
- BAND / DERIVABLE: 4
- DERIVED_ATTRIBUTE / DERIVABLE: 3

The source catalog is intended to be immutable evidence for that run. Do not mutate it as a side effect of Stage/Driver retrieval.

---

# 11. Profile/Cohort catalog

The Profile catalog contains 21 Feature Definitions. Canonical concepts include:

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

The product decision was to keep useful attributes with roughly 75-80%+ coverage even if some have high cardinality. High cardinality does not automatically make an attribute useless for descriptive/cohort work.

Later OCX cohort logic should apply its own suitability/minimum-size rules.

---

# 12. Historical recipe priors

An older historical feature dictionary was converted into **172 historical semantic recipe priors**.

Important semantics:

- historical recipes are evidence/prior, not truth;
- old Driver names are context, not current mappings;
- unresolved placeholders remain unresolved and should yield `MAPPING_REQUIRED` rather than an invented formula;
- the historical recipe recovery/resolution rate was about 87.86%.

The system uses this history to improve ranking and formula awareness, not to override current Source Intelligence.

---

# 13. Frozen V7 Stage/Driver discovery

Canonical script:

- `scripts/source-intelligence/03_stage_driver_kpi_discovery_preflight.sh`

Known commit:

- `3c9b61a feat: add Stage Driver KPI discovery preflight`

V7 is considered frozen for now. Do not restart heuristic tuning unless a later regression demonstrates a concrete problem.

V7 behavior:

- uses Source Intelligence + historical priors;
- ranks Direct Experience ingredients/formulas for Stage + Driver;
- scores theme fit;
- scores Driver intent/causal fit;
- scores Stage/object fit;
- incorporates historical/data priors;
- enforces concept-family diversity;
- suppresses identifier/contact-coordinate pseudo-KPIs;
- uses object-aware semantics;
- downranks Profile/context slices unless explicitly relevant;
- marks unresolved formula placeholders MAPPING_REQUIRED;
- emits explicit target gaps;
- keeps everything `Empirical_Status = NOT_TESTED`.

## Support regression

For `Support -> Effectiveness of Resolution`, the final set focuses on resolution/escalation/SLA/time/severity/root-cause/support-burden concepts. It intentionally removed contact-coordinate junk and prevented Task/Opportunity "closed" fields from being treated as Case resolution.

Known explicit gap:

- reopen/repeat-resolution rate

## Renewal regression

For `Renewal -> Confidence in Value`, the final set shifts toward forecast/renewal opportunity, engagement, opportunity age/timing, overdue activities, and support burden.

Known explicit target gaps:

- product usage/adoption depth
- realized customer outcomes/ROI

The different results are evidence that discovery is Stage/Driver-aware, not a generic ranker.

---

# 14. Signal testing decision

Full empirical testing is intentionally deferred.

The guided chat should remain fast. It can use cheap data-fitness checks, but should not wait for a full statistics/modeling job every time the user defines a Driver.

Current candidate state should remain:

- source proposal: PROPOSED
- empirical: NOT_TESTED

Later OCX validation should be type-aware and consider effect size, predictive lift, stability, redundancy, and leakage—not just Pearson correlation or p-values.

Do not add full signal testing to the next REST phase.

---

# 15. Persisted Support proposal

The first persisted real proposal is:

- Stage: `Support`
- Driver: `Effectiveness of Resolution`
- proposal run: `a0HAs0000040tGjMAI`

Known final state:

- run status: Complete
- Feature Definitions: 16
- Direct Experience: 16
- Ingredient links: 19
- unique source ingredients involved: 13
- Profile definitions on this run: 0
- Cohort Derived on this run: 0
- availability: 14 DERIVABLE, 1 MAPPING_REQUIRED, 1 TARGET_NOT_YET_AVAILABLE
- all source proposal state: PROPOSED
- all empirical state: NOT_TESTED

Canonical scripts:

- `scripts/source-intelligence/04_prepare_stage_driver_feature_proposals.sh`
- `scripts/source-intelligence/05_persist_stage_driver_feature_proposals.sh`

Known commit:

- `5ad2832 feat: persist Stage Driver feature proposals`

At last verification, `main` and `origin/main` were aligned.

---

# 16. Persistence recovery history — do not repeat these mistakes

The proposal-persistence phase had several failures that taught important workflow rules.

## Failure 1: filterability assumption

An initial implementation attempted to filter `Scope__c` in SOQL and learned that the field could not be filtered in that query context. The corrected approach retrieved candidate runs and compared Scope locally.

Lesson: inspect actual Salesforce field/query behavior rather than assuming every field is filterable.

## Failure 2: complex `--values` parsing

A proposal run was created, then Feature Definition creation used `sf data create record --values`. Complex formula/rationale content broke the CLI key=value parser.

Critically, the apparent failure did **not** mean zero writes happened. Later preflight proved two Feature Definitions already existed.

Lesson: after a write error, query live state before retrying.

## Failure 3 caught before write: explainability mapping

An intermediate recovery script looked for the wrong logical field-map key and would have omitted/mismatched `Explainability_Score__c` on remaining features.

Preflight caught the inconsistency before apply.

Lesson: preflight must verify resolved live field names and existing partial-record consistency.

## Final recovery

The successful recovery:

- reused the interrupted run;
- never created another proposal run;
- updated the two partial records if needed;
- used CSV/Bulk API for complex records;
- inserted only missing Feature Definitions;
- refreshed IDs;
- inserted only missing lineage links;
- verified exact counts/statuses;
- completed the run only after verification.

This established a project-wide rule: **partial writes must be resumed, not blindly replayed.**

---

# 17. Git/repository discipline

Canonical local repo:

`/Users/briancurry/ocx-salesforce`

Known GitHub repo:

`brianscurry/OCX_CustomerAI_Salesforce`

Known org aliases:

- `OCXDemo`
- `OCXPersistent`

Known API version:

- `67.0`

Historically unrelated/local work has appeared in the working tree, including:

- `force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml`
- Bulk-result CSVs
- `backups/`
- `build/`

Never use broad staging/cleanup just to make the tree pretty. Stage exact files only.

Do not claim commit/push success without terminal output.

---

# 18. Coordination with OCX/Lovable side

The OCX coding agent proposed consuming Source Intelligence through a vendor-neutral backend contract rather than continuing to invent KPIs from raw Salesforce schema.

The agreed architectural boundary is:

> Salesforce proposes and explains source-side candidates. OCX decides, versions, computes, and maintains the final feature definitions.

The user explicitly chose **not** to have the OCX side implement speculatively in parallel while the Salesforce REST payload is still hypothetical.

Therefore the sequence is:

1. Build Salesforce read-only REST endpoints.
2. Call them against the real org.
3. Produce real JSON fixtures.
4. Adjust/freeze v1 contract based on reality.
5. Commit/push Salesforce REST phase.
6. Hand OCX/Lovable the real schema, requests, responses, auth behavior.
7. Only then build/wire the OCX read-only adapter and later guided-chat changes.

---

# 19. Draft vendor-neutral REST contract decisions

The draft contract lives at:

- `docs/contracts/source-intelligence.v1.schema.json`

It is not considered frozen until validated against real Apex responses.

## Proposed routes

- `GET /services/apexrest/ocx/source-intelligence/v1/profile`
- `POST /services/apexrest/ocx/source-intelligence/v1/candidates`
- `GET /services/apexrest/ocx/source-intelligence/v1/definitions/{candidateId}`

The exact internal Apex class structure should follow existing repo patterns.

## `candidates` request

Primary interface: free-text Stage + Driver.

A Salesforce proposal-run ID is not required.

Recommended request shape:

```json
{
  "stage": {"name": "Support", "description": null},
  "driver": {"name": "Effectiveness of Resolution", "description": null},
  "limit": 15
}
```

## Read-only semantics

A read request must never create a proposal run.

If an exact persisted snapshot exists, return it.

Until live V7 discovery is ported behind the service, an unseen Driver returns explicit `NOT_GENERATED` with no candidates and no write.

Never silently nearest-neighbor match a Driver.

## Availability normalization

Salesforce storage -> vendor-neutral v1:

- AVAILABLE -> AVAILABLE
- DERIVABLE -> DERIVABLE
- MAPPING_REQUIRED -> MAPPING_REQUIRED
- TARGET_NOT_YET_AVAILABLE -> TARGET_NOT_AVAILABLE

## Grain/window

Executable candidates (`AVAILABLE`/`DERIVABLE`) must have a resolved grain and time window.

Incomplete/gap candidates may have null grain/window when accompanied by `incompleteReasons`.

Do not invent defaults.

## Source status versus OCX decision

Expose Salesforce proposal status as `sourceProposalStatus`.

Expose current empirical status as `empiricalStatus`.

Future OCX approval status is separate.

## Identity

Keep separate:

- `sourceCandidateId`
- `sourceCandidateFingerprint`
- optional Salesforce record ID for diagnostics
- future `ocxFeatureDefinitionId`
- future `ocxFeatureDefinitionVersion`

Salesforce record ID must not become the cross-source/final feature identity.

The candidate fingerprint should be deterministic and semantically stable. If the exact algorithm requires a cross-system decision, discuss it before freezing the contract.

---

# 20. Immediate next task for Codex

The next task is deliberately narrow:

> Build and prove the read-only Salesforce Source Intelligence v1 REST service for `profile`, persisted `candidates`, and `definition`, including Apex tests and real `OCXDemo` JSON fixtures. Do not implement live V7 discovery yet.

## Expected engineering steps

Codex should:

1. Read all durable docs.
2. Inspect the actual repository and existing Apex REST/service patterns.
3. Verify Git state/recent commits.
4. Verify live Source Intelligence runs/counts read-only.
5. Inspect actual custom-object fields rather than guessing DTO mappings.
6. Propose the minimal class/metadata design.
7. Resolve candidate external identity/fingerprint design explicitly.
8. Implement DTO/service/controller tests according to repo style.
9. Add permission/manifest metadata only where necessary.
10. Run targeted Apex tests.
11. Validate/dry-run deployment if practical.
12. Deploy to `OCXDemo` only after the implementation is internally green and the user authorizes execution if needed by the chosen Codex approval mode.
13. Call all three endpoints against the actual org.
14. Save real fixtures under `docs/contracts/examples/`.
15. Validate fixtures against `source-intelligence.v1.schema.json`.
16. Prove `candidates` is read-only by comparing relevant proposal-run counts/state before and after calls.
17. Show exact diff/status and test/deploy output.
18. Do not commit until reviewed/approved.

## Required tests/behavior

At minimum cover:

- `profile` success.
- persisted Support/Effectiveness candidates success.
- expected 16 candidate records returned or equivalent contract representation.
- availability normalization.
- expanded definition success with lineage.
- invalid candidate ID -> controlled not-found behavior.
- unseen Driver -> NOT_GENERATED, zero candidates in Phase 1.
- no proposal-run creation during candidates retrieval.
- excluded/downstream source ingredients are not surfaced as predictor lineage.
- response shape validates against the draft contract.

## Reference fixture

Use:

- Stage: Support
- Driver: Effectiveness of Resolution
- known proposal run: `a0HAs0000040tGjMAI`

Do not assume the ID is valid without verifying it in the org.

---

# 21. Explicitly out of scope for the first Codex implementation

Do not do any of the following in REST Phase 1:

- port V7 discovery into Apex;
- create new Stage/Driver proposal runs from read calls;
- change the seven-object Source Intelligence data model;
- build OCX approval storage;
- write OCX-approved definitions back to Salesforce;
- compute account/time-window feature values;
- build cohorts;
- run empirical signal testing;
- refactor unrelated Salesforce code;
- clean unrelated working-tree files;
- redesign Bongo source/product mappings;
- treat downstream OCX fields as predictor inputs.

---

# 22. What comes after REST retrieval

Once real payloads are proven and the contract is frozen:

## OCX Phase 1

Build a vendor-neutral `source-intelligence` backend adapter using the real endpoints and fixtures.

Operations conceptually include:

- profile
- candidates
- definition

## OCX Phase 2

Wire retrieval into guided ontology chat:

- candidates per accepted Driver
- Profile catalog once per connected source/customer
- present Available/Derivable/Mapping Required/Target Not Available
- explain lineage/reasoning
- retire raw-schema KPI invention for Salesforce intelligence-enabled orgs

## OCX Phase 3

Create OCX-owned feature-definition and version storage; support approve/reject/rename/formula/window edits and manual additions.

Any Salesforce write-back should be asynchronous/optional through a dedicated reconciliation API rather than direct raw writes from OCX.

## Later analytics

- compute Direct Experience feature values
- construct cohorts from Profile attributes
- compute cohort benchmarks
- feed approved features into Gen Analytics
- perform later type-aware empirical validation

## Later Salesforce discovery

Port/implement live arbitrary Stage + Driver discovery behind the existing `candidates` contract so OCX does not need a contract change when generation becomes dynamic.

---

# 23. How Codex should behave in this project

The user wants Codex to replace the previous architecture-plus-script workflow without losing context.

That means Codex should do both:

- **discussion/reasoning mode** when the user is deciding architecture or asking what/why; and
- **implementation mode** when the user says to build it.

Do not interpret every architectural question as permission to modify code.

When implementing, Codex should be more autonomous than the old screenshot relay:

- inspect failures itself;
- read relevant code/logs;
- fix routine problems;
- rerun narrow tests;
- return to the user when an error implies an architectural/data-model/product decision.

The user prefers exactness over hand-waving. Report:

- files changed
- commands run
- tests and counts
- deployment result
- live verification
- remaining risks/questions

Do not say "done" when the evidence only proves local compilation.

---

# 24. Final mental model

The system being built is:

`Customer systems`

-> `Source Intelligence: what data exists, what it means, what is eligible, what can be built`

-> `Customer AI Journey/Stage/Driver reasoning`

-> `source-side candidate feature proposals + gaps + lineage`

-> `human tuning`

-> `OCX-owned approved feature definitions`

-> `OCX feature computation + Profile/Cohort analytics`

-> `later empirical signal validation`

-> `Gen Analytics / predictive models / explanations`

Salesforce is the first Source Intelligence adapter. It should be excellent at explaining Salesforce data without becoming the permanent owner of OCX's final feature definitions or analytical feature matrix.
