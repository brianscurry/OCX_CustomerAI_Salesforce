import { api } from 'lwc';
import LightningModal from 'lightning/modal';

const DEFAULT_RATIO = '16/9';
const DEFAULT_LAYOUT = 'responsive';
const VIEWER_ORIGIN = 'https://ocxagentpreview2.lovable.app';

export default class OcxInteractiveViewerModal extends LightningModal {
    @api viewerUrl;
    @api reportTitle;

    _aspectRatio = DEFAULT_RATIO;
    _viewerLayout = DEFAULT_LAYOUT;
    messageHandler;

    @api
    get aspectRatio() {
        return this._aspectRatio;
    }

    set aspectRatio(value) {
        this._aspectRatio = this.normalizeAspectRatio(value);
    }

    @api
    get viewerLayout() {
        return this._viewerLayout;
    }

    set viewerLayout(value) {
        this._viewerLayout = this.normalizeLayout(value);
    }

    connectedCallback() {
        this.messageHandler =
            this.handleViewerMessage.bind(this);

        window.addEventListener(
            'message',
            this.messageHandler
        );
    }

    disconnectedCallback() {
        window.removeEventListener(
            'message',
            this.messageHandler
        );
    }

    normalizeAspectRatio(value) {
        const candidate =
            typeof value === 'string'
                ? value.trim()
                : '';

        const match = candidate.match(
            /^([0-9]+(?:\.[0-9]+)?)\/([0-9]+(?:\.[0-9]+)?)$/
        );

        if (!match) {
            return DEFAULT_RATIO;
        }

        const width = Number(match[1]);
        const height = Number(match[2]);

        if (
            !Number.isFinite(width) ||
            !Number.isFinite(height) ||
            width <= 0 ||
            height <= 0
        ) {
            return DEFAULT_RATIO;
        }

        return `${width}/${height}`;
    }

    normalizeLayout(value) {
        return [
            'document',
            'presentation',
            'responsive'
        ].includes(value)
            ? value
            : DEFAULT_LAYOUT;
    }

    get safeViewerUrl() {
        const value =
            typeof this.viewerUrl === 'string'
                ? this.viewerUrl.trim()
                : '';

        return value.startsWith('https://')
            ? value
            : '';
    }

    get hasViewerUrl() {
        return Boolean(this.safeViewerUrl);
    }

    get isPortrait() {
        const [width, height] =
            this._aspectRatio.split('/').map(Number);

        return width / height < 1;
    }

    get viewerContainerClass() {
        return this.isPortrait
            ? 'viewer-container portrait'
            : 'viewer-container landscape';
    }

    get viewerStyle() {
        const [width, height] =
            this._aspectRatio.split('/').map(Number);

        return `aspect-ratio: ${width} / ${height};`;
    }

    handleViewerMessage(event) {
        if (
            event.origin !== VIEWER_ORIGIN ||
            event.data?.type !== 'OCX_VIEWER_LAYOUT'
        ) {
            return;
        }

        if (event.data.aspectRatio) {
            this._aspectRatio =
                this.normalizeAspectRatio(
                    event.data.aspectRatio
                );
        }

        if (event.data.layout) {
            this._viewerLayout =
                this.normalizeLayout(
                    event.data.layout
                );
        }
    }

    handleFrameLoad() {
        const frame =
            this.template.querySelector('iframe');

        if (!frame?.contentWindow) {
            return;
        }

        frame.contentWindow.postMessage(
            {
                type: 'OCX_VIEWER_REQUEST_LAYOUT'
            },
            VIEWER_ORIGIN
        );
    }

    handleClose() {
        this.close();
    }
}