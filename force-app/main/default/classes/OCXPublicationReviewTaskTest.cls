@IsTest
private class OCXPublicationReviewTaskTest {
    @IsTest
    static void createsOneReviewTaskAndCompletesIt() {
        Account accountRecord =
            new Account(
                Name = 'OCX Review Test'
            );

        insert accountRecord;

        OCX_Published_Content__c publication =
            new OCX_Published_Content__c(
                OCX_Account__c =
                    accountRecord.Id,
                OCX_Title__c =
                    'Retention Analysis',
                OCX_Content_Format__c =
                    'INTERACTIVE_HTML',
                OCX_Status__c =
                    'PUBLISHED',
                OCX_Viewer_URL__c =
                    'https://ocxagentpreview2.lovable.app' +
                    '/viewer/test?ar=16/9' +
                    '&layout=presentation',
                OCX_Publication_Key__c =
                    'review-test-one'
            );

        Test.startTest();
        insert publication;
        Test.stopTest();

        Task reviewTask = [
            SELECT Id,
                   Subject,
                   OwnerId,
                   WhatId,
                   ActivityDate,
                   ReminderDateTime,
                   Description,
                   IsClosed
            FROM Task
            WHERE WhatId = :accountRecord.Id
              AND Subject =
                  'Review Report: Retention Analysis'
            LIMIT 1
        ];

        System.assertEquals(
            accountRecord.Id,
            reviewTask.WhatId
        );

        System.assertEquals(
            UserInfo.getUserId(),
            reviewTask.OwnerId
        );

        System.assertEquals(
            Date.today().addDays(2),
            reviewTask.ActivityDate
        );

        System.assertNotEquals(
            null,
            reviewTask.ReminderDateTime
        );

        System.assert(
            reviewTask.Description.contains(
                'OCX_PUBLICATION_ID=' +
                publication.Id
            )
        );

        System.assertEquals(
            false,
            reviewTask.IsClosed
        );

        OCXTaskReviewController.ReviewContext contextValue =
            OCXTaskReviewController.getReviewContext(reviewTask.Id);

        System.assertEquals(
            'Retention Analysis',
            contextValue.title
        );

        System.assert(
            contextValue.viewerUrl.contains(
                '/viewer/test'
            )
        );

        OCXTaskReviewController.completeTask(
            reviewTask.Id
        );

        reviewTask = [
            SELECT IsClosed
            FROM Task
            WHERE Id = :reviewTask.Id
        ];

        System.assertEquals(
            true,
            reviewTask.IsClosed
        );

        publication.OCX_Title__c =
            'Retention Analysis Updated';

        update publication;

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Task
                WHERE WhatId = :accountRecord.Id
                  AND Subject LIKE 'Review Report:%'
            ]
        );
    }

    @IsTest
    static void createsTaskWhenViewerUrlArrivesLater() {
        Account accountRecord =
            new Account(
                Name = 'OCX Delayed Viewer Test'
            );

        insert accountRecord;

        OCX_Published_Content__c publication =
            new OCX_Published_Content__c(
                OCX_Account__c =
                    accountRecord.Id,
                OCX_Title__c =
                    'Delayed Viewer Report',
                OCX_Content_Format__c =
                    'INTERACTIVE_HTML',
                OCX_Status__c =
                    'PUBLISHED',
                OCX_Publication_Key__c =
                    'review-test-two'
            );

        insert publication;

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Task
                WHERE WhatId = :accountRecord.Id
                  AND Subject LIKE 'Review Report:%'
            ]
        );

        Test.startTest();

        publication.OCX_Viewer_URL__c =
            'https://ocxagentpreview2.lovable.app' +
            '/viewer/delayed?ar=1/1.29' +
            '&layout=document';

        update publication;

        Test.stopTest();

        Task reviewTask = [
            SELECT Id, Description
            FROM Task
            WHERE WhatId = :accountRecord.Id
              AND Subject =
                  'Review Report: Delayed Viewer Report'
            LIMIT 1
        ];

        System.assert(
            reviewTask.Description.contains(
                'OCX_PUBLICATION_ID=' +
                publication.Id
            )
        );
    }
}