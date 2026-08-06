public without sharing class OCXPortfolioActionDeploymentBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    private final Id deploymentId;
    private Integer accountsProcessed = 0;
    private Integer tasksCreated = 0;
    private Integer failures = 0;
    private Integer ctaCount = 0;

    public OCXPortfolioActionDeploymentBatch(Id deploymentId) {
        this.deploymentId = deploymentId;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        OCX_Action_Deployment__c deployment = [
            SELECT Id, OCX_Portfolio__c, OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];

        if (deployment.OCX_Status__c != 'DEPLOYING') {
            return Database.getQueryLocator([
                SELECT Id, OCX_Account__c
                FROM OCX_Portfolio_Membership__c
                WHERE Id = :deploymentId
            ]);
        }

        return Database.getQueryLocator([
            SELECT Id, OCX_Account__c
            FROM OCX_Portfolio_Membership__c
            WHERE OCX_Portfolio_Ref__c = :deployment.OCX_Portfolio__c
              AND OCX_Account__c != null
            ORDER BY Id
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        if (scope.isEmpty()) {
            return;
        }

        try {
            processScope(scope);
        } catch (Exception error) {
            failures += scope.size();
            System.debug(
                LoggingLevel.ERROR,
                'Portfolio deployment batch scope failed: ' + error.getMessage()
            );
        }
    }

    private void processScope(List<SObject> scope) {
        OCX_Action_Deployment__c deployment = [
            SELECT Id, OCX_Portfolio__c, OCX_Published_Content__c,
                   OCX_Source_Resource_ID__c, OCX_Source_Version__c,
                   OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];
        if (deployment.OCX_Status__c != 'DEPLOYING') {
            return;
        }

        OCX_Portfolio__c portfolio = [
            SELECT Id, Name
            FROM OCX_Portfolio__c
            WHERE Id = :deployment.OCX_Portfolio__c
            LIMIT 1
        ];
        OCX_Published_Content__c publication = [
            SELECT Id, OCX_Markdown__c
            FROM OCX_Published_Content__c
            WHERE Id = :deployment.OCX_Published_Content__c
            LIMIT 1
        ];

        List<OCXPortfolioActionDeploymentService.CtaItem> ctas =
            OCXPortfolioActionDeploymentService.parseCtas(publication.OCX_Markdown__c);
        ctaCount = ctas.size();
        if (ctas.isEmpty()) {
            failures += scope.size();
            return;
        }

        Schema.RecordTypeInfo recordTypeInfo = Schema.SObjectType.Task
            .getRecordTypeInfosByDeveloperName().get('OCX_Action');
        if (recordTypeInfo == null) {
            failures += scope.size() * ctas.size();
            return;
        }

        Set<Id> accountIds = new Set<Id>();
        for (SObject rawMembership : scope) {
            OCX_Portfolio_Membership__c membership =
                (OCX_Portfolio_Membership__c) rawMembership;
            if (membership.OCX_Account__c != null) {
                accountIds.add(membership.OCX_Account__c);
            }
        }
        accountsProcessed += accountIds.size();

        List<OCX_Action_Deployment_Account__c> deploymentAccounts =
            new List<OCX_Action_Deployment_Account__c>();
        List<Id> sourceAccountIds = new List<Id>();
        for (Id accountId : accountIds) {
            deploymentAccounts.add(new OCX_Action_Deployment_Account__c(
                OCX_Action_Deployment__c = deployment.Id,
                OCX_Account__c = accountId,
                OCX_Deployment_Account_Key__c = OCXPortfolioActionDeploymentService.hash(
                    String.valueOf(deployment.Id) + '|' + String.valueOf(accountId)
                ),
                OCX_Status__c = 'PENDING'
            ));
            sourceAccountIds.add(accountId);
        }

        Database.SaveResult[] deploymentAccountResults =
            Database.insert(deploymentAccounts, false);
        Map<Id, Id> deploymentAccountByAccount = new Map<Id, Id>();

        for (Integer index = 0; index < deploymentAccountResults.size(); index++) {
            if (deploymentAccountResults[index].isSuccess()) {
                deploymentAccountByAccount.put(
                    sourceAccountIds[index],
                    deploymentAccounts[index].Id
                );
            } else {
                failures += ctas.size();
            }
        }

        List<Task> tasks = new List<Task>();
        List<Id> taskAccountIds = new List<Id>();
        for (Id accountId : deploymentAccountByAccount.keySet()) {
            Integer fallbackSequence = 0;
            for (OCXPortfolioActionDeploymentService.CtaItem cta : ctas) {
                fallbackSequence++;
                Integer sequence = cta.sequence == null ? fallbackSequence : cta.sequence;
                String portfolioCtaKey = String.valueOf(sequence);
                String actionKey = OCXPortfolioActionDeploymentService.hash(
                    String.valueOf(deployment.Id) + '|' +
                    String.valueOf(accountId) + '|' + portfolioCtaKey
                );

                Date dueDate;
                if (String.isNotBlank(cta.dueDate)) {
                    try {
                        dueDate = Date.valueOf(cta.dueDate);
                    } catch (Exception ignored) {
                        dueDate = null;
                    }
                }

                tasks.add(new Task(
                    Subject = String.isBlank(cta.title) ? 'Portfolio CTA' : cta.title,
                    Description = OCXPortfolioActionDeploymentService.buildDescription(
                        cta,
                        portfolio.Name
                    ),
                    WhatId = accountId,
                    OwnerId = UserInfo.getUserId(),
                    Status = 'Not Started',
                    Priority = normalizePriority(cta.priority),
                    ActivityDate = dueDate,
                    RecordTypeId = recordTypeInfo.getRecordTypeId(),
                    OCX_Action_Key__c = actionKey,
                    OCX_Action_ID__c = actionKey,
                    OCX_Action_Type__c = 'CTA',
                    OCX_Sequence__c = sequence,
                    OCX_Source_Resource_ID__c = deployment.OCX_Source_Resource_ID__c,
                    OCX_Source_Version__c = parseVersion(deployment.OCX_Source_Version__c),
                    OCX_Source_State__c = 'ACTIVE',
                    OCX_Published_Content__c = publication.Id,
                    OCX_Action_Deployment__c = deployment.Id,
                    OCX_Action_Deployment_Account__c =
                        deploymentAccountByAccount.get(accountId),
                    OCX_Source_Portfolio__c = portfolio.Id,
                    OCX_Portfolio_CTA_Key__c = portfolioCtaKey,
                    OCX_Inherited_From_Portfolio__c = true,
                    OCX_Deployment_State__c = 'ACTIVE'
                ));
                taskAccountIds.add(accountId);
            }
        }

        Database.SaveResult[] taskResults = Database.insert(tasks, false);
        Map<Id, Integer> succeededByAccount = new Map<Id, Integer>();
        Map<Id, Integer> failedByAccount = new Map<Id, Integer>();

        for (Integer index = 0; index < taskResults.size(); index++) {
            Id accountId = taskAccountIds[index];
            if (taskResults[index].isSuccess()) {
                tasksCreated++;
                succeededByAccount.put(
                    accountId,
                    valueOrZero(succeededByAccount, accountId) + 1
                );
            } else {
                failures++;
                failedByAccount.put(
                    accountId,
                    valueOrZero(failedByAccount, accountId) + 1
                );
            }
        }

        List<OCX_Action_Deployment_Account__c> accountUpdates =
            new List<OCX_Action_Deployment_Account__c>();
        for (Id accountId : deploymentAccountByAccount.keySet()) {
            Integer succeededForAccount = valueOrZero(succeededByAccount, accountId);
            Integer failedForAccount = valueOrZero(failedByAccount, accountId);
            accountUpdates.add(new OCX_Action_Deployment_Account__c(
                Id = deploymentAccountByAccount.get(accountId),
                OCX_Status__c = failedForAccount == 0
                    ? 'SUCCEEDED'
                    : 'PARTIALLY_FAILED',
                OCX_Tasks_Created__c = succeededForAccount
            ));
        }
        if (!accountUpdates.isEmpty()) {
            update accountUpdates;
        }

        update new OCX_Action_Deployment__c(
            Id = deployment.Id,
            OCX_Account_Count__c = accountsProcessed,
            OCX_CTA_Count__c = ctaCount,
            OCX_Task_Count__c = tasksCreated,
            OCX_Failed_Count__c = failures
        );
    }

    public void finish(Database.BatchableContext context) {
        List<OCX_Action_Deployment__c> rows = [
            SELECT Id, OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];
        if (rows.isEmpty() || rows[0].OCX_Status__c != 'DEPLOYING') {
            return;
        }

        OCX_Action_Deployment__c deployment = rows[0];
        deployment.OCX_Account_Count__c = accountsProcessed;
        deployment.OCX_CTA_Count__c = ctaCount;
        deployment.OCX_Task_Count__c = tasksCreated;
        deployment.OCX_Failed_Count__c = failures;
        deployment.OCX_Deployed_At__c = System.now();

        if (accountsProcessed == 0) {
            deployment.OCX_Status__c = 'FAILED';
            deployment.OCX_Failed_Count__c = failures > 0 ? failures : 1;
        } else {
            deployment.OCX_Status__c = failures == 0
                ? 'ACTIVE'
                : 'PARTIALLY_FAILED';
        }
        update deployment;
    }

    private static Integer valueOrZero(Map<Id, Integer> values, Id key) {
        return values.containsKey(key) ? values.get(key) : 0;
    }

    private static Decimal parseVersion(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Decimal.valueOf(value);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static String normalizePriority(String value) {
        return 'High'.equalsIgnoreCase(value) ? 'High' : 'Normal';
    }
}