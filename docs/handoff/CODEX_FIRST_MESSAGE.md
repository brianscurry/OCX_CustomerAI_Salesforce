# First message to paste into the persistent Codex thread

We are continuing the OCX Salesforce Integration project from a long-running architecture + implementation thread. I want this Codex thread to become the primary development conversation, not just a one-shot coding task.

Before changing anything:

1. Read `AGENTS.md` and every document it marks as required.
2. Inspect the actual repository, especially `scripts/source-intelligence/`, Source Intelligence Salesforce metadata, existing Apex REST/service patterns, permission sets, manifests, and tests.
3. Verify the current Git state and recent commits. Do not stage, discard, or clean unrelated working-tree changes.
4. Verify the `OCXDemo` org connection and the relevant live Source Intelligence state using read-only CLI queries/calls. In particular, verify the immutable source catalog run and the completed Support / Effectiveness of Resolution proposal described in the handoff.
5. Compare what you find to `docs/handoff/CODEX_HANDOFF_2026-08-11.md`. If anything materially conflicts, stop and tell me exactly what is different before editing code.

Then give me a concise but technically specific understanding of:

- the product goal and Journey -> Stage -> Driver -> feature flow;
- why Source Intelligence exists instead of raw schema prompting;
- the Salesforce-versus-OCX ownership boundary;
- the Direct Experience / Profile / Cohort Derived distinction;
- provenance/leakage rules;
- the current verified Salesforce data/model state;
- what V7 discovery already does;
- why full signal testing is intentionally later;
- the proposal-persistence history and resume-safe lesson;
- the exact next REST-v1 phase and what is explicitly out of scope.

After that, propose the smallest coherent implementation plan for the read-only Source Intelligence REST v1 service:

- `GET /services/apexrest/ocx/source-intelligence/v1/profile`
- `POST /services/apexrest/ocx/source-intelligence/v1/candidates`
- `GET /services/apexrest/ocx/source-intelligence/v1/definitions/{candidateId}`

The first phase must retrieve existing persisted intelligence only. Do not port live arbitrary-Driver V7 discovery yet. Do not change the Source Intelligence object model. Do not make `candidates` create proposal runs. Do not silently nearest-neighbor match unseen Drivers. Do not commit anything yet.

Your plan should identify:

- classes/files you expect to add/change after inspecting existing repository patterns;
- DTO/serialization approach;
- candidate stable-ID/fingerprint approach, clearly calling out any cross-system identity decision that needs my approval;
- Apex test cases;
- permission/metadata changes if needed;
- how you will make real authenticated calls against `OCXDemo`;
- how you will capture and validate the real JSON fixtures against `docs/contracts/source-intelligence.v1.schema.json`;
- how you will prove read-only/no-new-proposal behavior.

Do not start implementation until you have shown me the audit result and plan and I have confirmed there is no context mismatch.
