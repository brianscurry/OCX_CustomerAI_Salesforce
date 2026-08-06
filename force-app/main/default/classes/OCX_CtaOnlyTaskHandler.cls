public class OCX_CtaOnlyTaskHandler {
    @TestVisible
    private static Boolean queued = false;

    public static void handle(
        List<Task> currentRecords,
        Map<Id, Task> oldRecords
    ) {
        if (queued || currentRecords == null || currentRecords.isEmpty()) {
            return;
        }

        Schema.RecordTypeInfo recordTypeInfo =
            Schema.SObjectType.Task
                .getRecordTypeInfosByDeveloperName()
                .get('OCX_Action');

        if (recordTypeInfo == null) {
            return;
        }

        Id actionRecordTypeId = recordTypeInfo.getRecordTypeId();
        Set<String> resourceIds = new Set<String>();

        for (Task currentRecord : currentRecords) {
            if (
                currentRecord.RecordTypeId != actionRecordTypeId ||
                currentRecord.OCX_Source_State__c != 'ACTIVE' ||
                String.isBlank(currentRecord.OCX_Action_Key__c) ||
                String.isBlank(currentRecord.OCX_Source_Resource_ID__c)
            ) {
                continue;
            }

            if (
                oldRecords != null &&
                oldRecords.containsKey(currentRecord.Id) &&
                !taxonomyChanged(
                    currentRecord,
                    oldRecords.get(currentRecord.Id)
                )
            ) {
                continue;
            }

            resourceIds.add(currentRecord.OCX_Source_Resource_ID__c);
        }

        if (resourceIds.isEmpty()) {
            return;
        }

        queued = true;
        System.enqueueJob(new OCX_CtaOnlyTaskService(resourceIds));
    }

    @TestVisible
    private static Boolean taxonomyChanged(
        Task currentRecord,
        Task oldRecord
    ) {
        /*
         * Description is excluded deliberately. The service updates the
         * CTA Description itself and that update must not enqueue another job.
         */
        return
            currentRecord.Subject != oldRecord.Subject ||
            currentRecord.OCX_Action_Key__c !=
                oldRecord.OCX_Action_Key__c ||
            currentRecord.OCX_Action_Type__c !=
                oldRecord.OCX_Action_Type__c ||
            currentRecord.OCX_Parent_Action_Key__c !=
                oldRecord.OCX_Parent_Action_Key__c ||
            currentRecord.OCX_Sequence__c !=
                oldRecord.OCX_Sequence__c ||
            currentRecord.OCX_Source_Resource_ID__c !=
                oldRecord.OCX_Source_Resource_ID__c ||
            currentRecord.OCX_Source_State__c !=
                oldRecord.OCX_Source_State__c;
    }
}