# AGENTS.md — OCX Salesforce Integration

This repository is the Salesforce side of the OCX Customer AI Source Intelligence integration. Coding agents must treat this file and the referenced architecture documents as durable project instructions, not optional background.

## Read this first

Before changing code, read these files in order:

1. `docs/handoff/CODEX_HANDOFF_2026-08-11.md`
2. `docs/architecture/ocx-source-intelligence.md`
3. `docs/architecture/feature-architecture.md`
4. `docs/architecture/provenance-and-eligibility.md`
5. `docs/demo/bongo-data-conventions.md`
6. `docs/development/salesforce-demo-guardrails.md`
7. `docs/contracts/README.md`
8. `docs/contracts/source-intelligence.v1.schema.json`
9. `docs/history/source-intelligence-implementation-history.md`

If repository metadata or live-org state conflicts with these documents, stop and report the mismatch. Do not silently "fix" history or infer a new architecture.

## Project objective

Customer AI guides a user through:

`Journey -> Stages -> Drivers -> candidate measurements -> human tuning -> approved OCX feature definitions -> later computation/cohorts/analytics`

Salesforce is the first Source Intelligence adapter. It should expose an interpreted, provenance-aware view of Salesforce source data and source-side candidate proposals. OCX owns the final approved feature-definition lifecycle.

## Ownership boundary

Salesforce owns:

- Salesforce source/schema intelligence.
- Source Ingredient classification and data-fitness metadata.
- Profile/Cohort source attributes available from Salesforce.
- Historical recipe priors as evidence, never truth.
- Stage/Driver candidate discovery evidence and source lineage.
- Optional immutable/persisted proposal snapshots.

OCX owns:

- Human-approved/rejected/modified feature definitions.
- OCX feature-definition IDs and version history.
- Final names/formulas/windows after human tuning.
- Feature computation across accounts/time windows.
- Cohort construction and cohort-derived benchmarks.
- Later empirical signal validation and modeling.

Do not collapse these two ownership layers.

## Hard provenance rule

Physical presence in Salesforce does **not** prove that a field is legitimate upstream source evidence. This demo org also contains downstream OCX analytics and reconstruction artifacts. Predictor eligibility must use Source Intelligence classification, not object/field presence alone.

Never use `OUTCOME`, `OCX_DERIVED`, or `MODEL_OUTPUT` fields as source predictors. See `docs/architecture/provenance-and-eligibility.md`.

## Current authoritative live state

Verify before relying on it, but the last known-good state is:

- Salesforce API version: `67.0`.
- Scratch/demo alias: `OCXDemo`.
- Persistent alias: `OCXPersistent`.
- Main Source Intelligence catalog run: `a0HAs0000040k2DMAQ`.
- Catalog counts: 304 Source Ingredients; 21 Profile Feature Definitions.
- Historical semantic recipe priors: 172.
- Completed Support / Effectiveness of Resolution proposal run: `a0HAs0000040tGjMAI`.
- Proposal counts: 16 Direct Experience Feature Definitions, 19 ingredient-lineage links.
- Proposal availability: 14 `DERIVABLE`, 1 `MAPPING_REQUIRED`, 1 `TARGET_NOT_YET_AVAILABLE` in Salesforce storage.
- All proposal features remain source-side `PROPOSED` and `NOT_TESTED`.

## Current next assignment

Build and prove the **read-only Source Intelligence v1 Apex REST service** for:

- `profile`
- persisted `candidates` for a Stage + Driver
- `definition/{candidateId}` with formula/evidence/lineage

Do **not** port live arbitrary-Driver V7 discovery in the first REST phase. First prove retrieval using the already persisted `Support / Effectiveness of Resolution` proposal.

Proposed REST surface:

- `GET /services/apexrest/ocx/source-intelligence/v1/profile`
- `POST /services/apexrest/ocx/source-intelligence/v1/candidates`
- `GET /services/apexrest/ocx/source-intelligence/v1/definitions/{candidateId}`

The exact Apex class layout may follow existing repository conventions. The external behavior must follow the contract docs.

## REST behavior rules

- Read calls are read-only and idempotent.
- A `candidates` read must never create a new proposal run merely because the chat asked a question.
- Normal `candidates` input is free-text Stage + Driver; no Salesforce proposal-run ID is required.
- If an exact persisted proposal exists, return it and its `proposalRunId`.
- Until online V7 discovery exists, an unseen Driver returns an explicit `NOT_GENERATED` state rather than an invented nearest-neighbor match.
- Do not silently nearest-neighbor match a Driver.
- Salesforce record IDs may be included diagnostically, but must not be the primary vendor-neutral external identities.
- Keep `sourceCandidateId/sourceCandidateFingerprint` separate from future `ocxFeatureDefinitionId/version`.
- Expose Salesforce `Human_Status__c` as source proposal state, not as the authoritative OCX human decision.
- Normalize Salesforce `TARGET_NOT_YET_AVAILABLE` to contract value `TARGET_NOT_AVAILABLE` at the adapter boundary.
- `grain` and `window` are required for executable `AVAILABLE`/`DERIVABLE` candidates; they may be null for incomplete/gap candidates when accompanied by `incompleteReasons`.

## Development discipline

- Inspect before editing.
- Prefer existing repository patterns over inventing parallel architecture.
- Make the smallest coherent change that satisfies the phase.
- Run syntax/static checks and relevant Apex tests.
- Dry-run/validate deployments before live deployment when practical.
- Call the real endpoints against `OCXDemo` and save real JSON fixtures.
- Never claim a deploy, write, test, or commit succeeded without actual command output.
- Routine implementation errors may be diagnosed and fixed autonomously. Stop and ask the user when a failure implies an architectural or data-model decision.
- Do not rewrite or "clean up" unrelated parts of the repo.
- Do not commit until the user asks or approves the reviewed diff.

## Git safety

Historically, the working tree has contained unrelated/local files that must remain unstaged, including:

- `force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml`
- Bulk-result CSVs from failed/successful jobs
- `backups/`
- `build/`

Before staging, show `git status --short` and stage an explicit path list only.

## Demo identity rules

The authoritative demo customer/brand is **Bongo**. Follow `docs/demo/bongo-data-conventions.md` exactly. Do not invent product mappings or people identities.

## Signal testing is later

Do not insert full empirical signal testing into the guided-chat path. Candidate discovery remains semantic/source-intelligence driven and stores `NOT_TESTED`. Type-aware statistical/predictive validation is a later asynchronous analytical phase.
