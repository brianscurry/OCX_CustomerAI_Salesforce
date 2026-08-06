import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import OcxInteractiveViewerModal from 'c/ocxInteractiveViewerModal';
import getPortfolios from '@salesforce/apex/OCXPortfolioExplorerController.getPortfolios';
import getPortfolioSummary from '@salesforce/apex/OCXPortfolioExplorerController.getPortfolioSummary';
import getAccounts from '@salesforce/apex/OCXPortfolioExplorerController.getAccounts';
import getPublishedContent from '@salesforce/apex/OCXPortfolioExplorerController.getPublishedContent';
import getDeployments from '@salesforce/apex/OCXPortfolioActionDeploymentController.getDeployments';
import deployPlan from '@salesforce/apex/OCXPortfolioActionDeploymentController.deployPlan';
import deactivateDeployment from '@salesforce/apex/OCXPortfolioActionDeploymentController.deactivateDeployment';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const PAGE_SIZE = 50;

const ACCOUNT_COLUMNS = [
    {
        label: 'Account',
        fieldName: 'name',
        type: 'button',
        typeAttributes: {
            label: { fieldName: 'name' },
            name: 'open_account',
            variant: 'base'
        }
    },
    { label: 'ACV', fieldName: 'acv', type: 'currency' },
    { label: 'NPS Class', fieldName: 'npsClass', type: 'text' },
    { label: 'Propensity', fieldName: 'propensity', type: 'text' },
    { label: 'Revenue Band', fieldName: 'revenueBand', type: 'text' },
    { label: 'Renewal Quarter', fieldName: 'renewalQuarter', type: 'text' },
    { label: 'Open Tickets', fieldName: 'openTickets', type: 'number' },
    { label: 'Primary Product', fieldName: 'primaryProduct', type: 'text' }
];

