public without sharing class OCXPublicationReviewTaskService {
    private static final String MARKER_PREFIX =
        'OCX_PUBLICATION_ID=';

    public static void createMissingReviewTasks(
        List<OCX_Published_Content__c> publications
    ) {
        if (publications == null || publications.isEmpty()) {
            return;
        }

        Map<Id, OCX_Published_Content__c> eligibleById =
            new Map<Id, OCX_Published_Content__c>();

        Set<Id> accountIds = new Set<Id>();

        for (
            OCX_Published_Content__c publication :
            publications
        ) {
            if (
                publication.Id != null &&
                publication.OCX_Account__c != null &&
                String.isNotBlank(
                    publication.OCX_Viewer_URL__c
                ) &&
                publication.OCX_Status__c == 'PUBLISHED'
            ) {
                eligibleById.put(
                    publication.Id,
                    publication
                );

                accountIds.add(
                    publication.OCX_Account__c
                );
            }
        }

        if (eligibleById.isEmpty()) {
            return;
        }

        Set<String> publicationIdsWithTasks =
            new Set<String>();

        List<SObject> existingRows =
            Database.queryWithBinds(
                'SELECT Id, Description ' +
                'FROM Task ' +
                'WHERE WhatId IN :accountIds ' +
                'AND Subject LIKE \'Review Report:%\'',
                new Map<String, Object>{
                    'accountIds' => accountIds
                },
                AccessLevel.SYSTEM_MODE
            );

        for (SObject row : existingRows) {
            Task existingTask = (Task) row;

            String existingPublicationId =
                publicationIdFromDescription(
                    existingTask.Description
                );

            if (
                String.isNotBlank(
                    existingPublicationId
                )
            ) {
                publicationIdsWithTasks.add(
                    existingPublicationId
                );
            }
        }

        Map<Id, Account> accountsById =
            new Map<Id, Account>([
                SELECT Id, OwnerId
                FROM Account
                WHERE Id IN :accountIds
            ]);

        String openStatus = firstOpenTaskStatus();
        Datetime dueAt = System.now().addHours(48);

        List<Task> tasksToInsert = new List<Task>();

        for (
            OCX_Published_Content__c publication :
            eligibleById.values()
        ) {
            String publicationId =
                String.valueOf(publication.Id);

            if (
                publicationIdsWithTasks.contains(
                    publicationId
                )
            ) {
                continue;
            }

            Account account =
                accountsById.get(
                    publication.OCX_Account__c
                );

            if (account == null) {
                continue;
            }

            String title =
                String.isBlank(
                    publication.OCX_Title__c
                )
                    ? 'Customer AI Report'
                    : publication.OCX_Title__c.trim();

            String subject =
                'Review Report: ' + title;

            if (subject.length() > 255) {
                subject = subject.left(255);
            }

            Task reviewTask = new Task(
                Subject = subject,
                OwnerId = account.OwnerId,
                WhatId = account.Id,
                ActivityDate = Date.today().addDays(2),
                Priority = 'Normal',
                IsReminderSet = true,
                ReminderDateTime = dueAt,
                Description =
                    MARKER_PREFIX +
                    publicationId +
                    '\n\nOpen this task and choose ' +
                    'Review Report to view the published ' +
                    'Customer AI report.'
            );

            if (String.isNotBlank(openStatus)) {
                reviewTask.Status = openStatus;
            }

            tasksToInsert.add(reviewTask);
        }

        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
        }
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

    private static String firstOpenTaskStatus() {
        List<TaskStatus> statuses = [
            SELECT MasterLabel
            FROM TaskStatus
            WHERE IsClosed = false
            ORDER BY SortOrder ASC
            LIMIT 1
        ];

        return statuses.isEmpty()
            ? null
            : statuses[0].MasterLabel;
    }
}