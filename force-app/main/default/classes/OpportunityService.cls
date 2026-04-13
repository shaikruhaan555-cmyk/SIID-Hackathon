public with sharing class OpportunityService {
    private static final String DOCUMENTS_REQUESTED_STAGE = 'Documents Requested';
    private static final String SUBMITTED_STATUS = 'Submitted';

    public static void processDocumentsRequestedOpportunities(
        List<Opportunity> listNewOpportunities,
        Map<Id, Opportunity> mapOldOpportunityById
    ) {
        if (listNewOpportunities == null || listNewOpportunities.isEmpty() ||
            mapOldOpportunityById == null || mapOldOpportunityById.isEmpty()) {
            return;
        }

        List<Opportunity> listQualifiedOpportunities =
            getQualifiedOpportunities(listNewOpportunities, mapOldOpportunityById);

        if (listQualifiedOpportunities.isEmpty()) {
            return;
        }

        Map<Id, Contact> mapContactByOpportunityId =
            getContactByOpportunityId(listQualifiedOpportunities);

        createLoanApplications(listQualifiedOpportunities, mapContactByOpportunityId);

        Set<Id> setOnboardingContactIds = new Set<Id>();
        for (Contact conCurrent : mapContactByOpportunityId.values()) {
            if (conCurrent != null && conCurrent.Id != null &&
                !String.isBlank(conCurrent.Email)) {
                setOnboardingContactIds.add(conCurrent.Id);
            }
        }

        if (!setOnboardingContactIds.isEmpty()) {
            System.enqueueJob(
                new OpportunityCommunityOnboardingQueueable(
                    new List<Id>(setOnboardingContactIds)
                )
            );
        }
    }

    private static List<Opportunity> getQualifiedOpportunities(
        List<Opportunity> listNewOpportunities,
        Map<Id, Opportunity> mapOldOpportunityById
    ) {
        List<Opportunity> listQualifiedOpportunities = new List<Opportunity>();

        for (Opportunity oppCurrent : listNewOpportunities) {
            Opportunity oppOld = mapOldOpportunityById.get(oppCurrent.Id);
            if (oppOld == null) continue;

            Boolean isStageChanged = oppCurrent.StageName != oppOld.StageName;
            Boolean isDocumentsRequested =
                oppCurrent.StageName == DOCUMENTS_REQUESTED_STAGE;

            if (isStageChanged && isDocumentsRequested) {
                listQualifiedOpportunities.add(oppCurrent);
            }
        }

        return listQualifiedOpportunities;
    }

    private static Map<Id, Contact> getContactByOpportunityId(
        List<Opportunity> listQualifiedOpportunities
    ) {
        Map<Id, Contact> mapContactByOpportunityId = new Map<Id, Contact>();
        Set<Id> setOpportunityIds = new Set<Id>();

        for (Opportunity opp : listQualifiedOpportunities) {
            setOpportunityIds.add(opp.Id);
        }

        // ✅ Step 1: Get Primary Contact via OCR
        List<OpportunityContactRole> listPrimaryRoles = [
            SELECT OpportunityId, ContactId,
                   Contact.Id, Contact.Email, Contact.FirstName, Contact.LastName
            FROM OpportunityContactRole
            WHERE OpportunityId IN :setOpportunityIds
            AND IsPrimary = true
            WITH USER_MODE
        ];

        for (OpportunityContactRole ocr : listPrimaryRoles) {
            if (!mapContactByOpportunityId.containsKey(ocr.OpportunityId) &&
                ocr.ContactId != null) {
                mapContactByOpportunityId.put(ocr.OpportunityId, ocr.Contact);
            }
        }

        // ✅ Step 2: Collect Accounts needing fallback
        Set<Id> setFallbackAccountIds = new Set<Id>();
        for (Opportunity opp : listQualifiedOpportunities) {
            if (!mapContactByOpportunityId.containsKey(opp.Id) &&
                opp.AccountId != null) {
                setFallbackAccountIds.add(opp.AccountId);
            }
        }

        // ✅ Step 3: Query Accounts (IMPORTANT for Person Account)
        Map<Id, Account> mapAccountById = new Map<Id, Account>();
        if (!setFallbackAccountIds.isEmpty()) {
            mapAccountById = new Map<Id, Account>([
                SELECT Id, PersonContactId
                FROM Account
                WHERE Id IN :setFallbackAccountIds
                WITH USER_MODE
            ]);
        }

        // ✅ Step 4: Query Contacts for Business Accounts
        Map<Id, Contact> mapFallbackContactByAccountId = new Map<Id, Contact>();
        if (!setFallbackAccountIds.isEmpty()) {
            List<Contact> listFallbackContacts = [
                SELECT Id, AccountId, Email, FirstName, LastName
                FROM Contact
                WHERE AccountId IN :setFallbackAccountIds
                WITH USER_MODE
                ORDER BY CreatedDate ASC
            ];

            for (Contact con : listFallbackContacts) {
                if (!mapFallbackContactByAccountId.containsKey(con.AccountId)) {
                    mapFallbackContactByAccountId.put(con.AccountId, con);
                }
            }
        }

        // ✅ Step 5: Final Mapping (Person Account + Business Account)
        for (Opportunity opp : listQualifiedOpportunities) {
            if (!mapContactByOpportunityId.containsKey(opp.Id) &&
                opp.AccountId != null) {

                Account acc = mapAccountById.get(opp.AccountId);

                // 🔥 Person Account Handling
                if (acc != null && acc.PersonContactId != null) {
                    mapContactByOpportunityId.put(
                        opp.Id,
                        new Contact(Id = acc.PersonContactId)
                    );
                }
                // 🔥 Business Account Handling
                else if (mapFallbackContactByAccountId.containsKey(opp.AccountId)) {
                    mapContactByOpportunityId.put(
                        opp.Id,
                        mapFallbackContactByAccountId.get(opp.AccountId)
                    );
                }
            }
        }

        return mapContactByOpportunityId;
    }

    private static void createLoanApplications(
        List<Opportunity> listQualifiedOpportunities,
        Map<Id, Contact> mapContactByOpportunityId
    ) {
        List<Loan_Application__c> listLoanApplicationsToInsert =
            new List<Loan_Application__c>();

        for (Opportunity opp : listQualifiedOpportunities) {
            Contact con = mapContactByOpportunityId.get(opp.Id);

            Loan_Application__c loan = new Loan_Application__c();
            loan.Opportunity__c = opp.Id;
            loan.Account__c = opp.AccountId;
            loan.Contact__c = con != null ? con.Id : null;
            loan.Loan_Amount__c = opp.Amount;
            loan.Total_Repayment_Amount__c = opp.Amount;
            loan.Customer_Email__c = con.email;
            loan.Application_Status__c = SUBMITTED_STATUS;

            listLoanApplicationsToInsert.add(loan);
        }

        if (!listLoanApplicationsToInsert.isEmpty()) {
            insert listLoanApplicationsToInsert;
        }
    }
}