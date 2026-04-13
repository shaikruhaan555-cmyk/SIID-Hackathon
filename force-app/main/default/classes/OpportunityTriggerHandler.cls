public with sharing class OpportunityTriggerHandler {
    public static void handleAfterUpdate(List<Opportunity> listNewOpportunities, Map<Id, Opportunity> mapOldOpportunityById) {
        OpportunityService.processDocumentsRequestedOpportunities(listNewOpportunities, mapOldOpportunityById);
    }
}