@isTest
private class OCX_ActionListControllerTest {
    private static Id actionRecordTypeId() {
        return Schema.SObjectType.Task.getRecordTypeInfosByDeveloperName()
            .get('OCX_Action')
            .getRecordTypeId();
    }

    /**
     * Creates a Standard User and grants the OCX Action Plan User permission set.
     * Setup DML (User + PermissionSetAssignment) is isolated in its own System.runAs block so it
     * can be mixed with the Account/Task data DML the tests seed afterwards.
     */
    private static User makeAuthorizedUser(String aliasSeed) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = aliasSeed,
            Email = aliasSeed + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Tester',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = aliasSeed + '.' + DateTime.now().getTime() + '@example.com.ocxtest'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            PermissionSet ps = [
                SELECT Id
                FROM PermissionSet
                WHERE Name = 'OCX_Action_Plan_User'
                LIMIT 1
            ];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    private static User makeMinimumAccessUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'ocxmin',
            Email = 'ocx.min@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Minimal',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'ocx.min.' + DateTime.now().getTime() + '@example.com.ocxtest'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Account makeAccount() {
        Account a = new Account(Name = 'Daltonville Health', OCX_Account_ID__c = 'ACC-DALTONVILLE');
        insert a;
        return a;
    }

    private static Task makeAction(
        Account a,
        String actionId,
        String parentActionId,
        String type,
        Decimal seq,
        String state,
        String status
    ) {
        return new Task(
            RecordTypeId = actionRecordTypeId(),
            WhatId = a.Id,
            Subject = type + ' ' + actionId,
            Status = status,
            Priority = 'Normal',
            OCX_Action_Key__c = 'key-' + actionId,
            OCX_Action_ID__c = actionId,
            OCX_Parent_Action_ID__c = parentActionId,
            OCX_Action_Type__c = type,
            OCX_Sequence__c = seq,
            OCX_Source_State__c = state,
            OCX_Source_Resource_ID__c = 'res-1',
            OCX_Source_Version__c = 3
        );
    }

    @isTest
    static void returnsActiveActionsGroupedByCta() {
        // Seed in the default test context: the OCX_Action record type must be writable.
        Account a = makeAccount();
        List<Task> rows = new List<Task>{
            makeAction(a, 'cta-1', null, 'CTA', 1, 'ACTIVE', 'Not Started'),
            makeAction(a, 'task-1b', 'cta-1', 'Task', 3, 'ACTIVE', 'Not Started'),
            makeAction(a, 'task-1a', 'cta-1', 'Task', 2, 'ACTIVE', 'Completed'),
            makeAction(a, 'cta-2', null, 'CTA', 4, 'ACTIVE', 'Not Started')
        };
        insert rows;

        Test.startTest();
        OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);
        Test.stopTest();

        System.assertEquals(4, plan.totalCount, 'all active actions counted');
        System.assertEquals(3, plan.openCount, 'completed action excluded from open count');
        System.assertEquals(2, plan.ctas.size(), 'two CTAs');
        System.assertEquals(0, plan.orphans.size(), 'no orphans');
        System.assertEquals(2, plan.ctas[0].children.size(), 'children nested under their CTA');
        System.assertEquals('res-1', plan.sourceResourceId);
        System.assertEquals(3, plan.sourceVersion);
    }

    @isTest
    static void authorizedActionPlanUserSeesActivePlan() {
        User authorized = makeAuthorizedUser('ocxauth');

        Account a = makeAccount();
        insert new List<Task>{
            makeAction(a, 'cta-1', null, 'CTA', 1, 'ACTIVE', 'Not Started'),
            makeAction(a, 'task-1a', 'cta-1', 'Task', 2, 'ACTIVE', 'Not Started')
        };

        Test.startTest();
        System.runAs(authorized) {
            OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);
            System.assertNotEquals(null, plan, 'permissioned user gets a plan');
        }
        Test.stopTest();
    }

    @isTest
    static void ordersBySequence() {
        Account a = makeAccount();
        insert new List<Task>{
            makeAction(a, 'cta-b', null, 'CTA', 20, 'ACTIVE', 'Not Started'),
            makeAction(a, 'cta-a', null, 'CTA', 10, 'ACTIVE', 'Not Started')
        };

        OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);

        System.assertEquals('cta-a', plan.ctas[0].actionId, 'lowest sequence first');
        System.assertEquals('cta-b', plan.ctas[1].actionId);
    }

    @isTest
    static void excludesSupersededActions() {
        Account a = makeAccount();
        insert new List<Task>{
            makeAction(a, 'cta-live', null, 'CTA', 1, 'ACTIVE', 'Not Started'),
            makeAction(a, 'cta-dead', null, 'CTA', 2, 'SUPERSEDED', 'Not Started')
        };

        OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);

        System.assertEquals(1, plan.totalCount, 'superseded action is hidden');
        System.assertEquals('cta-live', plan.ctas[0].actionId);
    }

    @isTest
    static void excludesNonActionTasks() {
        Account a = makeAccount();
        insert new Task(WhatId = a.Id, Subject = 'Plain follow up', Status = 'Not Started');

        OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);

        System.assertEquals(0, plan.totalCount, 'tasks without the OCX Action record type are ignored');
    }

    @isTest
    static void childWithMissingParentBecomesOrphan() {
        Account a = makeAccount();
        insert new List<Task>{
            makeAction(a, 'task-lost', 'cta-gone', 'Task', 1, 'ACTIVE', 'Not Started')
        };

        OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);

        System.assertEquals(0, plan.ctas.size());
        System.assertEquals(1, plan.orphans.size(), 'child with an unknown parent is surfaced, never dropped');
    }

    @isTest
    static void completeActionSetsStatus() {
        Account a = makeAccount();
        Task t = makeAction(a, 'cta-1', null, 'CTA', 1, 'ACTIVE', 'Not Started');
        insert t;

        Test.startTest();
        Id updatedId = OCX_ActionListController.completeAction(t.Id);
        Test.stopTest();

        Task reloaded = [SELECT Status FROM Task WHERE Id = :updatedId];
        System.assertEquals('Completed', reloaded.Status);
    }

    @isTest
    static void completeActionHandlesTaskNormalizedByAutomation() {
        Account a = makeAccount();

        Task taskRecord = new Task(
            WhatId = a.Id,
            Subject = 'Plain',
            Status = 'Not Started'
        );
        insert taskRecord;

        Test.startTest();
        OCX_ActionListController.completeAction(taskRecord.Id);
        Test.stopTest();

        Task reloaded = [
            SELECT Status
            FROM Task
            WHERE Id = :taskRecord.Id
        ];

        System.assertEquals(
            'Completed',
            reloaded.Status,
            'Org automation normalizes the Task into an OCX action, so completion must succeed.'
        );
    }

    @isTest
    static void nullRecordIdThrows() {
        Boolean threw = false;
        try {
            OCX_ActionListController.getActions(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'a null record id is rejected');
    }

    @isTest
    static void minimumAccessUserSeesNothingWithoutPermissionSet() {
        // User creation and data seeding both happen outside the restricted runAs block.
        User minimal = makeMinimumAccessUser();

        Account a = makeAccount();
        insert makeAction(a, 'cta-1', null, 'CTA', 1, 'ACTIVE', 'Not Started');

        Test.startTest();
        System.runAs(minimal) {
            OCX_ActionListController.ActionPlan plan = OCX_ActionListController.getActions(a.Id);
            System.assertNotEquals(null, plan, 'controller returns a plan rather than failing hard');
            System.assertEquals(0, plan.totalCount, 'no actions without the permission set');
            System.assertEquals(0, plan.ctas.size(), 'no CTAs without the permission set');
        }
        Test.stopTest();
    }
}