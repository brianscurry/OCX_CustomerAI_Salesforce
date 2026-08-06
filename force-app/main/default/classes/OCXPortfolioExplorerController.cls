public with sharing class OCXPortfolioExplorerController {
    private static final String DASHBOARD_VIEWER_BASE_URL = 'https://iuxswspibfhhexiovbnu.supabase.co/functions/v1/artifact-viewer';
    private static final String CUSTOMER_AI_TENANT = 'demo';

    private static String buildDashboardUrl(String scope) {
        return DASHBOARD_VIEWER_BASE_URL
            + '?tenant='
            + EncodingUtil.urlEncode(CUSTOMER_AI_TENANT, 'UTF-8').replace('+', '%20')
            + '&scope='
            + EncodingUtil.urlEncode(scope, 'UTF-8').replace('+', '%20');
    }

    private static final Integer DEFAULT_PAGE_SIZE = 50;
    private static final Integer MAX_PAGE_SIZE = 200;

    public class PortfolioOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String externalId;
        @AuraEnabled public Decimal storedAccountCount;
    }

    public class DistributionItem {
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;

        public DistributionItem(String label, Integer count) {
            this.label = String.isBlank(label) ? 'Unclassified' : label;
            this.count = count == null ? 0 : count;
        }
    }

    public class PortfolioSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String externalId;
        @AuraEnabled public Integer accountCount;
        @AuraEnabled public Decimal totalAcv;
        @AuraEnabled public Decimal openTickets;
        @AuraEnabled public List<DistributionItem> npsDistribution;
        @AuraEnabled public List<DistributionItem> propensityDistribution;
    }

    public class AccountRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal acv;
        @AuraEnabled public String npsClass;
        @AuraEnabled public String propensity;
        @AuraEnabled public String revenueBand;
        @AuraEnabled public String renewalQuarter;
        @AuraEnabled public Decimal openTickets;
        @AuraEnabled public String primaryProduct;
    }

    public class AccountPage {
        @AuraEnabled public List<AccountRow> rows;
        @AuraEnabled public String nextAfterName;
        @AuraEnabled public Id nextAfterId;
        @AuraEnabled public Boolean hasMore;
    }

    public class PublishedContentRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String summary;
        @AuraEnabled public String format;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime publishedAt;
        @AuraEnabled public String sourceUrl;
        @AuraEnabled public String viewerUrl;
        @AuraEnabled public String aspectRatio;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String renderedHtml;
        @AuraEnabled public String markdown;
        @AuraEnabled public String resourceType;
        @AuraEnabled public Boolean actionPlan;
        @AuraEnabled public String viewerLayout;
        @AuraEnabled public Boolean dashboard;
    }

    @AuraEnabled(cacheable=true)
    public static List<PortfolioOption> getPortfolios(String searchTerm) {
        String likeTerm = String.isBlank(searchTerm) ? '%' : '%' + searchTerm.trim() + '%';

        List<OCX_Portfolio__c> portfolios = [
            SELECT Id, Name, OCX_Portfolio_ID__c
            FROM OCX_Portfolio__c
            WHERE Name LIKE :likeTerm
            WITH USER_MODE
            ORDER BY Name
            LIMIT 200
        ];

        Set<Id> portfolioIds = new Map<Id, OCX_Portfolio__c>(portfolios).keySet();
        Map<Id, Decimal> actualAccountCounts = new Map<Id, Decimal>();

        if (!portfolioIds.isEmpty()) {
            for (AggregateResult aggregateRow : [
                SELECT OCX_Portfolio_Ref__c portfolioId,
                       COUNT_DISTINCT(OCX_Account__c) accountCount
                FROM OCX_Portfolio_Membership__c
                WHERE OCX_Portfolio_Ref__c IN :portfolioIds
                  AND OCX_Account__c != null
                WITH USER_MODE
                GROUP BY OCX_Portfolio_Ref__c
            ]) {
                actualAccountCounts.put(
                    (Id) aggregateRow.get('portfolioId'),
                    Decimal.valueOf(String.valueOf(aggregateRow.get('accountCount')))
                );
            }
        }

        List<PortfolioOption> result = new List<PortfolioOption>();

        for (OCX_Portfolio__c row : portfolios) {
            PortfolioOption item = new PortfolioOption();
            item.id = row.Id;
            item.name = row.Name;
            item.externalId = row.OCX_Portfolio_ID__c;
            item.storedAccountCount = actualAccountCounts.containsKey(row.Id)
                ? actualAccountCounts.get(row.Id)
                : 0;
            result.add(item);
        }

        return result;
    }

    @AuraEnabled(cacheable=true)
    public static PortfolioSummary getPortfolioSummary(Id portfolioId) {
        requireId(portfolioId, 'portfolioId');

        OCX_Portfolio__c portfolio = [
            SELECT Id, Name, OCX_Portfolio_ID__c, OCX_Account_Count__c
            FROM OCX_Portfolio__c
            WHERE Id = :portfolioId
            WITH USER_MODE
            LIMIT 1
        ];

        AggregateResult totals = [
            SELECT COUNT(Id) accountCount,
                   SUM(OCX_ACV__c) totalAcv,
                   SUM(OCX_Open_Tickets__c) openTickets
            FROM Account
            WHERE Id IN (
                SELECT OCX_Account__c
                FROM OCX_Portfolio_Membership__c
                WHERE OCX_Portfolio_Ref__c = :portfolioId
                  AND OCX_Account__c != null
            )
            WITH USER_MODE
        ];

        PortfolioSummary summary = new PortfolioSummary();
        summary.id = portfolio.Id;
        summary.name = portfolio.Name;
        summary.externalId = portfolio.OCX_Portfolio_ID__c;
        summary.accountCount = Integer.valueOf(String.valueOf(totals.get('accountCount')));
        summary.totalAcv = (Decimal) totals.get('totalAcv');
        summary.openTickets = (Decimal) totals.get('openTickets');
        summary.npsDistribution = getNpsDistribution(portfolioId);
        summary.propensityDistribution = getPropensityDistribution(portfolioId);
        return summary;
    }

    private static List<DistributionItem> getNpsDistribution(Id portfolioId) {
        List<DistributionItem> items = new List<DistributionItem>();
        for (AggregateResult row : [
            SELECT OCX_NPS_Class__c category, COUNT(Id) itemCount
            FROM Account
            WHERE Id IN (
                SELECT OCX_Account__c
                FROM OCX_Portfolio_Membership__c
                WHERE OCX_Portfolio_Ref__c = :portfolioId
                  AND OCX_Account__c != null
            )
            WITH USER_MODE
            GROUP BY OCX_NPS_Class__c
            ORDER BY OCX_NPS_Class__c
        ]) {
            items.add(new DistributionItem((String) row.get('category'), Integer.valueOf(String.valueOf(row.get('itemCount')))));
        }
        return items;
    }

    private static List<DistributionItem> getPropensityDistribution(Id portfolioId) {
        List<DistributionItem> items = new List<DistributionItem>();
        for (AggregateResult row : [
            SELECT OCX_Propensity__c category, COUNT(Id) itemCount
            FROM Account
            WHERE Id IN (
                SELECT OCX_Account__c
                FROM OCX_Portfolio_Membership__c
                WHERE OCX_Portfolio_Ref__c = :portfolioId
                  AND OCX_Account__c != null
            )
            WITH USER_MODE
            GROUP BY OCX_Propensity__c
            ORDER BY OCX_Propensity__c
        ]) {
            items.add(new DistributionItem((String) row.get('category'), Integer.valueOf(String.valueOf(row.get('itemCount')))));
        }
        return items;
    }

    @AuraEnabled(cacheable=true)
    public static AccountPage getAccounts(
        Id portfolioId,
        String searchTerm,
        Integer pageSize,
        String afterName,
        Id afterId
    ) {
        requireId(portfolioId, 'portfolioId');
        Integer safePageSize = pageSize == null ? DEFAULT_PAGE_SIZE : pageSize;
        if (safePageSize < 1) {
            safePageSize = 1;
        } else if (safePageSize > MAX_PAGE_SIZE) {
            safePageSize = MAX_PAGE_SIZE;
        }

        String soql =
            'SELECT Id, Name, OCX_ACV__c, OCX_NPS_Class__c, OCX_Propensity__c, ' +
            'OCX_Revenue_Band__c, OCX_Renewal_Quarter__c, OCX_Open_Tickets__c, OCX_Primary_Product__c ' +
            'FROM Account ' +
            'WHERE Id IN (' +
                'SELECT OCX_Account__c FROM OCX_Portfolio_Membership__c ' +
                'WHERE OCX_Portfolio_Ref__c = :portfolioId AND OCX_Account__c != null' +
            ')';

        Map<String, Object> binds = new Map<String, Object>{ 'portfolioId' => portfolioId };

        if (!String.isBlank(searchTerm)) {
            soql += ' AND Name LIKE :nameLike';
            binds.put('nameLike', '%' + searchTerm.trim() + '%');
        }

        if (!String.isBlank(afterName) && afterId != null) {
            soql += ' AND (Name > :afterName OR (Name = :afterName AND Id > :afterId))';
            binds.put('afterName', afterName);
            binds.put('afterId', afterId);
        }

        soql += ' ORDER BY Name, Id LIMIT ' + String.valueOf(safePageSize + 1);

        List<Account> accounts = (List<Account>) Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
        Boolean hasMore = accounts.size() > safePageSize;
        if (hasMore) {
            accounts.remove(accounts.size() - 1);
        }

        AccountPage page = new AccountPage();
        page.rows = new List<AccountRow>();
        page.hasMore = hasMore;

        for (Account account : accounts) {
            AccountRow row = new AccountRow();
            row.id = account.Id;
            row.name = account.Name;
            row.acv = account.OCX_ACV__c;
            row.npsClass = account.OCX_NPS_Class__c;
            row.propensity = account.OCX_Propensity__c;
            row.revenueBand = account.OCX_Revenue_Band__c;
            row.renewalQuarter = account.OCX_Renewal_Quarter__c;
            row.openTickets = account.OCX_Open_Tickets__c;
            row.primaryProduct = account.OCX_Primary_Product__c;
            page.rows.add(row);
        }

        if (!accounts.isEmpty()) {
            Account lastAccount = accounts[accounts.size() - 1];
            page.nextAfterName = lastAccount.Name;
            page.nextAfterId = lastAccount.Id;
        }
        return page;
    }

    @AuraEnabled(cacheable=true)
    public static List<PublishedContentRow> getPublishedContent(Id portfolioId) {
        requireId(portfolioId, 'portfolioId');
        List<PublishedContentRow> result = new List<PublishedContentRow>();

        OCX_Portfolio__c dashboardPortfolio = [
            SELECT Id, Name
            FROM OCX_Portfolio__c
            WHERE Id = :portfolioId
            WITH USER_MODE
            LIMIT 1
        ];

        String dashboardScope = dashboardPortfolio.Name == 'All Accounts'
            ? 'all'
            : dashboardPortfolio.Name;

        PublishedContentRow dashboardItem = new PublishedContentRow();
        dashboardItem.id = dashboardPortfolio.Id;
        dashboardItem.title = 'Analytics Dashboard';
        dashboardItem.summary = 'Evergreen Customer AI analytics dashboard.';
        dashboardItem.format = 'INTERACTIVE_HTML';
        dashboardItem.status = 'Published';
        dashboardItem.sourceUrl = buildDashboardUrl(dashboardScope);
        dashboardItem.viewerUrl = dashboardItem.sourceUrl;
        dashboardItem.aspectRatio = '8.5/11';
        dashboardItem.viewerLayout = 'document';
        dashboardItem.resourceType = 'Dashboard';
        dashboardItem.actionPlan = false;
        dashboardItem.dashboard = true;
        result.add(dashboardItem);

        for (OCX_Published_Content__c row : [
            SELECT Id, OCX_Title__c, OCX_Summary__c, OCX_Content_Format__c,
                   OCX_Status__c, OCX_Published_At__c, OCX_Source_URL__c,
                   OCX_Viewer_URL__c, OCX_Aspect_Ratio__c, OCX_Content_Document_ID__c,
                   OCX_Rendered_HTML__c, OCX_Markdown__c, OCX_Source_Resource_Type__c
            FROM OCX_Published_Content__c
            WHERE OCX_Portfolio__c = :portfolioId
            WITH USER_MODE
            ORDER BY OCX_Published_At__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 100
        ]) {
            PublishedContentRow item = new PublishedContentRow();
            item.id = row.Id;
            item.title = row.OCX_Title__c;
            item.summary = row.OCX_Summary__c;
            item.format = row.OCX_Content_Format__c;
            item.status = row.OCX_Status__c;
            item.publishedAt = row.OCX_Published_At__c;
            item.sourceUrl = row.OCX_Source_URL__c;
            item.viewerUrl = row.OCX_Viewer_URL__c;
            item.aspectRatio = row.OCX_Aspect_Ratio__c;
            item.contentDocumentId = row.OCX_Content_Document_ID__c;
            item.renderedHtml = row.OCX_Rendered_HTML__c;
            item.markdown = row.OCX_Markdown__c;
            item.resourceType = row.OCX_Source_Resource_Type__c;
            item.actionPlan = !String.isBlank(row.OCX_Markdown__c) && row.OCX_Markdown__c.contains('```ocx-actions');
            item.dashboard = false;
            result.add(item);
        }
        return result;
    }

    private static void requireId(Id value, String parameterName) {
        if (value == null) {
            throw new AuraHandledException(parameterName + ' is required.');
        }
    }
}