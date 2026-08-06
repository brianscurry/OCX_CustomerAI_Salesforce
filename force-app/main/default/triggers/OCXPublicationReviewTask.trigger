trigger OCXPublicationReviewTask on OCX_Published_Content__c (after insert, after update) {
    OCXPublicationReviewTaskService.createMissingReviewTasks(Trigger.new);
}