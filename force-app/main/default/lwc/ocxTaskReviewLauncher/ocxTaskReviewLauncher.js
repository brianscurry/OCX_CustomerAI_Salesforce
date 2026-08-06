import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getReviewContext from '@salesforce/apex/OCXTaskReviewController.getReviewContext';
import completeTask from '@salesforce/apex/OCXTaskReviewController.completeTask';
import OcxInteractiveViewerModal from 'c/ocxInteractiveViewerModal';

export default class OcxTaskReviewLauncher extends LightningElement {
    _recordId;
    launched = false;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        this.launchWhenReady();
    }

    connectedCallback() {
        this.launchWhenReady();
    }

    async launchWhenReady() {
        if (!this._recordId || this.launched) {
            return;
        }

        this.launched = true;

        try {
            const contextValue = await getReviewContext({
                taskId: this._recordId
            });

            const viewerOptions = this.parseViewerOptions(
                contextValue.viewerUrl
            );

            const modalPromise = OcxInteractiveViewerModal.open({
                label: contextValue.title,
                size: viewerOptions.modalSize,
                viewerUrl: contextValue.viewerUrl,
                reportTitle: contextValue.title,
                aspectRatio: viewerOptions.aspectRatio,
                viewerLayout: viewerOptions.viewerLayout
            });

            await completeTask({ taskId: this._recordId });
            await modalPromise;

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Report reviewed',
                    message: 'The review task was completed.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Unable to open report',
                    message:
                        error?.body?.message ||
                        error?.message ||
                        'An unexpected error occurred.',
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.dispatchEvent(
                new CustomEvent('close', {
                    bubbles: true,
                    composed: true
                })
            );
        }
    }

    parseViewerOptions(viewerUrl) {
        let aspectRatio = '16/9';
        let viewerLayout = 'responsive';
        let modalSize = 'large';

        try {
            const parsedUrl = new URL(viewerUrl);
            const ratioValue = parsedUrl.searchParams.get('ar');
            const layoutValue = parsedUrl.searchParams.get('layout');

            if (
                ratioValue &&
                /^[0-9]+(?:\.[0-9]+)?\/[0-9]+(?:\.[0-9]+)?$/.test(
                    ratioValue
                )
            ) {
                aspectRatio = ratioValue;
                const [width, height] = ratioValue.split('/').map(Number);
                modalSize = width / height < 1 ? 'medium' : 'large';
            }

            if (
                ['document', 'presentation', 'responsive'].includes(
                    layoutValue
                )
            ) {
                viewerLayout = layoutValue;
            }
        } catch (error) {
            // Safe defaults are already set.
        }

        return {
            aspectRatio,
            viewerLayout,
            modalSize
        };
    }
}