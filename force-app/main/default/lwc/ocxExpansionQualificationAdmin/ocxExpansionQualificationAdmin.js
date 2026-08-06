import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listRules from '@salesforce/apex/OCXExpansionAdminController.listRules';
import getRule from '@salesforce/apex/OCXExpansionAdminController.getRule';
import getAccountFields from '@salesforce/apex/OCXExpansionAdminController.getAccountFields';
import saveRule from '@salesforce/apex/OCXExpansionAdminController.saveRule';
import testRule from '@salesforce/apex/OCXExpansionAdminController.testRule';
import runRule from '@salesforce/apex/OCXExpansionAdminController.runRule';

export default class OcxExpansionQualificationAdmin extends LightningElement {
    @track rules = [];
    @track fields = [];
    @track conditions = [];
    selectedRuleId;
    ruleName = '';
    matchType = 'All';
    active = true;
    description = '';
    message = '';
    sampleAccounts = [];

    matchOptions = [
        { label: 'All conditions', value: 'All' },
        { label: 'Any condition', value: 'Any' }
    ];

    operatorOptions = [
        'Equals', 'Not Equal', 'Greater Than', 'Greater Than or Equal',
        'Less Than', 'Less Than or Equal', 'Contains', 'In', 'Is Blank', 'Is Not Blank'
    ].map(value => ({ label: value, value }));

    async connectedCallback() {
        await this.refreshMetadata();
        this.newRule();
    }

    get ruleOptions() {
        return [{ label: 'New Rule', value: 'NEW' }, ...this.rules.map(r => ({ label: r.OCX_Rule_Name__c, value: r.Id }))];
    }

    get fieldOptions() {
        return this.fields.map(f => ({ label: f.label, value: f.apiName }));
    }

    async refreshMetadata() {
        [this.rules, this.fields] = await Promise.all([listRules(), getAccountFields()]);
    }

    newRule() {
        this.selectedRuleId = 'NEW';
        this.ruleName = '';
        this.matchType = 'All';
        this.active = true;
        this.description = '';
        this.conditions = [this.blankCondition()];
        this.message = '';
        this.sampleAccounts = [];
    }

    blankCondition() {
        return { key: `${Date.now()}-${Math.random()}`, fieldApiName: '', fieldLabel: '', dataType: '', operator: 'Equals', value: '' };
    }

    async handleRuleChange(event) {
        const value = event.detail.value;
        if (value === 'NEW') {
            this.newRule();
            return;
        }
        this.selectedRuleId = value;
        const bundle = await getRule({ ruleId: value });
        this.ruleName = bundle.rule.OCX_Rule_Name__c;
        this.matchType = bundle.rule.OCX_Match_Type__c;
        this.active = bundle.rule.OCX_Active__c;
        this.description = bundle.rule.OCX_Description__c || '';
        this.conditions = bundle.conditions.map(c => ({
            key: c.Id,
            id: c.Id,
            fieldApiName: c.OCX_Field_API_Name__c,
            fieldLabel: c.OCX_Field_Label__c,
            dataType: c.OCX_Data_Type__c,
            operator: c.OCX_Operator__c,
            value: c.OCX_Value__c || ''
        }));
    }

    handleHeaderChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.type === 'checkbox' ? event.target.checked : event.detail?.value ?? event.target.value;
    }

    handleConditionChange(event) {
        const index = Number(event.target.dataset.index);
        const action = event.target.dataset.action;
        const rows = [...this.conditions];
        const row = { ...rows[index] };
        const value = event.detail?.value ?? event.target.value;
        if (action === 'field') {
            const descriptor = this.fields.find(f => f.apiName === value);
            row.fieldApiName = value;
            row.fieldLabel = descriptor?.label || value;
            row.dataType = descriptor?.dataType || 'String';
        } else if (action === 'operator') {
            row.operator = value;
        } else {
            row.value = value;
        }
        rows[index] = row;
        this.conditions = rows;
    }

    addCondition() {
        this.conditions = [...this.conditions, this.blankCondition()];
    }

    removeCondition(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.conditions = this.conditions.filter((_, i) => i !== index);
        if (!this.conditions.length) this.addCondition();
    }

    buildRule() {
        return {
            Id: this.selectedRuleId === 'NEW' ? null : this.selectedRuleId,
            OCX_Rule_Name__c: this.ruleName,
            OCX_Active__c: this.active,
            OCX_Match_Type__c: this.matchType,
            OCX_Description__c: this.description
        };
    }

    buildConditions() {
        return this.conditions.map((c, index) => ({
            OCX_Sequence__c: index + 1,
            OCX_Field_API_Name__c: c.fieldApiName,
            OCX_Field_Label__c: c.fieldLabel,
            OCX_Data_Type__c: c.dataType,
            OCX_Operator__c: c.operator,
            OCX_Value__c: c.value,
            OCX_Active__c: true
        }));
    }

    async save() {
        try {
            const result = await saveRule({ ruleRecord: this.buildRule(), conditionRecords: this.buildConditions() });
            this.selectedRuleId = result.ruleId;
            await this.refreshMetadata();
            this.toast('Saved', `${result.conditionCount} conditions saved.`, 'success');
        } catch (e) {
            this.handleError(e);
        }
    }

    async test() {
        try {
            if (this.selectedRuleId === 'NEW') await this.save();
            const result = await testRule({ ruleId: this.selectedRuleId, sampleLimit: 10 });
            this.message = `${result.matchCount} Accounts match this rule.`;
            this.sampleAccounts = result.sampleAccounts || [];
        } catch (e) {
            this.handleError(e);
        }
    }

    async run() {
        try {
            if (this.selectedRuleId === 'NEW') await this.save();
            const result = await runRule({ ruleId: this.selectedRuleId });
            this.message = `Matched ${result.matchedCount}; created ${result.createdCount}; updated ${result.updatedCount}; skipped ${result.skippedCount}.`;
            this.sampleAccounts = [];
            this.toast('Rule completed', this.message, 'success');
        } catch (e) {
            this.handleError(e);
        }
    }

    handleError(error) {
        const message = error?.body?.message || error?.message || 'Unexpected error';
        this.message = message;
        this.toast('Error', message, 'error');
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
