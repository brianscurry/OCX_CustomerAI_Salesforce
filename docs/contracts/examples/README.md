# Required Real Contract Fixtures

Do not fabricate these JSON files from this handoff. The purpose of Phase 1 is to prove the contract with real Apex responses from the live `OCXDemo` org.

Codex should create and version fixtures after the endpoints exist and pass tests.

Recommended fixture names:

1. `profile.json`
   - real `GET /profile` response
   - expected to represent the current 21 Profile Feature Definitions

2. `candidates.support-effectiveness-of-resolution.json`
   - real `POST /candidates` response for:
     - Stage: Support
     - Driver: Effectiveness of Resolution
   - expected source proposal run: `a0HAs0000040tGjMAI`
   - expected current proposal inventory: 16 Direct Experience candidates
   - expected availability split in Salesforce storage: 14 DERIVABLE, 1 MAPPING_REQUIRED, 1 TARGET_NOT_YET_AVAILABLE
   - v1 response should normalize the last value to TARGET_NOT_AVAILABLE

3. `definition.<stable-candidate-slug-or-id>.json`
   - choose one executable Support candidate with nontrivial lineage
   - include expanded ingredients/formula/evidence

4. `candidates.unseen-driver.json`
   - request a clearly nonexistent/unpersisted Stage + Driver during Phase 1
   - expected behavior before live V7 Apex discovery: `NOT_GENERATED`, zero candidates, no Salesforce write

After writing fixtures:

- validate JSON syntax
- validate each response against `source-intelligence.v1.schema.json`
- prove the `candidates` calls did not create new proposal runs
- document the exact command/call used to capture each fixture