const PUBLISHED_COLUMNS = [
    {
        label: 'Title',
        fieldName: 'title',
        type: 'button',
        typeAttributes: {
            label: { fieldName: 'title' },
            name: 'open_content',
            variant: 'base'
        }
    },
    { label: 'Format', fieldName: 'formatLabel', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'Published', fieldName: 'publishedAt', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
    { label: 'Summary', fieldName: 'summary', type: 'text', wrapText: true },
    {
        label: 'Actions',
        type: 'button',
        fixedWidth: 155,
        typeAttributes: {
            label: { fieldName: 'deployLabel' },
            name: 'deploy_actions',
            variant: 'brand-outline',
            disabled: { fieldName: 'deployDisabled' }
        }
    },
    { type: 'action', typeAttributes: { rowActions: { fieldName: 'rowActions' } } }
];

const DEPLOYMENT_COLUMNS = [
    { label: 'Plan', fieldName: 'publicationTitle', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'Accounts', fieldName: 'accountCount', type: 'number' },
    { label: 'CTAs', fieldName: 'ctaCount', type: 'number' },
    { label: 'Tasks', fieldName: 'taskCount', type: 'number' },
    { label: 'Deployed', fieldName: 'deployedAt', type: 'date' },
    {
        label: 'Actions',
        type: 'button',
        fixedWidth: 190,
        typeAttributes: {
            label: 'Deactivate Deployment',
            name: 'deactivate',
            variant: 'destructive-text',
            disabled: { fieldName: 'deactivateDisabled' }
        }
    },
    { type: 'action', typeAttributes: { rowActions: { fieldName: 'rowActions' } } }
];

export default class OcxPortfolioExplorer extends NavigationMixin(LightningElement) {
    portfolioSearch = '';
    accountSearch = '';
    portfolios = [];
    selectedPortfolioId;
    summary;
    accountRows = [];
    publishedRows = [];
    deploymentRows = [];
    selectedPublication;
    isLoading = false;
    deployingPublicationId;
    deploymentPollTimer;
    deploymentPollPublicationId;
    deploymentPollAttempts = 0;
    errorMessage;
    nextCursor;
    currentCursor;
    cursorHistory = [];
    pageNumber = 1;
    searchTimer;

    accountColumns = ACCOUNT_COLUMNS;
    publishedColumns = PUBLISHED_COLUMNS;
    deploymentColumns = DEPLOYMENT_COLUMNS;

    connectedCallback() {
        this.loadPortfolios();
    }

    get portfolioOptions() {
        return this.portfolios.map((portfolio) => ({
            label: `${portfolio.name} (${Number(portfolio.storedAccountCount || 0).toLocaleString()})`,
            value: portfolio.id
        }));
    }

    get hasPortfolio() {
        return Boolean(this.summary);
    }

    get formattedTotalAcv() {
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: 'USD',
            maximumFractionDigits: 0,
            notation: 'compact'
        }).format(Number(this.summary?.totalAcv || 0));
    }

    get formattedOpenTickets() {
        return Number(this.summary?.openTickets || 0).toLocaleString();
    }

    get npsDistribution() {
        return this.withPercent(this.summary?.npsDistribution);
    }

    get propensityDistribution() {
        return this.withPercent(this.summary?.propensityDistribution);
    }

    get portfolioNps() {
        const items = this.summary?.npsDistribution || [];
        const total = items.reduce((sum, item) => sum + Number(item.count || 0), 0);
        if (!total) {
            return '—';
        }
        const promoters = this.findDistributionCount(items, 'promoter');
        const detractors = this.findDistributionCount(items, 'detractor');
        return Math.round(((promoters - detractors) / total) * 100);
    }

    get accountsTabLabel() {
        const count = Number(this.summary?.accountCount || 0).toLocaleString();
        return `Accounts (${count})`;
    }

    get publishedTabLabel() {
        return `Published OCX Analytics (${this.publishedRows.length})`;
    }

    get hasPublishedContent() {
        return this.publishedRows.length > 0;
    }

    get hasDeployments() {
        return this.deploymentRows.length > 0;
    }

    get previousDisabled() {
        return this.cursorHistory.length === 0 || this.isLoading;
    }

    get nextDisabled() {
        return !this.nextCursor || this.isLoading;
    }

    get selectedStaticContent() {
        return Boolean(
            this.selectedPublication &&
            ['MARKDOWN', 'STATIC_HTML'].includes(this.selectedPublication.format) &&
            this.selectedPublication.renderedHtml
        );
    }

    async loadPortfolios() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.portfolios = await getPortfolios({ searchTerm: this.portfolioSearch });
            if (!this.selectedPortfolioId && this.portfolios.length > 0) {
                this.selectedPortfolioId = this.portfolios[0].id;
                await this.loadSelectedPortfolio();
            } else if (this.selectedPortfolioId && !this.portfolios.some((item) => item.id === this.selectedPortfolioId)) {
                this.selectedPortfolioId = this.portfolios[0]?.id;
                if (this.selectedPortfolioId) {
                    await this.loadSelectedPortfolio();
                } else {
                    this.clearPortfolio();
                }
            }
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadSelectedPortfolio() {
        if (!this.selectedPortfolioId) {
            this.clearPortfolio();
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        this.resetAccountPaging();
        try {
            const [summary, accountPage, publications, deployments] = await Promise.all([
                getPortfolioSummary({ portfolioId: this.selectedPortfolioId }),
                getAccounts({
                    portfolioId: this.selectedPortfolioId,
                    searchTerm: this.accountSearch,
                    pageSize: PAGE_SIZE,
                    afterName: null,
                    afterId: null
                }),
                getPublishedContent({ portfolioId: this.selectedPortfolioId }),
                getDeployments({ portfolioId: this.selectedPortfolioId })
            ]);
            this.summary = summary;
            this.applyAccountPage(accountPage);
            this.deploymentRows = this.mapDeploymentRows(deployments || []);
            this.publishedRows = this.mapPublishedRows(
                publications || [],
                this.deploymentRows
            );
            this.selectedPublication = undefined;
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadAccountPage(cursor) {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const page = await getAccounts({
                portfolioId: this.selectedPortfolioId,
                searchTerm: this.accountSearch,
                pageSize: PAGE_SIZE,
                afterName: cursor?.afterName || null,
                afterId: cursor?.afterId || null
            });
            this.currentCursor = cursor;
            this.applyAccountPage(page);
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    applyAccountPage(page) {
        this.accountRows = page?.rows || [];
        this.nextCursor = page?.hasMore
            ? { afterName: page.nextAfterName, afterId: page.nextAfterId }
            : undefined;
    }

    handlePortfolioSearch(event) {
        this.portfolioSearch = event.target.value;
        window.clearTimeout(this.searchTimer);
        this.searchTimer = window.setTimeout(() => this.loadPortfolios(), 300);
    }

    handlePortfolioChange(event) {
        this.selectedPortfolioId = event.detail.value;
        this.loadSelectedPortfolio();
    }

    handleAccountSearch(event) {
        this.accountSearch = event.target.value;
        window.clearTimeout(this.searchTimer);
        this.searchTimer = window.setTimeout(() => {
            this.resetAccountPaging();
            this.loadAccountPage(undefined);
        }, 300);
    }

    handleRefresh() {
        this.loadSelectedPortfolio();
    }

    handleNextPage() {
        if (!this.nextCursor) {
            return;
        }
        this.cursorHistory = [...this.cursorHistory, this.currentCursor];
        this.pageNumber += 1;
        this.loadAccountPage(this.nextCursor);
    }

    handlePreviousPage() {
        if (this.cursorHistory.length === 0) {
            return;
        }
        const history = [...this.cursorHistory];
        const previousCursor = history.pop();
        this.cursorHistory = history;
        this.pageNumber = Math.max(1, this.pageNumber - 1);
        this.loadAccountPage(previousCursor);
    }

    handleAccountRowAction(event) {
        if (event.detail.action.name === 'open_account') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: event.detail.row.id,
                    objectApiName: 'Account',
                    actionName: 'view'
                }
            });
        }
    }

    mapDeploymentRows(deployments) {
        return deployments.map((item) => {
            const canDeactivate = ['ACTIVE', 'PARTIALLY_FAILED'].includes(item.status);
            return {
                ...item,
                deactivateDisabled: !canDeactivate,
                rowActions: canDeactivate
                    ? [{ label: 'Deactivate and Withdraw Incomplete Actions', name: 'deactivate' }]
                    : []
            };
        });
    }

    mapPublishedRows(publications, deployments) {
        const latestByPublication = new Map();
        deployments.forEach((deployment) => {
            if (deployment.publicationId && !latestByPublication.has(deployment.publicationId)) {
                latestByPublication.set(deployment.publicationId, deployment);
            }
        });

        return publications.map((item) => {
            const deployment = latestByPublication.get(item.id);
            const status = deployment?.status;
            const blocked = ['DEPLOYING', 'ACTIVE', 'PARTIALLY_FAILED', 'DEACTIVATING'].includes(status);
            const label = status === 'DEPLOYING'
                ? 'Deploying…'
                : (['ACTIVE', 'PARTIALLY_FAILED', 'DEACTIVATING'].includes(status) ? 'Deployed' : 'Deploy Actions');

            return {
                ...item,
                formatLabel: this.formatLabel(item.format),
                deployLabel: label,
                deployDisabled: !item.actionPlan || blocked,
                rowActions: item.actionPlan && !blocked
                    ? [{ label: 'Open', name: 'open_content' }, { label: 'Deploy Actions to All Accounts', name: 'deploy_actions' }]
                    : [{ label: 'Open', name: 'open_content' }]
            };
        });
    }

    async refreshDeploymentState() {
        try {
            const deployments = await getDeployments({ portfolioId: this.selectedPortfolioId });
            this.deploymentRows = this.mapDeploymentRows(deployments || []);
            this.publishedRows = this.mapPublishedRows(this.publishedRows, this.deploymentRows);
            return this.deploymentRows;
        } catch (error) {
            console.error('Unable to refresh Portfolio deployment state', error);
            return [];
        }
    }

    startDeploymentPolling(publicationId) {
        this.stopDeploymentPolling();
        this.deploymentPollPublicationId = publicationId;
        this.deploymentPollAttempts = 0;

        this.deploymentPollTimer = window.setInterval(async () => {
            this.deploymentPollAttempts += 1;
            const deployments = await this.refreshDeploymentState();
            const deployment = deployments.find(
                (item) => item.publicationId === this.deploymentPollPublicationId
            );

            if (!deployment) {
                if (this.deploymentPollAttempts >= 120) {
                    this.stopDeploymentPolling();
                }
                return;
            }

            if (['ACTIVE', 'PARTIALLY_FAILED'].includes(deployment.status)) {
                this.stopDeploymentPolling();
                this.toast(
                    'Deployment complete',
                    deployment.status === 'PARTIALLY_FAILED'
                        ? 'Actions were deployed, but some Accounts failed. Review Action Deployments for details.'
                        : 'Actions were deployed to the Portfolio Accounts.',
                    deployment.status === 'PARTIALLY_FAILED' ? 'warning' : 'success'
                );
                return;
            }

            if (deployment.status === 'FAILED') {
                this.stopDeploymentPolling();
                this.toast(
                    'Deployment failed',
                    'No additional deployment will be started automatically. Review Action Deployments for details.',
                    'error'
                );
                return;
            }

            if (this.deploymentPollAttempts >= 120) {
                this.stopDeploymentPolling();
                this.toast(
                    'Deployment still running',
                    'Status updates stopped after 10 minutes. Use Refresh to check again.',
                    'info'
                );
            }
        }, 5000);
    }

    stopDeploymentPolling() {
        if (this.deploymentPollTimer) {
            window.clearInterval(this.deploymentPollTimer);
        }

        this.deploymentPollTimer = undefined;
        this.deploymentPollPublicationId = undefined;
        this.deploymentPollAttempts = 0;
    }

    disconnectedCallback() {
        this.stopDeploymentPolling();
    }

    async handlePublishedRowAction(event) {
        const publication = event.detail.row;
        if (event.detail.action.name === 'deploy_actions') {
            if (this.deployingPublicationId) return;
            if (!window.confirm(`Deploy all CTAs in ${publication.title} to every current Account in this Portfolio?`)) return;

            this.deployingPublicationId = publication.id;
            this.publishedRows = this.publishedRows.map((item) => item.id === publication.id
                ? { ...item, deployLabel: 'Deploying…', deployDisabled: true }
                : item
            );

            try {
                await deployPlan({ publicationId: publication.id });
                this.toast('Deployment started', 'Salesforce is processing Accounts in batches. You can continue using this page.', 'success');
                await this.refreshDeploymentState();
                this.startDeploymentPolling(publication.id);
            } catch (error) {
                this.handleError(error);
                await this.refreshDeploymentState();
            } finally {
                this.deployingPublicationId = undefined;
            }
            return;
        }
        this.selectedPublication = publication;

        if (publication.format === 'PDF' && publication.contentDocumentId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'filePreview' },
                state: { selectedRecordId: publication.contentDocumentId }
            });
            return;
        }

        if (publication.format === 'INTERACTIVE_HTML' && publication.viewerUrl) {
            await OcxInteractiveViewerModal.open({
                viewerUrl: publication.viewerUrl,
                reportTitle: publication.title,
                aspectRatio: publication.aspectRatio,
                viewerLayout: publication.viewerLayout
            });
        }
    }

