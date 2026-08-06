import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getForAccount from '@salesforce/apex/OCXPublishedContentController.getForAccount';
import OcxInteractiveViewerModal from 'c/ocxInteractiveViewerModal';

export default class OcxPublishedContent extends NavigationMixin(LightningElement) {
    @api recordId;
    publications = [];
    errorMessage;
    isLoading = true;

    @wire(getForAccount, { accountId: '$recordId' })
    wiredPublications({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.errorMessage = undefined;
            this.publications = data.map((row) => ({
                ...row,
                hasRenderedHtml: Boolean(row.renderedHtml),
                hasMarkdownOnly: !row.renderedHtml && Boolean(row.markdown),
                hasSummary: Boolean(row.summary),
                hasSourceUrl: Boolean(row.sourceUrl),
                hasViewerUrl: Boolean(row.viewerUrl),
                launchUrl: row.viewerUrl || row.sourceUrl,
                hasLaunchUrl: Boolean(row.viewerUrl || row.sourceUrl),
                hasPdf: Boolean(row.contentDocumentId),
                meta: [row.format, row.status, row.publishedBy].filter(Boolean).join(' • ')
            }));
        } else if (error) {
            this.publications = [];
            this.errorMessage = error?.body?.message || error?.message || 'Unable to load OCX publications.';
        }
    }

    get hasPublications() {
        return this.publications.length > 0;
    }



    async openReport(event) {
        const publicationId = event.currentTarget.dataset.id;
        const publication = this.publications.find(
            (item) => item.id === publicationId
        );

        const viewerUrl =
            publication?.launchUrl ||
            event.currentTarget.dataset.url;

        const reportTitle =
            publication?.title ||
            event.currentTarget.dataset.title ||
            'Customer AI Report';

        if (!viewerUrl || !viewerUrl.startsWith('https://')) {
            this.errorMessage =
                'This publication does not contain a valid HTTPS report URL.';
            return;
        }

        let aspectRatio =
            publication?.aspectRatio ||
            '16/9';

        let viewerLayout =
            publication?.viewerLayout ||
            'responsive';

        if (
            !/^[0-9]+(?:\.[0-9]+)?\/[0-9]+(?:\.[0-9]+)?$/
                .test(aspectRatio)
        ) {
            aspectRatio = '16/9';
        }

        if (
            !['document', 'presentation', 'responsive']
                .includes(viewerLayout)
        ) {
            viewerLayout = 'responsive';
        }

        const [width, height] =
            aspectRatio.split('/').map(Number);

        const modalSize =
            Number.isFinite(width) &&
            Number.isFinite(height) &&
            width > 0 &&
            height > 0 &&
            width / height < 1
                ? 'medium'
                : 'large';

        await OcxInteractiveViewerModal.open({
            label: reportTitle,
            size: modalSize,
            viewerUrl,
            reportTitle,
            aspectRatio,
            viewerLayout
        });
    }

    openRecord(event) {

        const recordId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'OCX_Published_Content__c',
                actionName: 'view'
            }
        });
    }

    previewPdf(event) {
        const selectedRecordId = event.currentTarget.dataset.documentId;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId }
        });
    }
}