public without sharing class OCXPortfolioActionWithdrawalQueueable implements Queueable {
    private final Id deploymentId;

    public OCXPortfolioActionWithdrawalQueueable(Id deploymentId) {
        this.deploymentId = deploymentId;
    }

    public void execute(QueueableContext context) {
        List<Task> tasks = [
            SELECT Id, Status, WhatId, OCX_Deployment_State__c
            FROM Task
            WHERE OCX_Action_Deployment__c = :deploymentId
        ];

        Integer withdrawn = 0;
        Integer completed = 0;
        Id userId = UserInfo.getUserId();
        Datetime nowValue = System.now();

        for (Task taskRecord : tasks) {
            if (taskRecord.Status == 'Completed') {
                taskRecord.OCX_Deployment_State__c = 'SOURCE_DEACTIVATED';
                completed++;
            } else {
                taskRecord.OCX_Deployment_State__c = 'WITHDRAWN';
                taskRecord.WhatId = null;
                taskRecord.OCX_Withdrawn_At__c = nowValue;
                taskRecord.OCX_Withdrawn_By__c = userId;
                taskRecord.OCX_Withdrawal_Reason__c = 'Portfolio deployment deactivated';
                withdrawn++;
            }
        }
        if (!tasks.isEmpty()) {
            update tasks;
        }

        OCX_Action_Deployment__c deployment = [
            SELECT Id
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];
        deployment.OCX_Status__c = 'DEACTIVATED';
        deployment.OCX_Deactivated_At__c = nowValue;
        deployment.OCX_Deactivated_By__c = userId;
        deployment.OCX_Withdrawn_Count__c = withdrawn;
        deployment.OCX_Completed_Count__c = completed;
        update deployment;

        List<OCX_Action_Deployment_Account__c> deploymentAccounts = [
            SELECT Id
            FROM OCX_Action_Deployment_Account__c
            WHERE OCX_Action_Deployment__c = :deploymentId
        ];
        for (OCX_Action_Deployment_Account__c item : deploymentAccounts) {
            item.OCX_Status__c = 'WITHDRAWN';
        }
        if (!deploymentAccounts.isEmpty()) {
            update deploymentAccounts;
        }
    }
}