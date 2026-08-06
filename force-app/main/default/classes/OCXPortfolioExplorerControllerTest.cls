@IsTest
private class OCXPortfolioExplorerControllerTest {
    @TestSetup
    static void createData() {
        OCX_Portfolio__c portfolio = new OCX_Portfolio__c(
            Name = 'Test Portfolio',
            OCX_Portfolio_ID__c = 'PORT_TEST',
            OCX_Account_Count__c = 2
        );
        Database.insert(portfolio, AccessLevel.SYSTEM_MODE);

        List<Account> accounts = new List<Account>{
            new Account(
                Name = 'Alpha Test Account',
                OCX_Account_ID__c = 'ACCT_ALPHA',
                OCX_ACV__c = 1000,
                OCX_NPS_Class__c = 'Promoter',
                OCX_Propensity__c = 'Upsell',
                OCX_Revenue_Band__c = '$0K - $5K',
                OCX_Renewal_Quarter__c = 'FY26 Q1',
                OCX_Open_Tickets__c = 2,
                OCX_Primary_Product__c = 'Core Apps'
            ),
            new Account(
                Name = 'Beta Test Account',
                OCX_Account_ID__c = 'ACCT_BETA',
                OCX_ACV__c = 2000,
                OCX_NPS_Class__c = 'Detractor',
                OCX_Propensity__c = 'Churn',
                OCX_Revenue_Band__c = '$0K - $5K',
                OCX_Renewal_Quarter__c = 'FY26 Q2',
                OCX_Open_Tickets__c = 3,
                OCX_Primary_Product__c = 'Digital Docs'
            )
        };
        Database.insert(accounts, AccessLevel.SYSTEM_MODE);

        Database.insert(new List<OCX_Portfolio_Membership__c>{
            new OCX_Portfolio_Membership__c(
                Name = 'Alpha / Test Portfolio',
                OCX_Membership_ID__c = 'MEM_ALPHA',
                OCX_Account__c = accounts[0].Id,
                OCX_Portfolio_Ref__c = portfolio.Id
            ),
            new OCX_Portfolio_Membership__c(
                Name = 'Beta / Test Portfolio',
                OCX_Membership_ID__c = 'MEM_BETA',
                OCX_Account__c = accounts[1].Id,
                OCX_Portfolio_Ref__c = portfolio.Id
            )
        }, AccessLevel.SYSTEM_MODE);

        Database.insert(new OCX_Published_Content__c(
            OCX_Publication_Key__c = 'PUB_TEST',
            OCX_Title__c = 'Test Published Analysis',
            OCX_Content_Format__c = 'STATIC_HTML',
            OCX_Status__c = 'PUBLISHED',
            OCX_Portfolio__c = portfolio.Id,
            OCX_Rendered_HTML__c = '<p>Portfolio analysis</p>',
            OCX_Published_At__c = System.now()
        ), AccessLevel.SYSTEM_MODE);
    }

    @IsTest
    static void returnsPortfoliosAndSummary() {
        Test.startTest();
        List<OCXPortfolioExplorerController.PortfolioOption> options =
            OCXPortfolioExplorerController.getPortfolios('Test');
        OCXPortfolioExplorerController.PortfolioSummary summary =
            OCXPortfolioExplorerController.getPortfolioSummary(options[0].id);
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals(
            2,
            options[0].storedAccountCount,
            'Portfolio dropdown count must come from actual membership records.'
        );
        System.assertEquals('Test Portfolio', summary.name);
        System.assertEquals(2, summary.accountCount);
        System.assertEquals(3000, summary.totalAcv);
        System.assertEquals(5, summary.openTickets);
        System.assertEquals(2, summary.npsDistribution.size());
        System.assertEquals(2, summary.propensityDistribution.size());
    }

    @IsTest
    static void returnsAccountsWithCursorAndSearch() {
        Id portfolioId = [SELECT Id FROM OCX_Portfolio__c WHERE OCX_Portfolio_ID__c = 'PORT_TEST' LIMIT 1].Id;

        Test.startTest();
        OCXPortfolioExplorerController.AccountPage firstPage =
            OCXPortfolioExplorerController.getAccounts(portfolioId, null, 1, null, null);
        OCXPortfolioExplorerController.AccountPage secondPage =
            OCXPortfolioExplorerController.getAccounts(
                portfolioId,
                null,
                1,
                firstPage.nextAfterName,
                firstPage.nextAfterId
            );
        OCXPortfolioExplorerController.AccountPage searchPage =
            OCXPortfolioExplorerController.getAccounts(portfolioId, 'Beta', 50, null, null);
        Test.stopTest();

        System.assertEquals(1, firstPage.rows.size());
        System.assertEquals(true, firstPage.hasMore);
        System.assertEquals(1, secondPage.rows.size());
        System.assertEquals('Beta Test Account', secondPage.rows[0].name);
        System.assertEquals(1, searchPage.rows.size());
        System.assertEquals('Beta Test Account', searchPage.rows[0].name);
    }

    @IsTest
    static void returnsPublishedContent() {
        Id portfolioId = [SELECT Id FROM OCX_Portfolio__c WHERE OCX_Portfolio_ID__c = 'PORT_TEST' LIMIT 1].Id;

        Test.startTest();
        List<OCXPortfolioExplorerController.PublishedContentRow> publications =
            OCXPortfolioExplorerController.getPublishedContent(portfolioId);
        Test.stopTest();

        System.assertEquals(2, publications.size());
        System.assertEquals('Analytics Dashboard', publications[0].title);

        OCXPortfolioExplorerController.PublishedContentRow storedPublication;
        for (
            OCXPortfolioExplorerController.PublishedContentRow row :
            publications
        ) {
            if (row.title == 'Test Published Analysis') {
                storedPublication = row;
                break;
            }
        }

        System.assertNotEquals(
            null,
            storedPublication,
            'The stored publication must remain in the result.'
        );
        System.assertEquals(
            'STATIC_HTML',
            storedPublication.format
        );
    }
}