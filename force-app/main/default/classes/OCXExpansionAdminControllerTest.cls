@IsTest
private class OCXExpansionAdminControllerTest {
    @TestSetup
    static void setupData() {
        Account a = new Account(Name = 'Admin UI Test Account');
        a.OCX_NPS_Class__c = 'Promoter';
        a.OCX_Propensity__c = 'Upsell';
        insert a;
    }

    @IsTest
    static void testSaveListGetAndPreview() {
        OCX_Expansion_Qualification_Rule__c ruleRecord = new OCX_Expansion_Qualification_Rule__c(
            OCX_Rule_Name__c = 'Admin UI Test Rule',
            OCX_Active__c = true,
            OCX_Match_Type__c = 'All'
        );
        List<OCX_Expansion_Rule_Condition__c> rows = new List<OCX_Expansion_Rule_Condition__c>{
            new OCX_Expansion_Rule_Condition__c(
                OCX_Field_API_Name__c = 'OCX_NPS_Class__c',
                OCX_Field_Label__c = 'OCX NPS Class',
                OCX_Data_Type__c = 'String',
                OCX_Operator__c = 'Equals',
                OCX_Value__c = 'Promoter'
            )
        };

        Test.startTest();
        OCXExpansionAdminController.SaveResult saved = OCXExpansionAdminController.saveRule(ruleRecord, rows);
        List<OCX_Expansion_Qualification_Rule__c> rules = OCXExpansionAdminController.listRules();
        OCXExpansionAdminController.RuleBundle bundle = OCXExpansionAdminController.getRule(saved.ruleId);
        OCXExpansionRuleEngine.RulePreview preview = OCXExpansionAdminController.testRule(saved.ruleId, 5);
        Test.stopTest();

        System.assertEquals(1, saved.conditionCount);
        System.assert(!rules.isEmpty());
        System.assertEquals(1, bundle.conditions.size());
        System.assertEquals(1, preview.matchCount);
    }

    @IsTest
    static void testValidation() {
        try {
            OCXExpansionAdminController.saveRule(
                new OCX_Expansion_Qualification_Rule__c(OCX_Match_Type__c = 'All'),
                new List<OCX_Expansion_Rule_Condition__c>()
            );
            System.assert(false, 'Expected validation failure');
        } catch (AuraHandledException expected) {
            System.assertNotEquals(null, expected, 'Expected validation failure was thrown.');
        }
    }
}
