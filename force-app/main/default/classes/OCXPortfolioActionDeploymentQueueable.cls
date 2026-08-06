public without sharing class OCXPortfolioActionDeploymentQueueable implements Queueable {
    private final Id deploymentId;

    public OCXPortfolioActionDeploymentQueueable(Id deploymentId) {
        this.deploymentId = deploymentId;
    }

    public void execute(QueueableContext context) {
        OCX_Action_Deployment__c deployment = [
            SELECT Id, OCX_Portfolio__c, OCX_Published_Content__c,
                   OCX_Source_Resource_ID__c, OCX_Source_Version__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];
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
        List<OCX_Portfolio_Membership__c> memberships = [
            SELECT OCX_Account__c
            FROM OCX_Portfolio_Membership__c
            WHERE OCX_Portfolio_Ref__c = :portfolio.Id
              AND OCX_Account__c != null
        ];

        Schema.RecordTypeInfo recordTypeInfo = Schema.SObjectType.Task
            .getRecordTypeInfosByDeveloperName().get('OCX_Action');
        if (recordTypeInfo == null) {
            markFailed(deployment, 'OCX_Action Task record type was not found.');
            return;
        }

        List<OCX_Action_Deployment_Account__c> deploymentAccounts =
            new List<OCX_Action_Deployment_Account__c>();
        for (OCX_Portfolio_Membership__c membership : memberships) {
            deploymentAccounts.add(new OCX_Action_Deployment_Account__c(
                OCX_Action_Deployment__c = deployment.Id,
                OCX_Account__c = membership.OCX_Account__c,
                OCX_Deployment_Account_Key__c = OCXPortfolioActionDeploymentService.hash(
                    String.valueOf(deployment.Id) + '|' + String.valueOf(membership.OCX_Account__c)
                ),
                OCX_Status__c = 'PENDING'
            ));
        }
        if (!deploymentAccounts.isEmpty()) {
            insert deploymentAccounts;
        }

        Map<Id, Id> deploymentAccountByAccount = new Map<Id, Id>();
        for (OCX_Action_Deployment_Account__c item : deploymentAccounts) {
            deploymentAccountByAccount.put(item.OCX_Account__c, item.Id);
        }

        List<Task> tasks = new List<Task>();
        for (Id accountId : deploymentAccountByAccount.keySet()) {
            Integer fallbackSequence = 0;
            for (OCXPortfolioActionDeploymentService.CtaItem cta : ctas) {
                fallbackSequence++;
                Integer sequence = cta.sequence == null ? fallbackSequence : cta.sequence;
                String portfolioCtaKey = String.valueOf(sequence);
                String actionKey = OCXPortfolioActionDeploymentService.hash(
                    String.valueOf(deployment.Id) + '|' + String.valueOf(accountId) + '|' + portfolioCtaKey
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
                    Description = OCXPortfolioActionDeploymentService.buildDescription(cta, portfolio.Name),
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
                    OCX_Action_Deployment_Account__c = deploymentAccountByAccount.get(accountId),
                    OCX_Source_Portfolio__c = portfolio.Id,
                    OCX_Portfolio_CTA_Key__c = portfolioCtaKey,
                    OCX_Inherited_From_Portfolio__c = true,
                    OCX_Deployment_State__c = 'ACTIVE'
                ));
            }
        }

        Database.SaveResult[] results = Database.insert(tasks, false);
        Integer succeeded = 0;
        Integer failed = 0;
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                succeeded++;
            } else {
                failed++;
            }
        }

        List<OCX_Action_Deployment_Account__c> deploymentAccountUpdates =
            new List<OCX_Action_Deployment_Account__c>();
        for (OCX_Action_Deployment_Account__c item : deploymentAccounts) {
            deploymentAccountUpdates.add(
                new OCX_Action_Deployment_Account__c(
                    Id = item.Id,
                    OCX_Status__c = failed == 0
                        ? 'SUCCEEDED'
                        : 'PARTIALLY_FAILED',
                    OCX_Tasks_Created__c = ctas.size()
                )
            );
        }
        if (!deploymentAccountUpdates.isEmpty()) {
            update deploymentAccountUpdates;
        }

        deployment.OCX_Status__c = failed == 0 ? 'ACTIVE' : 'PARTIALLY_FAILED';
        deployment.OCX_Deployed_At__c = System.now();
        deployment.OCX_Account_Count__c = memberships.size();
        deployment.OCX_CTA_Count__c = ctas.size();
        deployment.OCX_Task_Count__c = succeeded;
        deployment.OCX_Failed_Count__c = failed;
        update deployment;
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
        if ('High'.equalsIgnoreCase(value)) {
            return 'High';
        }
        return 'Normal';
    }

    private static void markFailed(OCX_Action_Deployment__c deployment, String message) {
        deployment.OCX_Status__c = 'FAILED';
        deployment.OCX_Failed_Count__c = 1;
        update deployment;
    }
}