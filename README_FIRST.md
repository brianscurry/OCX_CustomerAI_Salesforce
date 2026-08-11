# OCX Salesforce Integration — Codex Handoff Package

Date: 2026-08-11

This package is intended to move the primary OCX Salesforce development conversation into Codex without losing the architectural and implementation context accumulated during the preceding work.

## How to use this package

1. Put these files at the root of the Salesforce repository (`/Users/briancurry/ocx-salesforce`, referred to as `REPO_ROOT`) while preserving their relative paths.
2. **Do not overwrite an existing `AGENTS.md` blindly.** If one already exists, have Codex merge the instructions while preserving any valid existing repository instructions.
3. Do not stage or commit anything merely because this package was copied in. First review `git status --short` and the diff.
4. Start a persistent Codex thread in the repository and paste the contents of `docs/handoff/CODEX_FIRST_MESSAGE.md` as the first message.
5. Codex should read `AGENTS.md` plus every document referenced there before changing code.
6. The first Codex turn should be an audit/understanding turn only. It should verify the repository and live-org state and report any mismatch with this handoff before implementation begins.

## Files in this package

- `AGENTS.md` — durable repository-level instructions for Codex and future coding agents.
- `docs/handoff/CODEX_HANDOFF_2026-08-11.md` — comprehensive project history, current state, architectural decisions, next work, and acceptance criteria.
- `docs/handoff/CODEX_FIRST_MESSAGE.md` — the exact recommended first message for the persistent Codex thread.
- `docs/architecture/ocx-source-intelligence.md` — system boundary and Source Intelligence architecture.
- `docs/architecture/feature-architecture.md` — feature classes, lifecycle, availability, approval, and later empirical validation.
- `docs/architecture/provenance-and-eligibility.md` — upstream/downstream boundaries, source roles, and leakage rules.
- `docs/demo/bongo-data-conventions.md` — authoritative Bongo demo identities, product mappings, and data conventions.
- `docs/development/salesforce-demo-guardrails.md` — Salesforce/Git workflow and safety rules.
- `docs/history/source-intelligence-implementation-history.md` — detailed implementation/recovery history and known-good identifiers.
- `docs/contracts/source-intelligence.v1.schema.json` — **draft v1 vendor-neutral response contract** to be proven against real Apex responses before OCX Phase 2 work.
- `docs/contracts/README.md` — route behavior, request shape, identity semantics, and fixture requirements.
- `docs/contracts/examples/README.md` — names of the real live-org fixtures Codex must create. No fabricated fixture is included here.

## Important

The contract is deliberately marked draft until Codex builds the read-only Apex REST service, calls it against the actual `OCXDemo` org, and compares the real responses to the schema. Do not ask the OCX/Lovable side to implement Phase 2 conversation wiring against an unproven payload.
