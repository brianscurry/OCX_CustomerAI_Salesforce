public with sharing class OCXExpansionAdminController {
    public class RuleBundle {
        @AuraEnabled public OCX_Expansion_Qualification_Rule__c rule;
        @AuraEnabled public List<OCX_Expansion_Rule_Condition__c> conditions;
    }

    public class SaveResult {
        @AuraEnabled public Id ruleId;
        @AuraEnabled public Integer conditionCount;
    }

    @AuraEnabled(cacheable=true)
    public static List<OCX_Expansion_Qualification_Rule__c> listRules() {
        return [
            SELECT Id, OCX_Rule_Name__c, OCX_Active__c, OCX_Description__c,
                   OCX_Match_Type__c, OCX_Priority__c, OCX_Recommended_Product__c,
                   OCX_Default_Value__c, OCX_Default_Close_Days__c,
                   OCX_Default_Opportunity_Type__c, OCX_Last_Test_Count__c,
                   OCX_Last_Tested_At__c, OCX_Last_Run_At__c
            FROM OCX_Expansion_Qualification_Rule__c
            ORDER BY OCX_Active__c DESC, OCX_Priority__c ASC NULLS LAST, OCX_Rule_Name__c
        ];
    }

    @AuraEnabled(cacheable=true)
    public static RuleBundle getRule(Id ruleId) {
        RuleBundle bundle = new RuleBundle();
        bundle.rule = [
            SELECT Id, OCX_Rule_Name__c, OCX_Active__c, OCX_Description__c,
                   OCX_Match_Type__c, OCX_Priority__c, OCX_Recommended_Product__c,
                   OCX_Default_Value__c, OCX_Default_Close_Days__c,
                   OCX_Default_Opportunity_Type__c, OCX_Last_Test_Count__c,
                   OCX_Last_Tested_At__c, OCX_Last_Run_At__c
            FROM OCX_Expansion_Qualification_Rule__c
            WHERE Id = :ruleId
            LIMIT 1
        ];
        bundle.conditions = [
            SELECT Id, OCX_Rule__c, OCX_Sequence__c, OCX_Field_API_Name__c,
                   OCX_Field_Label__c, OCX_Data_Type__c, OCX_Operator__c,
                   OCX_Value__c, OCX_Active__c
            FROM OCX_Expansion_Rule_Condition__c
            WHERE OCX_Rule__c = :ruleId
            ORDER BY OCX_Sequence__c ASC
        ];
        return bundle;
    }

    @AuraEnabled(cacheable=true)
    public static List<OCXExpansionRuleEngine.AccountFieldDescriptor> getAccountFields() {
        return OCXExpansionRuleEngine.getAccountFields();
    }

    @AuraEnabled
    public static SaveResult saveRule(
        OCX_Expansion_Qualification_Rule__c ruleRecord,
        List<OCX_Expansion_Rule_Condition__c> conditionRecords
    ) {
        if (ruleRecord == null || String.isBlank(ruleRecord.OCX_Rule_Name__c)) {
            throw new AuraHandledException('Rule Name is required.');
        }
        if (ruleRecord.OCX_Match_Type__c != 'All' && ruleRecord.OCX_Match_Type__c != 'Any') {
            throw new AuraHandledException('Match Type must be All or Any.');
        }

        upsert ruleRecord;

        List<OCX_Expansion_Rule_Condition__c> existing = [
            SELECT Id
            FROM OCX_Expansion_Rule_Condition__c
            WHERE OCX_Rule__c = :ruleRecord.Id
        ];
        if (!existing.isEmpty()) {
            delete existing;
        }

        List<OCX_Expansion_Rule_Condition__c> toInsert = new List<OCX_Expansion_Rule_Condition__c>();
        Integer seq = 1;
        for (OCX_Expansion_Rule_Condition__c row : conditionRecords == null
                ? new List<OCX_Expansion_Rule_Condition__c>()
                : conditionRecords) {
            if (String.isBlank(row.OCX_Field_API_Name__c)) {
                continue;
            }
            row.Id = null;
            row.OCX_Rule__c = ruleRecord.Id;
            row.OCX_Sequence__c = seq++;
            row.OCX_Active__c = true;
            toInsert.add(row);
        }
        if (toInsert.isEmpty()) {
            throw new AuraHandledException('At least one condition is required.');
        }
        insert toInsert;

        SaveResult result = new SaveResult();
        result.ruleId = ruleRecord.Id;
        result.conditionCount = toInsert.size();
        return result;
    }

    @AuraEnabled
    public static OCXExpansionRuleEngine.RulePreview testRule(Id ruleId, Integer sampleLimit) {
        return OCXExpansionRuleEngine.testRule(ruleId, sampleLimit == null ? 10 : sampleLimit);
    }

    @AuraEnabled
    public static OCXExpansionRuleEngine.RunSummary runRule(Id ruleId) {
        return OCXExpansionRuleEngine.runRule(ruleId);
    }
}
