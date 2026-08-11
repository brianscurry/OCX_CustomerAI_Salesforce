# CX Source Intelligence

Salesforce-resident semantic/source-intelligence layer for Customer AI.

The foundation explicitly supports three feature classes:

- DIRECT_EXPERIENCE
- PROFILE
- COHORT_DERIVED

Generated records are grouped under `OCX_Source_Intelligence_Run__c`, which is
the purge/rebuild boundary. Stable theme/concept/template records are seeded
independently and are not purged with a discovery run.

## Modes

    scripts/source-intelligence/01_create_foundation.sh audit
    scripts/source-intelligence/01_create_foundation.sh prepare
    scripts/source-intelligence/01_create_foundation.sh schema-dry-run
    scripts/source-intelligence/01_create_foundation.sh schema-apply
    scripts/source-intelligence/01_create_foundation.sh seed
    scripts/source-intelligence/01_create_foundation.sh verify
    scripts/source-intelligence/01_create_foundation.sh commit

Always run `schema-dry-run` before `schema-apply`.
