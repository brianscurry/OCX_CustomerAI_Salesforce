# Source Intelligence Contract v1

Status: **DRAFT until validated against real Salesforce Apex REST responses.**

The authoritative vendor-neutral response schema is:

- `docs/contracts/source-intelligence.v1.schema.json`

The purpose of this contract is to keep the OCX chat/analytics layers independent of Salesforce Source Intelligence storage details.

## Contract version

Every response must include:

```json
{"contractVersion":"1.0"}
```

## Proposed Salesforce REST routes

- `GET /services/apexrest/ocx/source-intelligence/v1/profile`
- `POST /services/apexrest/ocx/source-intelligence/v1/candidates`
- `GET /services/apexrest/ocx/source-intelligence/v1/definitions/{candidateId}`

The Salesforce adapter may use whatever internal classes/services fit repository conventions, but the external payload must validate against v1 before OCX Phase 2 chat integration.

## `profile`

### Request

No Stage/Driver is required. Authentication/tenant context comes from the connected Salesforce user/org.

### Response purpose

Return the Salesforce Profile/Cohort attribute catalog, including where available:

- stable profile-feature identity
- name/description
- feature type
- availability
- source ingredients
- coverage
- cardinality
- bucketing strategy
- cohort suitability
- minimum cohort size

If the current Salesforce model does not store one of the future cohort metadata fields yet, return `null` rather than inventing it. Do not change the data model merely to satisfy a speculative field without discussing the need first.

## `candidates`

### Request

Primary input is free-text Stage + Driver.

Recommended v1 request shape:

```json
{
  "stage": {
    "name": "Support",
    "description": null
  },
  "driver": {
    "name": "Effectiveness of Resolution",
    "description": null
  },
  "limit": 15
}
```

A Salesforce proposal-run ID is not required for the normal chat path.

A future replay/debug option may accept a proposal-run ID, but do not make it the primary interface.

### Read-only behavior

A `candidates` call must not create Salesforce records.

If an exact persisted proposal snapshot exists for the requested Stage + Driver, return it and include its `proposalRunId` in source metadata.

Until live V7 discovery is available behind Apex, an unseen Driver should return:

- retrieval status `NOT_GENERATED`
- empty candidate list
- no new proposal run

Do not silently nearest-neighbor match another Driver.

### Availability normalization

Salesforce storage -> v1 contract:

- AVAILABLE -> AVAILABLE
- DERIVABLE -> DERIVABLE
- MAPPING_REQUIRED -> MAPPING_REQUIRED
- TARGET_NOT_YET_AVAILABLE -> TARGET_NOT_AVAILABLE

OCX should not re-derive availability from raw fields.

### Candidate completeness

For executable candidates (`AVAILABLE` or `DERIVABLE`):

- `grain` must be non-null
- `window` must be non-null

For incomplete/gap candidates (`MAPPING_REQUIRED` or `TARGET_NOT_AVAILABLE`):

- `grain` and/or `window` may be null
- use `incompleteReasons` to explain what prevents execution

Do not silently default either field.

## `definition/{candidateId}`

Returns the expanded source-side definition for one candidate, including:

- name/description/theme
- availability
- formula
- grain/window
- source ingredients
- expanded lineage/evidence
- rationale
- scores/data-fitness metadata where available
- source proposal status
- empirical status
- source identifiers for diagnostics/provenance

The chat should normally use the compact candidate list first, then call `definition` when it needs expanded explanation/lineage rather than loading the entire Salesforce dictionary for every Driver.

## Identity semantics

Keep these separate:

- `sourceCandidateId` — stable external candidate identity within the source adapter
- `sourceCandidateFingerprint` — deterministic semantic/content fingerprint
- Salesforce record ID — optional diagnostics/provenance only
- future `ocxFeatureDefinitionId` — authoritative OCX-owned definition identity
- future `ocxFeatureDefinitionVersion` — OCX-owned version

Do not use a Salesforce record ID as the vendor-neutral final feature-definition identity.

The exact fingerprint algorithm should be deterministic and documented before the contract is frozen. If repository/live-data realities force a choice among plausible algorithms, stop and discuss it rather than making an invisible cross-system identity decision.

## Source proposal status versus OCX human decision

Salesforce `Human_Status__c` is source-side proposal state. Expose it in v1 as something like:

- `sourceProposalStatus`

Do not map it to the future authoritative OCX user decision.

`Empirical_Status__c` may be exposed as:

- `empiricalStatus`

The current persisted proposal should remain `NOT_TESTED`.

## Security/data minimization

- Return only data needed by the Source Intelligence contract.
- Do not return raw full Salesforce records.
- Do not expose excluded downstream values as candidate source evidence.
- Do not expose full conversation/transcript payloads through these endpoints.
- Preserve source eligibility classifications.

## Real fixture gate

Before the OCX application wires this into the guided conversation, Codex must create real live-org fixtures from `OCXDemo` and validate them against the schema.

Required fixtures are listed in `docs/contracts/examples/README.md`.

The reference Stage/Driver for the first fixture is:

- Stage: `Support`
- Driver: `Effectiveness of Resolution`

This should correspond to completed proposal run:

- `a0HAs0000040tGjMAI`

Verify the run exists and is complete before using the ID.
