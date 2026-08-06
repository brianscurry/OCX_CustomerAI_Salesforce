/**
 * Read/act surface for Customer AI action plans that were published into Salesforce
 * as Task records.
 *
 * Contract with Customer AI (publish-to-salesforce edge function):
 *  - Every synced action is a Task with RecordType.DeveloperName = 'OCX_Action'.
 *  - OCX_Action_Key__c is the globally unique upsert key. Never write it from Salesforce.
 *  - OCX_Source_State__c is 'ACTIVE' or 'SUPERSEDED'. Action lists MUST show ACTIVE only.
 *  - OCX_Action_Type__c is 'CTA' or 'Task'. Tasks hang off a CTA via OCX_Parent_Action_ID__c.
 *  - Execution fields (Status, OwnerId, ActivityDate, Description) are Salesforce-owned and
 *    are preserved across republishes. Everything else is overwritten by Customer AI.
 */
public with sharing class OCX_ActionListController {
    @TestVisible
    private static final String ACTION_RECORD_TYPE = 'OCX_Action';
    @TestVisible
    private static final String STATE_ACTIVE = 'ACTIVE';

    public class ActionItem {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String actionId;
        @AuraEnabled public String parentActionId;
        @AuraEnabled public String actionType;
        @AuraEnabled public String subject;
        @AuraEnabled public String description;
        @AuraEnabled public String status;
        @AuraEnabled public String priority;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public Boolean isComplete;
        @AuraEnabled public List<ActionItem> children;
    }

    public class ActionPlan {
        @AuraEnabled public List<ActionItem> ctas = new List<ActionItem>();
        @AuraEnabled public List<ActionItem> orphans = new List<ActionItem>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer openCount = 0;
        @AuraEnabled public String sourceResourceId;
        @AuraEnabled public Decimal sourceVersion;
    }

    /**
     * Returns the ACTIVE action plan for a record.
     * Supports placement on an Account record page (matches Tasks whose WhatId/AccountId is the
     * Account) and on an OCX_Published_Content__c record page (matches the lookup).
     */
    @TestVisible
    private static final List<String> REQUIRED_TASK_FIELDS = new List<String>{
        'Subject', 'Description', 'Status', 'Priority', 'ActivityDate', 'OwnerId',
        'AccountId', 'RecordTypeId', 'CreatedDate',
        'OCX_Action_ID__c', 'OCX_Parent_Action_ID__c', 'OCX_Action_Type__c',
        'OCX_Sequence__c', 'OCX_Source_State__c', 'OCX_Source_Resource_ID__c',
        'OCX_Source_Version__c', 'OCX_Published_Content__c'
    };

    /**
     * True only when the running user can read Task and every field this controller
     * selects, filters, or orders by. Used to degrade to an empty plan instead of
     * throwing when a user lacks the OCX Action Plan permission set.
     */
    @TestVisible
    private static Boolean hasRequiredAccess() {
        if (!Schema.SObjectType.Task.isAccessible()) {
            return false;
        }
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Task.fields.getMap();
        for (String fieldName : REQUIRED_TASK_FIELDS) {
            Schema.SObjectField f = fields.get(fieldName);
            if (f == null || !f.getDescribe().isAccessible()) {
                return false;
            }
        }
        return true;
    }

    @AuraEnabled(cacheable=true)
    public static ActionPlan getActions(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('A record Id is required.');
        }
        if (!hasRequiredAccess()) {
            return new ActionPlan();
        }


        String prefix = String.valueOf(recordId).substring(0, 3);
        Boolean isAccount = prefix == Account.SObjectType.getDescribe().getKeyPrefix();

        List<Task> rows;
        if (isAccount) {
            rows = [
                SELECT Id, Subject, Description, Status, Priority, ActivityDate, OwnerId, Owner.Name,
                       OCX_Action_ID__c, OCX_Parent_Action_ID__c, OCX_Action_Type__c, OCX_Sequence__c,
                       OCX_Source_Resource_ID__c, OCX_Source_Version__c
                FROM Task
                WHERE RecordType.DeveloperName = :ACTION_RECORD_TYPE
                  AND OCX_Source_State__c = :STATE_ACTIVE
                  AND AccountId = :recordId
                ORDER BY OCX_Sequence__c NULLS LAST, CreatedDate ASC
                LIMIT 2000
            ];
        } else {
            rows = [
                SELECT Id, Subject, Description, Status, Priority, ActivityDate, OwnerId, Owner.Name,
                       OCX_Action_ID__c, OCX_Parent_Action_ID__c, OCX_Action_Type__c, OCX_Sequence__c,
                       OCX_Source_Resource_ID__c, OCX_Source_Version__c
                FROM Task
                WHERE RecordType.DeveloperName = :ACTION_RECORD_TYPE
                  AND OCX_Source_State__c = :STATE_ACTIVE
                  AND OCX_Published_Content__c = :recordId
                ORDER BY OCX_Sequence__c NULLS LAST, CreatedDate ASC
                LIMIT 2000
            ];
        }

        return buildPlan(rows);
    }

    @TestVisible
    private static ActionPlan buildPlan(List<Task> rows) {
        ActionPlan plan = new ActionPlan();
        Map<String, ActionItem> ctaByActionId = new Map<String, ActionItem>();
        List<ActionItem> children = new List<ActionItem>();

        for (Task t : rows) {
            ActionItem item = toItem(t);
            plan.totalCount++;
            if (!item.isComplete) {
                plan.openCount++;
            }
            if (plan.sourceResourceId == null) {
                plan.sourceResourceId = t.OCX_Source_Resource_ID__c;
                plan.sourceVersion = t.OCX_Source_Version__c;
            }
            if (item.actionType == 'CTA') {
                ctaByActionId.put(item.actionId, item);
                plan.ctas.add(item);
            } else {
                children.add(item);
            }
        }

        for (ActionItem child : children) {
            ActionItem parent = child.parentActionId == null ? null : ctaByActionId.get(child.parentActionId);
            if (parent == null) {
                plan.orphans.add(child);
            } else {
                parent.children.add(child);
            }
        }

        return plan;
    }

    private static ActionItem toItem(Task t) {
        ActionItem item = new ActionItem();
        item.recordId = t.Id;
        item.actionId = t.OCX_Action_ID__c;
        item.parentActionId = t.OCX_Parent_Action_ID__c;
        item.actionType = t.OCX_Action_Type__c == 'CTA' ? 'CTA' : 'Task';
        item.subject = t.Subject;
        item.description = t.Description;
        item.status = t.Status;
        item.priority = t.Priority;
        item.dueDate = t.ActivityDate;
        item.ownerId = t.OwnerId;
        item.ownerName = t.Owner != null ? t.Owner.Name : null;
        item.sequence = t.OCX_Sequence__c;
        item.isComplete = t.Status == 'Completed';
        item.children = new List<ActionItem>();
        return item;
    }

    /**
     * Marks an action complete. Status is a Salesforce-owned execution field, so Customer AI
     * will not overwrite it on the next publish.
     */
    @AuraEnabled
    public static Id completeAction(Id taskId) {
        if (taskId == null) {
            throw new AuraHandledException('A task Id is required.');
        }
        if (!Schema.SObjectType.Task.fields.Status.isUpdateable()) {
            throw new AuraHandledException('You do not have permission to update this task.');
        }
        List<Task> found = [
            SELECT Id, Status
            FROM Task
            WHERE Id = :taskId
              AND RecordType.DeveloperName = :ACTION_RECORD_TYPE
            LIMIT 1
        ];
        if (found.isEmpty()) {
            throw new AuraHandledException('That task is not a Customer AI action.');
        }
        found[0].Status = 'Completed';
        update found;
        return found[0].Id;
    }
}