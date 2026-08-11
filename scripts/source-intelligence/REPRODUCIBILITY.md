# Source Intelligence reproducibility

This directory contains the versioned seed needed to recreate the approved
Salesforce Source Intelligence catalog after the baseline Bongo demo data and
Source Intelligence metadata have been deployed.

## Approved catalog

- 304 Salesforce Source Ingredients
- 21 proposed Profile/Cohort Feature Definitions
- 21 Profile Feature -> Source Ingredient lineage records
- 172 merged historical semantic recipe priors
- 0 Direct Experience Feature Definitions at bootstrap time
- 0 Cohort Derived Feature Definitions at bootstrap time

Direct Experience KPI definitions are intentionally generated later against an
approved Journey Stage and Driver.

## Source boundary

`Account.Source_ACV__c` is the upstream/profile ACV ingredient.

`Account.OCX_ACV__c` is a downstream Customer AI/OCX field and is excluded from
source-feature discovery even when current demo values happen to be identical.

Known outcome fields such as source Case satisfaction and source CSM sentiment
remain available as outcomes/context but are not predictor inputs.

## Recreate

After deploying the repository metadata and loading the baseline Bongo demo
source data:

```bash
scripts/source-intelligence/02_seed_source_dictionary.sh preflight
scripts/source-intelligence/02_seed_source_dictionary.sh apply
```

The bootstrap creates a new `OCX_Source_Intelligence_Run__c`, remaps all
run-scoped keys and relationship IDs, upserts the 172 global historical recipe
priors, verifies the expected counts, and marks the new run Complete.

The versioned seeds contain dictionary/configuration records only. They do not
contain Account, Opportunity, Case, Task, transcript, or other customer record
payloads.
