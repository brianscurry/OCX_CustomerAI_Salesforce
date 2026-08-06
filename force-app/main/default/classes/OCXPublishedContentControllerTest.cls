@IsTest
private class OCXPublishedContentControllerTest {
    @IsTest
    static void returnsAccountPublicationsOnly() {
        Account includedAccount = new Account(Name = 'Included Account');
        Account excludedAccount = new Account(Name = 'Excluded Account');
        Database.insert(new List<Account>{includedAccount, excludedAccount}, AccessLevel.SYSTEM_MODE);

        Database.insert(new List<OCX_Published_Content__c>{
            new OCX_Published_Content__c(
                OCX_Publication_Key__c = 'viewer-test-included',
                OCX_Account__c = includedAccount.Id,
                OCX_Title__c = 'Included Report',
                OCX_Content_Format__c = 'MARKDOWN',
                OCX_Status__c = 'PUBLISHED',
                OCX_Markdown__c = '# Included'
            ),
            new OCX_Published_Content__c(
                OCX_Publication_Key__c = 'viewer-test-excluded',
                OCX_Account__c = excludedAccount.Id,
                OCX_Title__c = 'Excluded Report',
                OCX_Content_Format__c = 'MARKDOWN',
                OCX_Status__c = 'PUBLISHED'
            )
        }, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        List<OCXPublishedContentController.PublicationDTO> rows =
            OCXPublishedContentController.getForAccount(includedAccount.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'dashboard plus the included publication');

        OCXPublishedContentController.PublicationDTO included;
        for (OCXPublishedContentController.PublicationDTO row : rows) {
            if (row.title == 'Included Report') {
                included = row;
                break;
            }
        }

        System.assertNotEquals(null, included, 'included publication is returned');
        System.assertEquals('# Included', included.markdown);
    }
}