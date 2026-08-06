@IsTest
private class OCX_CtaOnlyTaskServiceTest {
    private static Id actionRecordTypeId() {
        return Schema.SObjectType.Task
            .getRecordTypeInfosByDeveloperName()
            .get('OCX_Action')
            .getRecordTypeId();
    }

    private static Task makeAction(
        String subject,
        String actionKey,
        String actionType,
        String parentKey,
        Decimal sequence,
        String resourceId,
        Id accountId
    ) {
        return new Task(
            Subject = subject,
            Description = subject + ' details.',
            WhatId = accountId,
            OwnerId = UserInfo.getUserId(),
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(30),
            RecordTypeId = actionRecordTypeId(),
            OCX_Action_Key__c = actionKey,
            OCX_Action_Type__c = actionType,
            OCX_Parent_Action_Key__c = parentKey,
            OCX_Sequence__c = sequence,
            OCX_Source_Resource_ID__c = resourceId,
            OCX_Source_State__c = 'ACTIVE'
        );
    }

    @IsTest
    static void compactsNestedTasksIntoCtaDescription() {
        Account accountRecord = new Account(Name = 'OCX CTA Test');
        insert accountRecord;

        String resourceId = 'resource-cta-test';

        Task cta = makeAction(
            'Improve Customer Adoption',
            'cta-key-001',
            'CTA',
            null,
            1,
            resourceId,
            accountRecord.Id
        );

        cta.Description = 'CTA summary.';
        cta.Priority = 'High';
        cta.ActivityDate = Date.today().addDays(90);

        Task childOne = makeAction(
            'Conduct usage review',
            'child-key-001',
            'Task',
            'cta-key-001',
            1,
            resourceId,
            accountRecord.Id
        );

        childOne.Description = 'Review usage and identify gaps.';

        Task childTwo = makeAction(
            'Deliver enablement workshop',
            'child-key-002',
            'Task',
            'cta-key-001',
            2,
            resourceId,
            accountRecord.Id
        );

        childTwo.Description = 'Run a guided enablement session.';

        Test.startTest();
        insert new List<Task>{ cta, childTwo, childOne };
        Test.stopTest();

        Task savedCta = [
            SELECT
                Description,
                Status,
                OwnerId,
                Priority,
                ActivityDate
            FROM Task
            WHERE OCX_Action_Key__c = 'cta-key-001'
            LIMIT 1
        ];

        System.assertEquals('Not Started', savedCta.Status);
        System.assertEquals(UserInfo.getUserId(), savedCta.OwnerId);
        System.assertEquals('High', savedCta.Priority);
        System.assertEquals(
            Date.today().addDays(90),
            savedCta.ActivityDate
        );

        System.assert(savedCta.Description.contains('CTA summary.'));
        System.assert(
            savedCta.Description.contains('1. Conduct usage review')
        );
        System.assert(
            savedCta.Description.contains(
                '2. Deliver enablement workshop'
            )
        );
        System.assert(
            savedCta.Description.contains(
                'Review usage and identify gaps.'
            )
        );

        List<Task> children = [
            SELECT WhatId, OCX_Source_State__c
            FROM Task
            WHERE OCX_Parent_Action_Key__c = 'cta-key-001'
        ];

        System.assertEquals(2, children.size());

        for (Task child : children) {
            System.assertEquals(null, child.WhatId);
            System.assertEquals(
                'SUPERSEDED',
                child.OCX_Source_State__c
            );
        }

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Task
                WHERE WhatId = :accountRecord.Id
                  AND OCX_Source_Resource_ID__c = :resourceId
            ]
        );
    }

    @IsTest
    static void coversServiceEdgeCases() {
        System.assertEquals(
            '',
            OCX_CtaOnlyTaskService.removeGeneratedSection(null)
        );

        System.assertEquals(
            'Plain description',
            OCX_CtaOnlyTaskService.removeGeneratedSection(
                'Plain description'
            )
        );

        System.assertEquals(
            'Original',
            OCX_CtaOnlyTaskService.removeGeneratedSection(
                'Original\n\n' +
                '----- OCX WORKBOOK TASKS -----\n' +
                'old generated text'
            )
        );

        System.assertEquals(
            'Original',
            OCX_CtaOnlyTaskService.removeGeneratedSection(
                'Original\n\n' +
                '----- OCX WORKBOOK TASKS -----\n' +
                'old generated text\n' +
                '----- END OCX WORKBOOK TASKS -----'
            )
        );

        new OCX_CtaOnlyTaskService(
            new Set<String>()
        ).execute(null);

        new OCX_CtaOnlyTaskService(null).execute(null);
    }

    @IsTest
    static void coversHandlerPaths() {
        OCX_CtaOnlyTaskHandler.queued = false;
        OCX_CtaOnlyTaskHandler.handle(null, null);

        OCX_CtaOnlyTaskHandler.queued = false;
        OCX_CtaOnlyTaskHandler.handle(new List<Task>(), null);

        Task unrelated = new Task(
            Subject = 'Unrelated',
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today()
        );

        OCX_CtaOnlyTaskHandler.queued = false;
        Integer jobsBefore = Limits.getQueueableJobs();

        OCX_CtaOnlyTaskHandler.handle(
            new List<Task>{ unrelated },
            null
        );

        System.assertEquals(jobsBefore, Limits.getQueueableJobs());

        Account accountRecord = new Account(Name = 'Handler Test');
        insert accountRecord;

        Task currentRecord = makeAction(
            'Handler CTA',
            'handler-cta-key',
            'CTA',
            null,
            1,
            'handler-resource',
            accountRecord.Id
        );

        insert currentRecord;

        Task oldRecord = currentRecord.clone(
            true,
            true,
            false,
            false
        );

        currentRecord.Description = 'Description-only change';

        System.assertEquals(
            false,
            OCX_CtaOnlyTaskHandler.taxonomyChanged(
                currentRecord,
                oldRecord
            )
        );

        currentRecord.Subject = 'Changed subject';

        System.assertEquals(
            true,
            OCX_CtaOnlyTaskHandler.taxonomyChanged(
                currentRecord,
                oldRecord
            )
        );
    }
}