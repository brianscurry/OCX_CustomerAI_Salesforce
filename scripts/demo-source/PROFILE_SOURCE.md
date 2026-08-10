# OCX Demo Account Profile Source Reconstruction

## Purpose

This phase reconstructs the Account/Profile source layer that would plausibly
exist in Salesforce before OCX publishes analytics, documents, dashboards,
portfolios, model outputs, or other downstream OCX products back to Salesforce.

The source is based on prototype-customer profile snapshots plus the approved
Conga-to-Marumba Account mapping.

## Authoritative demo population

The OCX Salesforce demo contains 7,755 authoritative demo Accounts.

The prototype mapping contains a larger historical population. Accounts that
were intentionally removed from the demo are not recreated or loaded.

A Salesforce system/sample Account may exist outside the 7,755 demo population
and is deliberately excluded from profile loading.

## Mapping / transformation rule

For any information class represented by the approved mapping file, use the
mapped Marumba value.

If a targeted profile value is not mapped by that file, preserve the source
profile value as-is.

For the current Account profile load:

- Account identity/name is resolved through the Conga-to-Marumba mapping.
- Existing Salesforce Account.Name is not overwritten.
- Existing Account.OCX_Account_ID__c is not overwritten.
- Other targeted profile attributes pass through unchanged.
- No additional pseudonymization, perturbation, category remapping, or
  synthetic transformation is applied.

## Source files

The loader expects these files outside source control, normally in Downloads:

- profile_2024.csv
- profile_2025.csv
- conga_to_marumba_account_mapping*.csv

These customer-derived source files are intentionally not committed to Git.
Generated run artifacts and rollback files are written beneath `.ocx/` and are
also intentionally not committed.

## Source precedence

The current authoritative active Marumba demo population resolves entirely from
the 2025 profile snapshot. The loader retains 2024 fallback logic for repeatable
reconstruction if needed.

## Loader

Use:

    scripts/demo-source/06_load_account_profile_source.sh build-local
    scripts/demo-source/06_load_account_profile_source.sh schema-dry-run
    scripts/demo-source/06_load_account_profile_source.sh schema-apply
    scripts/demo-source/06_load_account_profile_source.sh preflight
    scripts/demo-source/06_load_account_profile_source.sh apply

Rollback is supported by passing a generated rollback CSV to the loader's
`rollback` mode.

## Validated result

The completed load was validated against OCXDemo with these results:

- authoritative demo Accounts: 7,755
- loaded Accounts found in Salesforce: 7,755
- profile/source fields validated: 50
- individual field values validated: 387,750
- value mismatches: 0
- fields with mismatches: 0

Source nulls remain null in Salesforce. Lower population on individual source
fields is therefore expected and should be visible to later source profiling.

Representative validated coverage included:

- Customer_Since_Date__c: 7,755
- Source_Industry__c: 7,746
- AnnualRevenue: 7,737
- NumberOfEmployees: 7,719
- Customer_Segment__c: 7,755
- Region__c: 7,755
- Source_ACV__c: 7,755
- Product_Family_Number__c: 6,272
- Community_Users__c: 7,440
- Super_Users__c: 7,440
- Last_Login_Date__c: 7,222

## Product boundary

This reconstruction is source-side data only. It is intended to support the
Customer AI demo workflow:

    discover -> profile -> target -> retrieve -> display -> purge -> repeat

The retrieved data is not yet used to build generative CX models.

Do not treat downstream OCX analytics, model outputs, survey outcomes,
portfolios, expansion outputs, published content, or action-plan artifacts as
upstream Salesforce source evidence.
