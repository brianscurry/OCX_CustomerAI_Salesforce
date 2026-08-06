import { api } from 'lwc';
import LightningModal from 'lightning/modal';

export default class OcxInteractiveViewerModal extends LightningModal {
    @api viewerUrl;
    @api reportTitle;

    get safeViewerUrl() {
        const value =
            typeof this.viewerUrl === 'string'
                ? this.viewerUrl.trim()
                : '';

        return value.startsWith('https://') ? value : '';
    }

    get modalTitle() {
        const value =
            typeof this.reportTitle === 'string'
                ? this.reportTitle.trim()
                : '';

        return value || 'Interactive Viewer';
    }

    handleClose() {
        this.close();
    }
}
