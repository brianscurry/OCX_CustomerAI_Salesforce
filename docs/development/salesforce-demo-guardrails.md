# Salesforce Demo Development Guardrails

## Repository and org

Canonical local repository:

`/Users/briancurry/ocx-salesforce`

GitHub repository:

`brianscurry/OCX_CustomerAI_Salesforce`

Salesforce aliases:

- scratch/demo org: `OCXDemo`
- persistent org: `OCXPersistent`

Salesforce API version:

- `67.0`

Verify all of the above in the actual environment before using them.

## Working style

This project has intentionally used a cautious CLI-first workflow because source reconstruction and metadata changes can easily create duplicate or misleading demo data.

Preferred sequence:

1. Inspect repository and live-org state.
2. Explain the intended change and scope.
3. Make a bounded implementation.
4. Run syntax/static checks.
5. Run a dry-run/preflight/validation when available.
6. Run targeted tests.
7. Deploy/apply.
8. Verify live state with explicit queries/calls.
9. Review exact Git diff/status.
10. Stage explicit files only.
11. Commit/push only after review/approval.

## Never claim success without evidence

Do not say any of the following unless actual command output proves it:

- deployment succeeded
- records were created/updated
- Apex tests passed
- endpoint returned the expected result
- Git commit/push succeeded

If a write partially succeeds and then fails, preserve the successfully written state and resume idempotently. Do not blindly rerun a create path that could duplicate data.

## Known interrupted-write lesson

The Stage/Driver proposal persistence phase originally created a proposal run and two Feature Definitions before a CLI parsing failure. Recovery reused the existing run and inserted only missing records.

This is now a general project rule:

> Determine what actually succeeded before retrying a write.

## Git hygiene

Do not stage unrelated files simply to obtain a clean status.

Known examples of local/unrelated files that have historically needed to remain unstaged:

- `force-app/main/default/permissionsets/OCX_Portfolio_Explorer.permissionset-meta.xml`
- failed/success Bulk CSV artifacts
- `backups/`
- `build/`

Before staging:

- run `git status --short`
- stage an explicit path list
- run `git diff --cached --name-status`
- run `git diff --cached --stat`
- inspect staged diff if nontrivial

Do not use broad `git add .` for this project unless the user explicitly approves the entire working tree.

## Source Intelligence script phases

Canonical scripts last known in the repo:

- `scripts/source-intelligence/03_stage_driver_kpi_discovery_preflight.sh`
- `scripts/source-intelligence/04_prepare_stage_driver_feature_proposals.sh`
- `scripts/source-intelligence/05_persist_stage_driver_feature_proposals.sh`

The canonical `05` uses resume-safe/Bulk-API behavior rather than the earlier broken complex `sf data create record --values` path.

## Salesforce REST development guidance

For the next REST phase:

- inspect existing Apex REST/controller/service/DTO conventions first
- do not create a parallel framework if one already exists
- keep retrieval code read-only
- enforce sharing/security according to existing repository patterns and intended connected-user behavior
- make field/object permissions explicit if the endpoint execution context requires them
- avoid leaking internal Source Intelligence storage shape into the vendor-neutral contract
- use DTOs/serializers rather than returning raw sObjects directly
- add focused Apex tests for successful retrieval, missing/unseen Driver, invalid candidate ID, and no-write behavior
- prove with real HTTP/Apex REST calls against `OCXDemo`

## Stop conditions

Stop and ask the user before proceeding if implementation requires any of these:

- changing the seven-object Source Intelligence data model
- changing authoritative Bongo mappings/identities
- reclassifying source roles/eligibility in a way that changes predictor semantics
- making candidate retrieval write records
- changing Salesforce-vs-OCX ownership
- using downstream OCX fields as source evidence
- deciding a new canonical candidate identity algorithm with material cross-system implications if the current docs are insufficient
- destructive cleanup or data deletion
- modifying unrelated repository work

Routine compilation/test failures that do not change architecture may be diagnosed and repaired without stopping.
