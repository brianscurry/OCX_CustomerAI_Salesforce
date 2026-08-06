trigger OCXReviewTaskRecordType on Task (before insert) {
    Map<String, Schema.RecordTypeInfo> recordTypes =
        Schema.SObjectType.Task
            .getRecordTypeInfosByDeveloperName();

    if (!recordTypes.containsKey('OCX_Report_Review')) {
        return;
    }

    Id reviewRecordTypeId =
        recordTypes
            .get('OCX_Report_Review')
            .getRecordTypeId();

    for (Task taskRecord : Trigger.new) {
        if (
            String.isNotBlank(taskRecord.Description)
            && taskRecord.Description.startsWith(
                'OCX_PUBLICATION_ID='
            )
        ) {
            taskRecord.RecordTypeId =
                reviewRecordTypeId;
        }
    }
}