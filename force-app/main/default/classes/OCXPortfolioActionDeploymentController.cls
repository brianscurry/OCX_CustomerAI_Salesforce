public with sharing class OCXPortfolioActionDeploymentController {
    public class DeploymentRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Id publicationId;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String publicationTitle;
        @AuraEnabled public Decimal accountCount;
        @AuraEnabled public Decimal ctaCount;
        @AuraEnabled public Decimal taskCount;
        @AuraEnabled public Decimal completedCount;
        @AuraEnabled public Decimal withdrawnCount;
        @AuraEnabled public Datetime deployedAt;
    }

    @AuraEnabled
    public static Id deployPlan(Id publicationId) {
        if (publicationId == null) {
            throw new AuraHandledException('publicationId is required.');
        }

        OCX_Published_Content__c publication = [
            SELECT Id, OCX_Portfolio__c, OCX_Source_Resource_ID__c,
                   OCX_Source_Version__c, OCX_Markdown__c
            FROM OCX_Published_Content__c
            WHERE Id = :publicationId
            WITH USER_MODE
            LIMIT 1
        ];

        if (publication.OCX_Portfolio__c == null) {
            throw new AuraHandledException('This publication is not linked to a Portfolio.');
        }
        if (OCXPortfolioActionDeploymentService.parseCtas(publication.OCX_Markdown__c).isEmpty()) {
            throw new AuraHandledException('No nested CTA taxonomy was found in this publication.');
        }

        List<OCX_Action_Deployment__c> existing = [
            SELECT Id, OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE OCX_Published_Content__c = :publication.Id
              AND OCX_Status__c IN ('DEPLOYING', 'ACTIVE', 'PARTIALLY_FAILED')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw new AuraHandledException(
                'This Portfolio plan already has a deployment in status ' +
                existing[0].OCX_Status__c + '.'
            );
        }

        Integer memberCount = [
            SELECT COUNT()
            FROM OCX_Portfolio_Membership__c
            WHERE OCX_Portfolio_Ref__c = :publication.OCX_Portfolio__c
              AND OCX_Account__c != null
        ];
        if (memberCount == 0) {
            throw new AuraHandledException(
                'This Portfolio has no member Accounts. Add members before deploying actions.'
            );
        }

        OCX_Action_Deployment__c deployment = new OCX_Action_Deployment__c(
            OCX_Portfolio__c = publication.OCX_Portfolio__c,
            OCX_Published_Content__c = publication.Id,
            OCX_Source_Resource_ID__c = publication.OCX_Source_Resource_ID__c,
            OCX_Source_Version__c = String.valueOf(publication.OCX_Source_Version__c),
            OCX_Status__c = 'DEPLOYING',
            OCX_Deployed_By__c = UserInfo.getUserId(),
            OCX_Account_Count__c = 0,
            OCX_CTA_Count__c = 0,
            OCX_Task_Count__c = 0,
            OCX_Failed_Count__c = 0,
            OCX_Deployment_Key__c = OCXPortfolioActionDeploymentService.hash(
                String.valueOf(publication.Id) + '|' + String.valueOf(System.now().getTime())
            )
        );
        insert deployment;
        Database.executeBatch(new OCXPortfolioActionDeploymentBatch(deployment.Id), 100);
        return deployment.Id;
    }

    @AuraEnabled
    public static void deactivateDeployment(Id deploymentId) {
        if (deploymentId == null) {
            throw new AuraHandledException('deploymentId is required.');
        }

        OCX_Action_Deployment__c deployment = [
            SELECT Id, OCX_Status__c
            FROM OCX_Action_Deployment__c
            WHERE Id = :deploymentId
            LIMIT 1
        ];
        if (deployment.OCX_Status__c != 'ACTIVE' && deployment.OCX_Status__c != 'PARTIALLY_FAILED') {
            throw new AuraHandledException('Only an active deployment can be deactivated.');
        }

        deployment.OCX_Status__c = 'DEACTIVATING';
        update deployment;
        System.enqueueJob(new OCXPortfolioActionWithdrawalQueueable(deployment.Id));
    }

    @AuraEnabled(cacheable=true)
    public static List<DeploymentRow> getDeployments(Id portfolioId) {
        List<DeploymentRow> rows = new List<DeploymentRow>();
        if (portfolioId == null) {
            return rows;
        }

        for (OCX_Action_Deployment__c deployment : [
            SELECT Id, Name, OCX_Status__c, OCX_Published_Content__c,
                   OCX_Published_Content__r.OCX_Title__c,
                   OCX_Account_Count__c, OCX_CTA_Count__c,
                   OCX_Task_Count__c, OCX_Completed_Count__c,
                   OCX_Withdrawn_Count__c, OCX_Deployed_At__c
            FROM OCX_Action_Deployment__c
            WHERE OCX_Portfolio__c = :portfolioId
            ORDER BY CreatedDate DESC
            LIMIT 100
        ]) {
            DeploymentRow row = new DeploymentRow();
            row.id = deployment.Id;
            row.publicationId = deployment.OCX_Published_Content__c;
            row.name = deployment.Name;
            row.status = deployment.OCX_Status__c;
            row.publicationTitle = deployment.OCX_Published_Content__r.OCX_Title__c;
            row.accountCount = deployment.OCX_Account_Count__c;
            row.ctaCount = deployment.OCX_CTA_Count__c;
            row.taskCount = deployment.OCX_Task_Count__c;
            row.completedCount = deployment.OCX_Completed_Count__c;
            row.withdrawnCount = deployment.OCX_Withdrawn_Count__c;
            row.deployedAt = deployment.OCX_Deployed_At__c;
            rows.add(row);
        }
        return rows;
    }
}