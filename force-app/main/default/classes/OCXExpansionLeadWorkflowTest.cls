@IsTest
private class OCXExpansionLeadWorkflowTest {
    private static String activeStage() {
        return [
            SELECT MasterLabel
            FROM OpportunityStage
            WHERE IsActive = true
            ORDER BY SortOrder
            LIMIT 1
        ].MasterLabel;
    }

    private static OCX_Expansion_Lead__c makeLead(String status) {
        Account account = new Account(Name = 'Expansion Workflow Test Account');
        insert account;

        OCX_Expansion_Lead__c lead = new OCX_Expansion_Lead__c(
            OCX_Account__c = account.Id,
            OCX_Status__c = status,
            OCX_Recommended_Product__c = 'Analytics Expansion',
            OCX_Estimated_Value__c = 50000,
            OCX_Rationale__c = 'Promoter with expansion propensity.'
        );
        insert lead;
        return lead;
    }

    @IsTest
    static void testGetAndAccept() {
        OCX_Expansion_Lead__c lead = makeLead('New');
        Test.startTest();
        OCXExpansionLeadService.LeadView accepted = OCXExpansionLeadController.acceptLead(lead.Id);
        Test.stopTest();

        System.assertEquals('Accepted', accepted.status);
        OCX_Expansion_Lead__c stored = [
            SELECT OCX_Status__c, OCX_Accepted_By__c, OCX_Accepted_At__c
            FROM OCX_Expansion_Lead__c
            WHERE Id = :lead.Id
        ];
        System.assertEquals('Accepted', stored.OCX_Status__c);
        System.assertEquals(UserInfo.getUserId(), stored.OCX_Accepted_By__c);
        System.assertNotEquals(null, stored.OCX_Accepted_At__c);
    }

    @IsTest
    static void testRejectRequiresReason() {
        OCX_Expansion_Lead__c lead = makeLead('New');
        Boolean thrown = false;
        try {
            OCXExpansionLeadController.rejectLead(lead.Id, '  ');
        } catch (AuraHandledException expected) {
            thrown = true;
        }
        System.assert(thrown, 'Expected blank rejection reason to fail.');

        OCXExpansionLeadController.rejectLead(lead.Id, 'Bad timing');
        OCX_Expansion_Lead__c stored = [
            SELECT OCX_Status__c, OCX_Rejected_Reason__c
            FROM OCX_Expansion_Lead__c
            WHERE Id = :lead.Id
        ];
        System.assertEquals('Rejected', stored.OCX_Status__c);
        System.assertEquals('Bad timing', stored.OCX_Rejected_Reason__c);
    }

    @IsTest
    static void testConvertAcceptedLead() {
        OCX_Expansion_Lead__c lead = makeLead('New');
        OCXExpansionLeadController.acceptLead(lead.Id);

        OCXExpansionLeadService.ConversionInput input = new OCXExpansionLeadService.ConversionInput();
        input.opportunityName = 'Expansion Workflow Test Opportunity';
        input.amount = 50000;
        input.closeDate = Date.today().addDays(90);
        input.stageName = activeStage();

        Test.startTest();
        Opportunity opportunity = OCXExpansionLeadController.convertLead(lead.Id, input);
        Test.stopTest();

        System.assertEquals(lead.Id, opportunity.OCX_Expansion_Lead__c);
        OCX_Expansion_Lead__c converted = [
            SELECT OCX_Status__c, OCX_Converted_Opportunity__c, OCX_Converted_At__c
            FROM OCX_Expansion_Lead__c
            WHERE Id = :lead.Id
        ];
        System.assertEquals('Converted', converted.OCX_Status__c);
        System.assertEquals(opportunity.Id, converted.OCX_Converted_Opportunity__c);
        System.assertNotEquals(null, converted.OCX_Converted_At__c);
    }

    @IsTest
    static void testConversionRequiresAcceptance() {
        OCX_Expansion_Lead__c lead = makeLead('New');
        OCXExpansionLeadService.ConversionInput input = new OCXExpansionLeadService.ConversionInput();
        input.opportunityName = 'Should Not Create';
        input.closeDate = Date.today().addDays(30);
        input.stageName = activeStage();

        Boolean thrown = false;
        try {
            OCXExpansionLeadController.convertLead(lead.Id, input);
        } catch (AuraHandledException expected) {
            thrown = true;
        }
        System.assert(thrown, 'Expected conversion of an unaccepted lead to fail.');
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE Name = 'Should Not Create']);
    }

    @IsTest
    static void testActiveStages() {
        System.assert(!OCXExpansionLeadController.getActiveStages().isEmpty());
    }
}
