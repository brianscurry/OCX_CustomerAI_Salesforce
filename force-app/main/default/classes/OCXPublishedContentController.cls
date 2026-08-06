public with sharing class OCXPublishedContentController {
    private static final String DASHBOARD_VIEWER_BASE_URL = 'https://iuxswspibfhhexiovbnu.supabase.co/functions/v1/artifact-viewer';
    private static final String CUSTOMER_AI_TENANT = 'demo';

    private static String buildDashboardUrl(String scope) {
        return DASHBOARD_VIEWER_BASE_URL
            + '?tenant='
            + EncodingUtil.urlEncode(CUSTOMER_AI_TENANT, 'UTF-8').replace('+', '%20')
            + '&scope='
            + EncodingUtil.urlEncode(scope, 'UTF-8').replace('+', '%20');
    }

    public class PublicationDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String publicationNumber;
        @AuraEnabled public String title;
        @AuraEnabled public String format;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime publishedAt;
        @AuraEnabled public String publishedBy;
        @AuraEnabled public String summary;
        @AuraEnabled public String renderedHtml;
        @AuraEnabled public String markdown;
        @AuraEnabled public String sourceUrl;
        @AuraEnabled public String viewerUrl;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String aspectRatio;
        @AuraEnabled public String viewerLayout;
        @AuraEnabled public Boolean dashboard;
    }

    @AuraEnabled(cacheable=true)
    public static List<PublicationDTO> getForAccount(Id accountId) {
        if (accountId == null) {
            return new List<PublicationDTO>();
        }

        List<PublicationDTO> results = new List<PublicationDTO>();

        Account dashboardAccount = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ];

        PublicationDTO dashboardItem = new PublicationDTO();
        dashboardItem.id = dashboardAccount.Id;
        dashboardItem.publicationNumber = 'Analytics Dashboard';
        dashboardItem.title = 'Analytics Dashboard';
        dashboardItem.format = 'INTERACTIVE_HTML';
        dashboardItem.status = 'Published';
        dashboardItem.publishedBy = 'Customer AI';
        dashboardItem.summary = 'Evergreen Customer AI analytics dashboard.';
        dashboardItem.sourceUrl = buildDashboardUrl('account::' + dashboardAccount.Name);
        dashboardItem.viewerUrl = dashboardItem.sourceUrl;
        dashboardItem.aspectRatio = '8.5/11';
        dashboardItem.viewerLayout = 'document';
        dashboardItem.dashboard = true;
        results.add(dashboardItem);

        for (OCX_Published_Content__c row : [
            SELECT Id, Name, OCX_Title__c, OCX_Content_Format__c, OCX_Status__c,
                   OCX_Published_At__c, OCX_Published_By_Name__c, OCX_Summary__c,
                   OCX_Rendered_HTML__c, OCX_Markdown__c, OCX_Source_URL__c,
                   OCX_Viewer_URL__c, OCX_Content_Document_ID__c
            FROM OCX_Published_Content__c
            WHERE OCX_Account__c = :accountId
            ORDER BY OCX_Published_At__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 100
        ]) {
            PublicationDTO dto = new PublicationDTO();
            dto.id = row.Id;
            dto.publicationNumber = row.Name;
            dto.title = String.isBlank(row.OCX_Title__c) ? row.Name : row.OCX_Title__c;
            dto.format = row.OCX_Content_Format__c;
            dto.status = row.OCX_Status__c;
            dto.publishedAt = row.OCX_Published_At__c;
            dto.publishedBy = row.OCX_Published_By_Name__c;
            dto.summary = row.OCX_Summary__c;
            dto.renderedHtml = row.OCX_Rendered_HTML__c;
            dto.markdown = row.OCX_Markdown__c;
            dto.sourceUrl = row.OCX_Source_URL__c;
            dto.viewerUrl = row.OCX_Viewer_URL__c;
            dto.contentDocumentId = row.OCX_Content_Document_ID__c;
            dto.dashboard = false;
            results.add(dto);
        }
        return results;
    }
}