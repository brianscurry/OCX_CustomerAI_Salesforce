public with sharing class OCXExpansionRuleEngine {
    public class RuleException extends Exception {}

    public class AccountFieldDescriptor {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String dataType;
        @AuraEnabled public List<String> picklistValues = new List<String>();
    }

    public class RulePreview {
        @AuraEnabled public Integer matchCount;
        @AuraEnabled public List<Account> sampleAccounts;
        @AuraEnabled public String generatedWhereClause;
    }

    public class RunSummary {
        @AuraEnabled public Integer matchedCount = 0;
        @AuraEnabled public Integer createdCount = 0;
        @AuraEnabled public Integer updatedCount = 0;
        @AuraEnabled public Integer skippedCount = 0;
    }

    private static final Set<Schema.DisplayType> SUPPORTED_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.String,
        Schema.DisplayType.TextArea,
        Schema.DisplayType.Email,
        Schema.DisplayType.Phone,
        Schema.DisplayType.Url,
        Schema.DisplayType.Picklist,
        Schema.DisplayType.Boolean,
        Schema.DisplayType.Integer,
        Schema.DisplayType.Double,
        Schema.DisplayType.Currency,
        Schema.DisplayType.Percent,
        Schema.DisplayType.Date,
        Schema.DisplayType.DateTime
    };

    @AuraEnabled(cacheable=true)
    public static List<AccountFieldDescriptor> getAccountFields() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
        List<AccountFieldDescriptor> result = new List<AccountFieldDescriptor>();
        for (String apiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult d = fieldMap.get(apiName).getDescribe();
            if (!d.isAccessible() || !d.isFilterable() || !SUPPORTED_TYPES.contains(d.getType())) {
                continue;
            }
            AccountFieldDescriptor row = new AccountFieldDescriptor();
            row.apiName = apiName;
            row.label = d.getLabel();
            row.dataType = String.valueOf(d.getType());
            if (d.getType() == Schema.DisplayType.Picklist) {
                for (Schema.PicklistEntry entry : d.getPicklistValues()) {
                    if (entry.isActive()) row.picklistValues.add(entry.getValue());
                }
            }
            result.add(row);
        }
        result.sort(new FieldDescriptorComparator());
        return result;
    }

    public class FieldDescriptorComparator implements Comparator<AccountFieldDescriptor> {
        public Integer compare(AccountFieldDescriptor left, AccountFieldDescriptor right) {
            return left.label.toLowerCase().compareTo(right.label.toLowerCase());
        }
    }

    @AuraEnabled
    public static RulePreview testRule(Id ruleId, Integer sampleLimit) {
        Integer limitValue = sampleLimit == null ? 10 : Math.max(1, Math.min(sampleLimit, 50));
        OCX_Expansion_Qualification_Rule__c rule = loadRule(ruleId);
        List<OCX_Expansion_Rule_Condition__c> conditions = loadConditions(ruleId);
        String whereClause = buildWhereClause(rule, conditions);

        RulePreview preview = new RulePreview();
        preview.generatedWhereClause = whereClause;
        preview.matchCount = Database.countQuery('SELECT COUNT() FROM Account WHERE ' + whereClause);
        preview.sampleAccounts = Database.query(
            'SELECT Id, Name, OwnerId, OCX_NPS_Class__c, OCX_Propensity__c ' +
            'FROM Account WHERE ' + whereClause + ' ORDER BY Name LIMIT ' + limitValue
        );

        rule.OCX_Last_Test_Count__c = preview.matchCount;
        rule.OCX_Last_Tested_At__c = System.now();
        update rule;
        return preview;
    }

    @AuraEnabled
    public static RunSummary runRule(Id ruleId) {
        OCX_Expansion_Qualification_Rule__c rule = loadRule(ruleId);
        if (!rule.OCX_Active__c) throw new RuleException('The qualification rule must be active before it can run.');

        List<OCX_Expansion_Rule_Condition__c> conditions = loadConditions(ruleId);
        String whereClause = buildWhereClause(rule, conditions);
        List<Account> accounts = Database.query(
            'SELECT Id, Name, OwnerId, OCX_NPS_Class__c, OCX_Propensity__c ' +
            'FROM Account WHERE ' + whereClause + ' ORDER BY Id LIMIT 50000'
        );

        RunSummary summary = new RunSummary();
        summary.matchedCount = accounts.size();
        if (accounts.isEmpty()) {
            rule.OCX_Last_Run_At__c = System.now();
            update rule;
            return summary;
        }

        Set<String> externalKeys = new Set<String>();
        for (Account accountRecord : accounts) externalKeys.add(accountRecord.Id + '::' + rule.Id);

        Map<String, OCX_Expansion_Lead__c> existingByKey = new Map<String, OCX_Expansion_Lead__c>();
        for (OCX_Expansion_Lead__c existing : [
            SELECT Id, OCX_External_Key__c, OCX_Status__c
            FROM OCX_Expansion_Lead__c
            WHERE OCX_External_Key__c IN :externalKeys
        ]) {
            existingByKey.put(existing.OCX_External_Key__c, existing);
        }

        List<OCX_Expansion_Lead__c> toUpsert = new List<OCX_Expansion_Lead__c>();
        Datetime evaluatedAt = System.now();
        for (Account accountRecord : accounts) {
            String key = accountRecord.Id + '::' + rule.Id;
            OCX_Expansion_Lead__c existing = existingByKey.get(key);
            if (existing != null && new Set<String>{'Accepted', 'Converted', 'Rejected'}.contains(existing.OCX_Status__c)) {
                summary.skippedCount++;
                continue;
            }

            OCX_Expansion_Lead__c leadRecord = existing == null
                ? new OCX_Expansion_Lead__c(OCX_External_Key__c = key)
                : existing;
            leadRecord.OCX_Account__c = accountRecord.Id;
            leadRecord.OCX_Qualification_Rule__c = rule.Id;
            leadRecord.OwnerId = accountRecord.OwnerId;
            leadRecord.OCX_Status__c = existing == null ? 'New' : existing.OCX_Status__c;
            leadRecord.OCX_Signal_Type__c = 'Product Expansion';
            leadRecord.OCX_NPS_Class__c = accountRecord.OCX_NPS_Class__c;
            leadRecord.OCX_Propensity__c = accountRecord.OCX_Propensity__c;
            leadRecord.OCX_Recommended_Product__c = rule.OCX_Recommended_Product__c;
            leadRecord.OCX_Estimated_Value__c = rule.OCX_Default_Value__c;
            leadRecord.OCX_Priority__c = priorityLabel(rule.OCX_Priority__c);
            leadRecord.OCX_Rationale__c = 'Matched qualification rule: ' + rule.OCX_Rule_Name__c;
            leadRecord.OCX_Last_Evaluated_At__c = evaluatedAt;
            toUpsert.add(leadRecord);
            if (existing == null) summary.createdCount++; else summary.updatedCount++;
        }

        if (!toUpsert.isEmpty()) upsert toUpsert OCX_External_Key__c;
        rule.OCX_Last_Run_At__c = evaluatedAt;
        update rule;
        return summary;
    }

    private static OCX_Expansion_Qualification_Rule__c loadRule(Id ruleId) {
        if (ruleId == null) throw new RuleException('A qualification rule ID is required.');
        List<OCX_Expansion_Qualification_Rule__c> rows = [
            SELECT Id, OCX_Rule_Name__c, OCX_Active__c, OCX_Match_Type__c,
                   OCX_Priority__c, OCX_Recommended_Product__c, OCX_Default_Value__c,
                   OCX_Last_Test_Count__c, OCX_Last_Tested_At__c, OCX_Last_Run_At__c
            FROM OCX_Expansion_Qualification_Rule__c
            WHERE Id = :ruleId
            LIMIT 1
        ];
        if (rows.isEmpty()) throw new RuleException('Qualification rule was not found.');
        return rows[0];
    }

    private static List<OCX_Expansion_Rule_Condition__c> loadConditions(Id ruleId) {
        List<OCX_Expansion_Rule_Condition__c> rows = [
            SELECT Id, OCX_Sequence__c, OCX_Field_API_Name__c, OCX_Field_Label__c,
                   OCX_Data_Type__c, OCX_Operator__c, OCX_Value__c, OCX_Active__c
            FROM OCX_Expansion_Rule_Condition__c
            WHERE OCX_Rule__c = :ruleId AND OCX_Active__c = true
            ORDER BY OCX_Sequence__c, CreatedDate
        ];
        if (rows.isEmpty()) throw new RuleException('The qualification rule has no active conditions.');
        return rows;
    }

    @TestVisible
    private static String buildWhereClause(
        OCX_Expansion_Qualification_Rule__c rule,
        List<OCX_Expansion_Rule_Condition__c> conditions
    ) {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
        List<String> clauses = new List<String>();
        for (OCX_Expansion_Rule_Condition__c condition : conditions) {
            String fieldName = condition.OCX_Field_API_Name__c == null ? '' : condition.OCX_Field_API_Name__c.trim();
            if (!fieldMap.containsKey(fieldName)) throw new RuleException('Unsupported Account field: ' + fieldName);
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(fieldName).getDescribe();
            if (!fieldDescribe.isAccessible() || !fieldDescribe.isFilterable() || !SUPPORTED_TYPES.contains(fieldDescribe.getType())) {
                throw new RuleException('Account field cannot be used in a rule: ' + fieldName);
            }
            clauses.add(buildCondition(fieldName, fieldDescribe.getType(), condition.OCX_Operator__c, condition.OCX_Value__c));
        }
        String joiner = rule.OCX_Match_Type__c == 'Any' ? ' OR ' : ' AND ';
        return '(' + String.join(clauses, joiner) + ')';
    }

    private static String buildCondition(String fieldName, Schema.DisplayType fieldType, String operatorLabel, String rawValue) {
        String op = operatorLabel == null ? '' : operatorLabel.trim();
        if (op == 'Is Blank') return fieldName + ' = NULL';
        if (op == 'Is Not Blank') return fieldName + ' != NULL';
        if (String.isBlank(rawValue)) throw new RuleException('A comparison value is required for ' + fieldName + '.');

        if (op == 'Contains') {
            assertTextType(fieldType, op);
            return fieldName + ' LIKE \'%' + String.escapeSingleQuotes(rawValue.trim()) + '%\'';
        }
        if (op == 'In') {
            List<String> values = new List<String>();
            for (String part : rawValue.split(',')) {
                if (!String.isBlank(part)) values.add(formatLiteral(fieldType, part.trim()));
            }
            if (values.isEmpty()) throw new RuleException('At least one value is required for IN.');
            return fieldName + ' IN (' + String.join(values, ',') + ')';
        }

        Map<String, String> operators = new Map<String, String>{
            'Equals' => '=',
            'Not Equal' => '!=',
            'Greater Than' => '>',
            'Greater Than or Equal' => '>=',
            'Less Than' => '<',
            'Less Than or Equal' => '<='
        };
        if (!operators.containsKey(op)) throw new RuleException('Unsupported operator: ' + op);
        if (new Set<String>{'Greater Than','Greater Than or Equal','Less Than','Less Than or Equal'}.contains(op)) {
            assertComparableType(fieldType, op);
        }
        return fieldName + ' ' + operators.get(op) + ' ' + formatLiteral(fieldType, rawValue.trim());
    }

    private static String formatLiteral(Schema.DisplayType fieldType, String rawValue) {
        if (fieldType == Schema.DisplayType.Boolean) {
            String normalized = rawValue.toLowerCase();
            if (normalized != 'true' && normalized != 'false') throw new RuleException('Boolean values must be true or false.');
            return normalized;
        }
        if (new Set<Schema.DisplayType>{Schema.DisplayType.Integer, Schema.DisplayType.Double, Schema.DisplayType.Currency, Schema.DisplayType.Percent}.contains(fieldType)) {
            try { Decimal.valueOf(rawValue); } catch (Exception ex) { throw new RuleException('Numeric value is invalid: ' + rawValue); }
            return rawValue;
        }
        if (fieldType == Schema.DisplayType.Date) {
            try { Date.valueOf(rawValue); } catch (Exception ex) { throw new RuleException('Date must use YYYY-MM-DD.'); }
            return rawValue;
        }
        if (fieldType == Schema.DisplayType.DateTime) {
            try { Datetime.valueOf(rawValue.replace('T', ' ')); } catch (Exception ex) { throw new RuleException('Date/time value is invalid.'); }
            return rawValue;
        }
        return '\'' + String.escapeSingleQuotes(rawValue) + '\'';
    }

    private static void assertTextType(Schema.DisplayType fieldType, String op) {
        if (!new Set<Schema.DisplayType>{Schema.DisplayType.String, Schema.DisplayType.TextArea, Schema.DisplayType.Email, Schema.DisplayType.Phone, Schema.DisplayType.Url, Schema.DisplayType.Picklist}.contains(fieldType)) {
            throw new RuleException(op + ' can only be used with text or picklist fields.');
        }
    }

    private static void assertComparableType(Schema.DisplayType fieldType, String op) {
        if (!new Set<Schema.DisplayType>{Schema.DisplayType.Integer, Schema.DisplayType.Double, Schema.DisplayType.Currency, Schema.DisplayType.Percent, Schema.DisplayType.Date, Schema.DisplayType.DateTime}.contains(fieldType)) {
            throw new RuleException(op + ' can only be used with numeric or date fields.');
        }
    }

    private static String priorityLabel(Decimal priorityValue) {
        if (priorityValue == null) return 'Medium';
        if (priorityValue <= 1) return 'High';
        if (priorityValue >= 3) return 'Low';
        return 'Medium';
    }
}
