# Bongo Account/Profile Anonymization

The authoritative OCX demo customer/brand is **Bongo**.

The Account/Profile reconstruction uses the prototype source snapshots only as
source ingredients for the demo. The final Salesforce demo must never surface
prototype-customer people or unapproved product labels.

## Authoritative population

- Bongo demo Accounts: 7,755
- Accounts intentionally removed from the prototype population remain removed.
- The source loader must never recreate removed Accounts.

## Account identity

Account identity/name is taken from the supplied account mapping file.

Legacy technical column names in that mapping file can remain in the local input
file, but they are not demo-facing labels.

## Raw source ACV

Raw profile ACV is written to:

`Account.Source_ACV__c`

It must not be written to:

`Account.OCX_ACV__c`

`OCX_ACV__c` remains the downstream Customer AI field.

## Approved product/category labels

- Contracts -> Agreements
- Commerce & Revenue -> Commercial Operations
- Core Apps -> Platform Services
- CPQ -> QuoteFlow
- CLM -> Contracta
- Digital Docs -> Docstream
- Conga Contracts -> Agreements
- Conga CPQ -> QuoteFlow
- Conga CLM -> Contracta
- Conga Composer -> Write Up
- Conga Sign -> Sign Here
- Conga Grid -> Matrix
- Conga X-Author -> Write Up Enterprise
- Conga X-Author Enterprise -> Write Up Enterprise
- Conga Orchestrate -> Conductor
- Conga Billing -> Billing
- Conga Collaborate -> Collab
- Conga Digital Commerce -> Online Seller
- Conga Order Management -> Order Pro
- Other -> Other
- Support -> Support

Unrecognized product labels require explicit mapping/confirmation. Do not invent
new product mappings.

## Fixed Bongo demo people

Customer-side contacts:

- Diana Reeves — VP Procurement
- Tom Nakamura — Director of Operations
- Priya Sharma — Platform Admin
- Mike Torres — IT Lead

Company/vendor-side contacts:

- Sarah Chen — CSM
- Marcus Webb — Account Executive
- Rachel Torres — Implementation Consultant
- James Walsh — Support Engineer
- Jennifer Park — CS Manager

The Account profile repair currently uses:

- Source Owner -> Marcus Webb
- Customer Manager -> Sarah Chen
- Territory Manager -> Marcus Webb
- Renewals Manager -> Jennifer Park
- New Account Owner -> Marcus Webb
- Previous Account Owner -> Jennifer Park

## Rebuild sequence

After the base demo data is loaded and the profile-source schema is deployed:

1. Run the versioned profile source loader.
2. Run `07_repair_bongo_profile_anonymization.sh preflight`.
3. Inspect the product mapping inventory.
4. Run `07_repair_bongo_profile_anonymization.sh apply`.
5. Require zero failed records, zero value mismatches, and zero person identity
   errors.

The repair script is the final safety gate for the reconstructed Account/Profile
source layer.
