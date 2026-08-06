public with sharing class OCXExpansionLeadService {
    public class ConversionInput {
        @AuraEnabled public String opportunityName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public String stageName;
    }

    public class LeadView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String status;
        @AuraEnabled public String recommendedProduct;
        @AuraEnabled public Decimal estimatedValue;
        @AuraEnabled public String rationale;
        @AuraEnabled public String sourceUrl;
        @AuraEnabled public Id convertedOpportunityId;
        @AuraEnabled public String convertedOpportunityName;
    }

    public static LeadView getLead(Id expansionLeadId) {
        if (expansionLeadId == null) {
            throw new AuraHandledException('Expansion Lead ID is required.');
        }

        OCX_Expansion_Lead__c row = [
            SELECT Id, Name, OwnerId, Owner.Name,
                   OCX_Account__c, OCX_Account__r.Name,
                   OCX_Status__c, OCX_Recommended_Product__c,
                   OCX_Estimated_Value__c, OCX_Rationale__c,
                   OCX_Source_URL__c,
                   OCX_Converted_Opportunity__c,
                   OCX_Converted_Opportunity__r.Name
            FROM OCX_Expansion_Lead__c
            WHERE Id = :expansionLeadId
            LIMIT 1
        ];

        LeadView view = new LeadView();
        view.id = row.Id;
        view.name = row.Name;
        view.accountId = row.OCX_Account__c;
        view.accountName = row.OCX_Account__r == null ? null : row.OCX_Account__r.Name;
        view.ownerId = row.OwnerId;
        view.ownerName = row.Owner == null ? null : row.Owner.Name;
        view.status = row.OCX_Status__c;
        view.recommendedProduct = row.OCX_Recommended_Product__c;
        view.estimatedValue = row.OCX_Estimated_Value__c;
        view.rationale = row.OCX_Rationale__c;
        view.sourceUrl = row.OCX_Source_URL__c;
        view.convertedOpportunityId = row.OCX_Converted_Opportunity__c;
        view.convertedOpportunityName = row.OCX_Converted_Opportunity__r == null
            ? null
            : row.OCX_Converted_Opportunity__r.Name;
        return view;
    }

    public static LeadView acceptLead(Id expansionLeadId) {
        OCX_Expansion_Lead__c row = lockLead(expansionLeadId);
        ensureNotTerminal(row);

        row.OCX_Status__c = 'Accepted';
        row.OCX_Accepted_By__c = UserInfo.getUserId();
        row.OCX_Accepted_At__c = System.now();
        row.OCX_Rejected_Reason__c = null;
        update row;
        return getLead(row.Id);
    }

    public static LeadView rejectLead(Id expansionLeadId, String reason) {
        if (String.isBlank(reason)) {
            throw new AuraHandledException('A rejection reason is required.');
        }

        OCX_Expansion_Lead__c row = lockLead(expansionLeadId);
        ensureNotTerminal(row);

        row.OCX_Status__c = 'Rejected';
        row.OCX_Rejected_Reason__c = reason.trim();
        update row;
        return getLead(row.Id);
    }

    public static Opportunity convertLead(Id expansionLeadId, ConversionInput input) {
        if (input == null) {
            throw new AuraHandledException('Opportunity details are required.');
        }
        if (String.isBlank(input.opportunityName)) {
            throw new AuraHandledException('Opportunity Name is required.');
        }
        if (input.closeDate == null) {
            throw new AuraHandledException('Close Date is required.');
        }
        if (String.isBlank(input.stageName)) {
            throw new AuraHandledException('Stage is required.');
        }

        OCX_Expansion_Lead__c row = lockLead(expansionLeadId);
        if (row.OCX_Status__c != 'Accepted') {
            throw new AuraHandledException('The Expansion Lead must be accepted before conversion.');
        }
        if (row.OCX_Converted_Opportunity__c != null) {
            throw new AuraHandledException('This Expansion Lead has already been converted.');
        }
        if (row.OCX_Account__c == null) {
            throw new AuraHandledException('The Expansion Lead must be related to an Account.');
        }

        Integer validStageCount = [
            SELECT COUNT()
            FROM OpportunityStage
            WHERE IsActive = true AND MasterLabel = :input.stageName
        ];
        if (validStageCount == 0) {
            throw new AuraHandledException('The selected Opportunity stage is not active.');
        }

        Opportunity opportunity = new Opportunity(
            AccountId = row.OCX_Account__c,
            OwnerId = row.OwnerId,
            Name = input.opportunityName.trim(),
            StageName = input.stageName,
            CloseDate = input.closeDate,
            Amount = input.amount,
            OCX_Expansion_Lead__c = row.Id,
            Description = buildDescription(row)
        );
        insert opportunity;

        row.OCX_Status__c = 'Converted';
        row.OCX_Converted_Opportunity__c = opportunity.Id;
        row.OCX_Converted_At__c = System.now();
        update row;

        return [
            SELECT Id, Name, AccountId, OwnerId, StageName, CloseDate, Amount,
                   OCX_Expansion_Lead__c
            FROM Opportunity
            WHERE Id = :opportunity.Id
        ];
    }

    public static List<String> getActiveStages() {
        List<String> values = new List<String>();
        for (OpportunityStage stage : [
            SELECT MasterLabel
            FROM OpportunityStage
            WHERE IsActive = true
            ORDER BY SortOrder
        ]) {
            values.add(stage.MasterLabel);
        }
        return values;
    }

    private static OCX_Expansion_Lead__c lockLead(Id expansionLeadId) {
        if (expansionLeadId == null) {
            throw new AuraHandledException('Expansion Lead ID is required.');
        }
        return [
            SELECT Id, OwnerId, OCX_Account__c, OCX_Status__c,
                   OCX_Recommended_Product__c, OCX_Rationale__c,
                   OCX_Source_URL__c, OCX_Converted_Opportunity__c
            FROM OCX_Expansion_Lead__c
            WHERE Id = :expansionLeadId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static void ensureNotTerminal(OCX_Expansion_Lead__c row) {
        if (row.OCX_Status__c == 'Converted') {
            throw new AuraHandledException('A converted Expansion Lead cannot be changed.');
        }
    }

    private static String buildDescription(OCX_Expansion_Lead__c row) {
        List<String> parts = new List<String>{'Created from an OCX Expansion Lead.'};
        if (!String.isBlank(row.OCX_Recommended_Product__c)) {
            parts.add('Recommended product: ' + row.OCX_Recommended_Product__c);
        }
        if (!String.isBlank(row.OCX_Rationale__c)) {
            parts.add('Qualification rationale: ' + row.OCX_Rationale__c);
        }
        if (!String.isBlank(row.OCX_Source_URL__c)) {
            parts.add('OCX source: ' + row.OCX_Source_URL__c);
        }
        return String.join(parts, '\n');
    }
}
