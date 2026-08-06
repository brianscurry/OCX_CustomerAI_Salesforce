public with sharing class OCXExpansionLeadController {
    @AuraEnabled(cacheable=true)
    public static OCXExpansionLeadService.LeadView getLead(Id recordId) {
        return OCXExpansionLeadService.getLead(recordId);
    }

    @AuraEnabled
    public static OCXExpansionLeadService.LeadView acceptLead(Id recordId) {
        return OCXExpansionLeadService.acceptLead(recordId);
    }

    @AuraEnabled
    public static OCXExpansionLeadService.LeadView rejectLead(Id recordId, String reason) {
        return OCXExpansionLeadService.rejectLead(recordId, reason);
    }

    @AuraEnabled
    public static Opportunity convertLead(
        Id recordId,
        OCXExpansionLeadService.ConversionInput input
    ) {
        return OCXExpansionLeadService.convertLead(recordId, input);
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getActiveStages() {
        return OCXExpansionLeadService.getActiveStages();
    }
}
