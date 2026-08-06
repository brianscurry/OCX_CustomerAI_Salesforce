@IsTest
private class OCXPortfolioActionDeploymentTest {
    @TestSetup
    static void setupData() {
        OCX_Portfolio__c portfolio = new OCX_Portfolio__c(
            Name = 'Deployment Test Portfolio',
            OCX_Portfolio_ID__c = 'P-DEPLOY-TEST'
        );
        Database.insert(portfolio, AccessLevel.SYSTEM_MODE);

        Account first = new Account(Name = 'Deployment Account One');
        Account second = new Account(Name = 'Deployment Account Two');
        Database.insert(new List<Account>{ first, second }, AccessLevel.SYSTEM_MODE);

        Database.insert(new List<OCX_Portfolio_Membership__c>{
            new OCX_Portfolio_Membership__c(
                OCX_Portfolio_Ref__c = portfolio.Id,
                OCX_Account__c = first.Id,
                OCX_Membership_ID__c = 'M-DEPLOY-1'
            ),
            new OCX_Portfolio_Membership__c(
                OCX_Portfolio_Ref__c = portfolio.Id,
                OCX_Account__c = second.Id,
                OCX_Membership_ID__c = 'M-DEPLOY-2'
            )
        }, AccessLevel.SYSTEM_MODE);

        String markdown =
            '```ocx-actions\n' +
            '[{"actionType":"CTA","title":"Improve Support","description":"Summary",' +
            '"sequence":1,"tasks":[{"title":"Review tickets","description":"Review 90 days","sequence":1}]}]' +
            '\n```';

        Database.insert(new OCX_Published_Content__c(
            OCX_Title__c = 'Portfolio Deployment Plan',
            OCX_Portfolio__c = portfolio.Id,
            OCX_Markdown__c = markdown,
            OCX_Publication_Key__c = 'PUB-DEPLOY-TEST',
            OCX_Source_Resource_ID__c = 'R-DEPLOY-TEST',
            OCX_Source_Version__c = 1,
            OCX_Content_Format__c = 'MARKDOWN',
            OCX_Status__c = 'PUBLISHED'
        ), AccessLevel.SYSTEM_MODE);
    }

    private static OCX_Published_Content__c publication() {
        return [
            SELECT Id, OCX_Portfolio__c, OCX_Source_Resource_ID__c,
                   OCX_Source_Version__c, OCX_Markdown__c
            FROM OCX_Published_Content__c
            WHERE OCX_Publication_Key__c = 'PUB-DEPLOY-TEST'
            LIMIT 1
        ];
    }

    private static OCX_Action_Deployment__c makeDeployment(String key) {
        OCX_Published_Content__c publication = publication();
        OCX_Action_Deployment__c deployment = new OCX_Action_Deployment__c(
            OCX_Portfolio__c = publication.OCX_Portfolio__c,
            OCX_Published_Content__c = publication.Id,
            OCX_Source_Resource_ID__c = publication.OCX_Source_Resource_ID__c,
            OCX_Source_Version__c = String.valueOf(publication.OCX_Source_Version__c),
            OCX_Status__c = 'DEPLOYING',
            OCX_Deployed_By__c = UserInfo.getUserId(),
            OCX_Deployment_Key__c = key
        );
        insert deployment;
        return deployment;
    }


    private static void runDeploymentBatch(Id deploymentId) {
        OCXPortfolioActionDeploymentBatch batch =
            new OCXPortfolioActionDeploymentBatch(deploymentId);
        List<SObject> scope = new List<SObject>();
        Id portfolioId = publication().OCX_Portfolio__c;
        for (OCX_Portfolio_Membership__c membership : [
            SELECT Id, OCX_Account__c
            FROM OCX_Portfolio_Membership__c
            WHERE OCX_Portfolio_Ref__c = :portfolioId
        ]) {
            scope.add(membership);
        }
        batch.execute(null, scope);
        batch.finish(null);
    }

    @IsTest
    static void parsesNestedCtasAndBuildsDescription() {
        List<OCXPortfolioActionDeploymentService.CtaItem> ctas =
            OCXPortfolioActionDeploymentService.parseCtas(publication().OCX_Markdown__c);
        System.assertEquals(1, ctas.size());
        System.assertEquals(1, ctas[0].tasks.size());

        String description =
            OCXPortfolioActionDeploymentService.buildDescription(ctas[0], 'Test Portfolio');
        System.assert(description.contains('1. Review tickets'));
        System.assert(description.contains('Review 90 days'));
        System.assertEquals(0, OCXPortfolioActionDeploymentService.parseCtas(null).size());
        System.assertEquals(0, OCXPortfolioActionDeploymentService.parseCtas('none').size());
        System.assertEquals(64, OCXPortfolioActionDeploymentService.hash('x').length());
    }

