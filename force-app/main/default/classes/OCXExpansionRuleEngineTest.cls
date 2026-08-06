@IsTest
private class OCXExpansionRuleEngineTest {
    @TestSetup
    static void setupData() {
        insert new List<Account>{
            new Account(Name='Promoter Upsell Account', OCX_NPS_Class__c='Promoter', OCX_Propensity__c='Upsell', AnnualRevenue=2000000),
            new Account(Name='Promoter Retain Account', OCX_NPS_Class__c='Promoter', OCX_Propensity__c='Retain', AnnualRevenue=3000000),
            new Account(Name='Detractor Upsell Account', OCX_NPS_Class__c='Detractor', OCX_Propensity__c='Upsell', AnnualRevenue=4000000)
        };
    }

    private static OCX_Expansion_Qualification_Rule__c makeRule(Boolean active, String matchType) {
        OCX_Expansion_Qualification_Rule__c rule = new OCX_Expansion_Qualification_Rule__c(
            OCX_Rule_Name__c='Promoter Expansion Candidates',
            OCX_Active__c=active,
            OCX_Match_Type__c=matchType,
            OCX_Priority__c=1,
            OCX_Recommended_Product__c='Analytics Expansion',
            OCX_Default_Value__c=75000
        );
        insert rule;
        return rule;
    }

    private static void addCondition(Id ruleId, Integer sequence, String fieldName, String dataType, String op, String value) {
        insert new OCX_Expansion_Rule_Condition__c(
            OCX_Rule__c=ruleId,
            OCX_Sequence__c=sequence,
            OCX_Field_API_Name__c=fieldName,
            OCX_Field_Label__c=fieldName,
            OCX_Data_Type__c=dataType,
            OCX_Operator__c=op,
            OCX_Value__c=value,
            OCX_Active__c=true
        );
    }

    @IsTest
    static void testPreviewAndRunAreIdempotent() {
        OCX_Expansion_Qualification_Rule__c rule = makeRule(true, 'All');
        addCondition(rule.Id, 1, 'OCX_NPS_Class__c', 'String', 'Equals', 'Promoter');
        addCondition(rule.Id, 2, 'OCX_Propensity__c', 'String', 'Equals', 'Upsell');

        Test.startTest();
        OCXExpansionRuleEngine.RulePreview preview = OCXExpansionRuleEngine.testRule(rule.Id, 10);
        OCXExpansionRuleEngine.RunSummary firstRun = OCXExpansionRuleEngine.runRule(rule.Id);
        OCXExpansionRuleEngine.RunSummary secondRun = OCXExpansionRuleEngine.runRule(rule.Id);
        Test.stopTest();

        System.assertEquals(1, preview.matchCount);
        System.assertEquals(1, firstRun.createdCount);
        System.assertEquals(0, secondRun.createdCount);
        System.assertEquals(1, secondRun.updatedCount);

        List<OCX_Expansion_Lead__c> leads = [
            SELECT Id, OCX_External_Key__c, OCX_Status__c, OCX_Account__r.Name,
                   OCX_NPS_Class__c, OCX_Propensity__c
            FROM OCX_Expansion_Lead__c
        ];
        System.assertEquals(1, leads.size());
        System.assertEquals('Promoter Upsell Account', leads[0].OCX_Account__r.Name);
        System.assertEquals('Promoter', leads[0].OCX_NPS_Class__c);
        System.assertEquals('Upsell', leads[0].OCX_Propensity__c);
        System.assert(leads[0].OCX_External_Key__c.contains('::'));
    }

    @IsTest
    static void testAnyLogic() {
        OCX_Expansion_Qualification_Rule__c rule = makeRule(true, 'Any');
        addCondition(rule.Id, 1, 'OCX_NPS_Class__c', 'String', 'Equals', 'Promoter');
        addCondition(rule.Id, 2, 'OCX_Propensity__c', 'String', 'Equals', 'Upsell');

        Test.startTest();
        OCXExpansionRuleEngine.RulePreview preview = OCXExpansionRuleEngine.testRule(rule.Id, 10);
        Test.stopTest();
        System.assertEquals(3, preview.matchCount);
    }

    @IsTest
    static void testInactiveRuleCannotRun() {
        OCX_Expansion_Qualification_Rule__c rule = makeRule(false, 'All');
        addCondition(rule.Id, 1, 'OCX_NPS_Class__c', 'String', 'Equals', 'Promoter');
        try {
            OCXExpansionRuleEngine.runRule(rule.Id);
            System.assert(false, 'Expected RuleException');
        } catch (OCXExpansionRuleEngine.RuleException ex) {
            System.assert(ex.getMessage().contains('active'));
        }
    }

    @IsTest
    static void testUnsupportedFieldRejected() {
        OCX_Expansion_Qualification_Rule__c rule = makeRule(true, 'All');
        addCondition(rule.Id, 1, 'Does_Not_Exist__c', 'String', 'Equals', 'Anything');
        try {
            OCXExpansionRuleEngine.testRule(rule.Id, 10);
            System.assert(false, 'Expected RuleException');
        } catch (OCXExpansionRuleEngine.RuleException ex) {
            System.assert(ex.getMessage().contains('Unsupported Account field'));
        }
    }

    @IsTest
    static void testAcceptedLeadIsNotOverwritten() {
        OCX_Expansion_Qualification_Rule__c rule = makeRule(true, 'All');
        addCondition(rule.Id, 1, 'OCX_NPS_Class__c', 'String', 'Equals', 'Promoter');
        addCondition(rule.Id, 2, 'OCX_Propensity__c', 'String', 'Equals', 'Upsell');
        Account accountRecord = [SELECT Id FROM Account WHERE Name='Promoter Upsell Account' LIMIT 1];
        insert new OCX_Expansion_Lead__c(
            OCX_Account__c=accountRecord.Id,
            OCX_Qualification_Rule__c=rule.Id,
            OCX_External_Key__c=accountRecord.Id + '::' + rule.Id,
            OCX_Status__c='Accepted'
        );

        Test.startTest();
        OCXExpansionRuleEngine.RunSummary summary = OCXExpansionRuleEngine.runRule(rule.Id);
        Test.stopTest();
        System.assertEquals(1, summary.skippedCount);
        System.assertEquals(0, summary.updatedCount);
    }

    @IsTest
    static void testFieldDescribeReturnsFields() {
        Test.startTest();
        List<OCXExpansionRuleEngine.AccountFieldDescriptor> fields = OCXExpansionRuleEngine.getAccountFields();
        Test.stopTest();
        System.assert(!fields.isEmpty());
        Boolean foundPropensity = false;
        for (OCXExpansionRuleEngine.AccountFieldDescriptor fieldRow : fields) {
            if (fieldRow.apiName == 'OCX_Propensity__c') foundPropensity = true;
        }
        System.assert(foundPropensity);
    }
}
