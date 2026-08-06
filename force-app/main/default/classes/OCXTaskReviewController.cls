public with sharing class OCXTaskReviewController {
    private static final String MARKER_PREFIX =
        'OCX_PUBLICATION_ID=';

    public class ReviewContext {
        @AuraEnabled public String title;
        @AuraEnabled public String viewerUrl;
    }

    @AuraEnabled(cacheable=true)
    public static ReviewContext getReviewContext(
        Id taskId
    ) {
        if (taskId == null) {
            throw new AuraHandledException(
                'A Task ID is required.'
            );
        }

        Task reviewTask = [
            SELECT Id, Description
            FROM Task
            WHERE Id = :taskId
            LIMIT 1
        ];

        String publicationIdText =
            publicationIdFromDescription(
                reviewTask.Description
            );

        if (String.isBlank(publicationIdText)) {
            throw new AuraHandledException(
                'This task is not linked to an ' +
                'OCX publication.'
            );
        }

        Id publicationId;

        try {
            publicationId =
                Id.valueOf(publicationIdText);
        } catch (Exception exceptionValue) {
            throw new AuraHandledException(
                'The linked OCX publication ID ' +
                'is invalid.'
            );
        }

        OCX_Published_Content__c publication = [
            SELECT Id,
                   OCX_Title__c,
                   OCX_Viewer_URL__c
            FROM OCX_Published_Content__c
            WHERE Id = :publicationId
            LIMIT 1
        ];

        if (
            String.isBlank(
                publication.OCX_Viewer_URL__c
            )
        ) {
            throw new AuraHandledException(
                'The linked publication does not ' +
                'have a viewer URL.'
            );
        }

        ReviewContext contextValue =
            new ReviewContext();

        contextValue.title =
            String.isBlank(
                publication.OCX_Title__c
            )
                ? 'Customer AI Report'
                : publication.OCX_Title__c;

        contextValue.viewerUrl =
            publication.OCX_Viewer_URL__c;

        return contextValue;
    }

    @AuraEnabled
    public static void completeTask(Id taskId) {
        if (taskId == null) {
            throw new AuraHandledException(
                'A Task ID is required.'
            );
        }

        Task reviewTask = [
            SELECT Id, IsClosed
            FROM Task
            WHERE Id = :taskId
            LIMIT 1
            FOR UPDATE
        ];

        if (reviewTask.IsClosed) {
            return;
        }

        List<TaskStatus> closedStatuses = [
            SELECT MasterLabel
            FROM TaskStatus
            WHERE IsClosed = true
            ORDER BY SortOrder ASC
            LIMIT 1
        ];

        if (closedStatuses.isEmpty()) {
            throw new AuraHandledException(
                'No completed Task status is ' +
                'configured in this org.'
            );
        }

        Task taskToComplete = new Task(
            Id = reviewTask.Id,
            Status = closedStatuses[0].MasterLabel
        );

        update as system taskToComplete;
    }

    private static String publicationIdFromDescription(
        String description
    ) {
        if (String.isBlank(description)) {
            return null;
        }

        for (String line : description.split('\n')) {
            String trimmedLine = line.trim();

            if (
                trimmedLine.startsWith(
                    MARKER_PREFIX
                )
            ) {
                return trimmedLine
                    .substring(
                        MARKER_PREFIX.length()
                    )
                    .trim();
            }
        }

        return null;
    }
}