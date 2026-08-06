import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getLead from '@salesforce/apex/OCXExpansionLeadController.getLead';
import acceptLead from '@salesforce/apex/OCXExpansionLeadController.acceptLead';
import rejectLead from '@salesforce/apex/OCXExpansionLeadController.rejectLead';
import convertLead from '@salesforce/apex/OCXExpansionLeadController.convertLead';
import getActiveStages from '@salesforce/apex/OCXExpansionLeadController.getActiveStages';

export default class OcxExpansionLeadActions extends NavigationMixin(LightningElement) {
    @api recordId;
    lead;
    loading = false;
    showReject = false;
    rejectReason = '';
    opportunityName = '';
    amount;
    closeDate;
    stageName;
    stageOptions = [];

    connectedCallback() {
        this.initialize();
    }

    async initialize() {
        this.loading = true;
        try {
            const [lead, stages] = await Promise.all([
                getLead({ recordId: this.recordId }),
                getActiveStages()
            ]);
            this.applyLead(lead);
            this.stageOptions = stages.map(value => ({ label: value, value }));
            if (!this.stageName && this.stageOptions.length) {
                this.stageName = this.stageOptions[0].value;
            }
        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    get isOpen() {
        return this.lead && !['Accepted', 'Rejected', 'Converted', 'Expired'].includes(this.lead.status);
    }

    get isAccepted() {
        return this.lead?.status === 'Accepted';
    }

    applyLead(value) {
        this.lead = value;
        if (!this.opportunityName && value?.accountName) {
            const product = value.recommendedProduct ? ` - ${value.recommendedProduct}` : ' - Expansion';
            this.opportunityName = `${value.accountName}${product}`;
        }
        if (this.amount == null && value?.estimatedValue != null) {
            this.amount = value.estimatedValue;
        }
        if (!this.closeDate) {
            const date = new Date();
            date.setDate(date.getDate() + 90);
            this.closeDate = date.toISOString().slice(0, 10);
        }
    }

    async handleAccept() {
        await this.run(async () => {
            this.applyLead(await acceptLead({ recordId: this.recordId }));
            this.toast('Accepted', 'The Expansion Lead is ready for Opportunity creation.', 'success');
        });
    }

    toggleReject() {
        this.showReject = !this.showReject;
    }

    handleRejectReason(event) {
        this.rejectReason = event.target.value;
    }

    async handleReject() {
        await this.run(async () => {
            this.applyLead(await rejectLead({ recordId: this.recordId, reason: this.rejectReason }));
            this.showReject = false;
            this.toast('Rejected', 'The Expansion Lead was rejected.', 'success');
        });
    }

    handleInput(event) {
        this[event.target.dataset.field] = event.detail?.value ?? event.target.value;
    }

    async handleConvert() {
        await this.run(async () => {
            const opportunity = await convertLead({
                recordId: this.recordId,
                input: {
                    opportunityName: this.opportunityName,
                    amount: this.amount === '' || this.amount == null ? null : Number(this.amount),
                    closeDate: this.closeDate,
                    stageName: this.stageName
                }
            });
            this.toast('Opportunity created', opportunity.Name, 'success');
            await this.initialize();
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: opportunity.Id,
                    objectApiName: 'Opportunity',
                    actionName: 'view'
                }
            });
        });
    }

    async run(action) {
        this.loading = true;
        try {
            await action();
        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    message(error) {
        return error?.body?.message || error?.message || 'Unexpected error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
