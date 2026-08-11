# Bongo Demo Data Conventions

These conventions are authoritative for the OCX Salesforce demo. Do not invent alternatives.

## Customer/brand

The only demo-facing customer/brand name is **Bongo**.

Any obsolete prior demo-brand reference is forbidden in demo-facing data, documentation, UI, scripts, or generated values. Legacy technical column names may remain only when changing them would break an established import/mapping contract; do not propagate them into new artifacts.

## Authoritative Account population

The authoritative Bongo Account population is **7,755 Accounts**.

The population was intentionally reduced from a larger prototype/source population. Source-profile rows belonging to removed Accounts should be ignored rather than loaded, recreated, or used to increase the account count.

## Demo contacts

Use the same dummy identities for every customer when demo people are needed.

### Customer-side contacts

- Diana Reeves — VP Procurement
- Tom Nakamura — Director of Operations
- Priya Sharma — Platform Admin
- Mike Torres — IT Lead

### Bongo/vendor-side contacts

- Sarah Chen — CSM
- Marcus Webb — Account Executive
- Rachel Torres — Implementation Consultant
- James Walsh — Support Engineer
- Jennifer Park — CS Manager

Do not replace these with prototype-customer people or invent new recurring demo identities without an explicit product decision.

## Product/category anonymization

### Family/category mappings

- Contracts -> Agreements
- Commerce & Revenue -> Commercial Operations
- Core Apps -> Platform Services
- CPQ -> QuoteFlow
- CLM -> Contracta
- Digital Docs -> Docstream

### Product-name mappings

- Conga Composer -> Write Up
- Conga Sign -> Sign Here
- Conga Grid -> Matrix
- Conga X-Author Enterprise -> Write Up Enterprise
- Conga X-Author -> Write Up Enterprise
- Conga Orchestrate -> Conductor
- Conga Billing -> Billing
- Conga Collaborate -> Collab
- Conga Digital Commerce -> Online Seller
- Conga Order Management -> Order Pro
- Other -> Other
- Support -> Support

### Additional normalization mappings

- Approvals -> Other
- Batch Trigger -> Other
- Conga Quote Generation -> QuoteFlow
- Revenue Management -> Billing
- source labels equivalent to `Revenue Management (Billing, Order, Rev Rec)` -> Billing

Clear legacy/version aliases of a product already mapped above may normalize to its approved Bongo label. Do not invent a new product label for an unresolved source product.

## Support Product normalization

For remaining unmapped source **Product** values:

- if the Product label contains the word `Community`, map it to `Community`;
- otherwise map it to `Other`.

This rule applies to Product labels only.

Keep `PL` as a separate product-line/category rollup dimension. Do not apply the Product fallback rule to `PL`, and do not turn `Support PL` into a Product-name mapping.

## ACV convention

Use `Account.Source_ACV__c` for upstream/source-profile ACV.

Do not use `Account.OCX_ACV__c` as source evidence.

## Product mapping discipline

Do not invent product mappings beyond the approved table. If a source product cannot be resolved by an explicit mapping or a clearly equivalent legacy/version alias, treat it as requiring explicit mapping/confirmation unless the Support Product fallback rule applies.
