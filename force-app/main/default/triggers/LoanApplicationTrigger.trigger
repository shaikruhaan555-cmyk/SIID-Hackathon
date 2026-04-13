trigger LoanApplicationTrigger on Loan_Application__c (after update) {
    LoanApplicationTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
}