async handleDeploymentRowAction(event) {
        if (event.detail.action.name !== 'deactivate') return;
        const row = event.detail.row;
        if (!window.confirm('Deactivate this deployment? Incomplete inherited actions will be withdrawn from Accounts; completed actions will remain.')) return;
        this.isLoading = true;
        try { await deactivateDeployment({ deploymentId: row.id }); this.toast('Deactivation started', 'Incomplete actions are being withdrawn.', 'success'); await this.loadSelectedPortfolio(); }
        catch (error) { this.handleError(error); }
        finally { this.isLoading = false; }
    }

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }

    openPortfolioRecord() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.selectedPortfolioId,
                objectApiName: 'OCX_Portfolio__c',
                actionName: 'view'
            }
        });
    }

    resetAccountPaging() {
        this.currentCursor = undefined;
        this.nextCursor = undefined;
        this.cursorHistory = [];
        this.pageNumber = 1;
    }

    clearPortfolio() {
        this.summary = undefined;
        this.accountRows = [];
        this.publishedRows = [];
        this.deploymentRows = [];
        this.selectedPublication = undefined;
        this.resetAccountPaging();
    }

    withPercent(items) {
        const safeItems = items || [];
        const total = safeItems.reduce((sum, item) => sum + Number(item.count || 0), 0);
        return safeItems.map((item) => ({
            ...item,
            percent: total ? Math.round((Number(item.count || 0) / total) * 1000) / 10 : 0
        }));
    }

    findDistributionCount(items, label) {
        const match = items.find((item) => String(item.label || '').toLowerCase() === label);
        return Number(match?.count || 0);
    }

    formatLabel(format) {
        const labels = {
            MARKDOWN: 'Markdown',
            STATIC_HTML: 'Static HTML',
            INTERACTIVE_HTML: 'Interactive HTML',
            PDF: 'PDF'
        };
        return labels[format] || format || 'Unknown';
    }

    handleError(error) {
        this.errorMessage = error?.body?.message || error?.message || 'Salesforce could not load the portfolio data.';
    }
}