    @IsTest
    static void deploymentBatchCreatesAccountCtas() {
        OCX_Action_Deployment__c deployment = makeDeployment('DEPLOY-QUEUEABLE');

        runDeploymentBatch(deployment.Id);

        System.assertEquals(2, [
            SELECT COUNT() FROM Task
            WHERE OCX_Action_Deployment__c = :deployment.Id
        ]);
        System.assertEquals(2, [
            SELECT COUNT() FROM OCX_Action_Deployment_Account__c
            WHERE OCX_Action_Deployment__c = :deployment.Id
        ]);

        OCX_Action_Deployment__c stored = [
            SELECT OCX_Status__c, OCX_Account_Count__c, OCX_CTA_Count__c,
                   OCX_Task_Count__c, OCX_Failed_Count__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deployment.Id
        ];
        System.assertEquals('ACTIVE', stored.OCX_Status__c);
        System.assertEquals(2, stored.OCX_Account_Count__c);
        System.assertEquals(1, stored.OCX_CTA_Count__c);
        System.assertEquals(2, stored.OCX_Task_Count__c);
        System.assertEquals(0, stored.OCX_Failed_Count__c);
    }

    @IsTest
    static void withdrawalQueueableWithdrawsIncompleteAndPreservesCompleted() {
        OCX_Action_Deployment__c deployment = makeDeployment('WITHDRAW-BATCH');
        runDeploymentBatch(deployment.Id);

        Task completedTask = [
            SELECT Id, Status
            FROM Task
            WHERE OCX_Action_Deployment__c = :deployment.Id
            LIMIT 1
        ];
        completedTask.Status = 'Completed';
        update completedTask;

        Test.startTest();
        new OCXPortfolioActionWithdrawalQueueable(deployment.Id).execute(null);
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM Task
            WHERE OCX_Action_Deployment__c = :deployment.Id
              AND OCX_Deployment_State__c = 'WITHDRAWN'
              AND WhatId = null
        ]);
        System.assertEquals(1, [
            SELECT COUNT() FROM Task
            WHERE OCX_Action_Deployment__c = :deployment.Id
              AND OCX_Deployment_State__c = 'SOURCE_DEACTIVATED'
              AND Status = 'Completed'
              AND WhatId != null
        ]);
        System.assertEquals('DEACTIVATED', [
            SELECT OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deployment.Id
        ].OCX_Status__c);
    }

    @IsTest
    static void controllerDeploysAndListsDeployment() {
        OCX_Published_Content__c publication = publication();

        Test.startTest();
        Id deploymentId = OCXPortfolioActionDeploymentController.deployPlan(publication.Id);
        Test.stopTest();

        OCX_Action_Deployment__c deployment = [
            SELECT Id, OCX_Status__c, OCX_Portfolio__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
        ];
        System.assertEquals('ACTIVE', deployment.OCX_Status__c);

        List<OCXPortfolioActionDeploymentController.DeploymentRow> rows =
            OCXPortfolioActionDeploymentController.getDeployments(deployment.OCX_Portfolio__c);
        System.assertEquals(1, rows.size());
        System.assertEquals(deploymentId, rows[0].id);
        System.assertEquals(publication.Id, rows[0].publicationId);
        System.assertEquals('Portfolio Deployment Plan', rows[0].publicationTitle);
        System.assertEquals(0,
            OCXPortfolioActionDeploymentController.getDeployments(null).size());
    }

    @IsTest
    static void controllerDeactivatesDeploymentAndValidatesInputs() {
        OCX_Action_Deployment__c deployment = makeDeployment('CONTROLLER-WITHDRAW');
        runDeploymentBatch(deployment.Id);

        Test.startTest();
        OCXPortfolioActionDeploymentController.deactivateDeployment(deployment.Id);
        Test.stopTest();

        System.assertEquals('DEACTIVATED', [
            SELECT OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deployment.Id
        ].OCX_Status__c);

        Boolean publicationExceptionCaught = false;
        try {
            OCXPortfolioActionDeploymentController.deployPlan(null);
        } catch (AuraHandledException expected) {
            publicationExceptionCaught = true;
        }
        System.assertEquals(true, publicationExceptionCaught);

        Boolean deploymentExceptionCaught = false;
        try {
            OCXPortfolioActionDeploymentController.deactivateDeployment(null);
        } catch (AuraHandledException expected) {
            deploymentExceptionCaught = true;
        }
        System.assertEquals(true, deploymentExceptionCaught);
    }
}