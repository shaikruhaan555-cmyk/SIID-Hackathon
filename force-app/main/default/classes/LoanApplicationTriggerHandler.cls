public with sharing class LoanApplicationTriggerHandler {
    private static final String STATUS_APPROVED = 'Approved';
    private static final String ORG_WIDE_EMAIL_ADDRESS_ID = '0D2DO0000004Cv20AE';
    private static final Integer EMAIL_LIMIT_PER_TRANSACTION = 10;

    public static void handleAfterUpdate(
        List<Loan_Application__c> listLoanApplications,
        Map<Id, Loan_Application__c> mapOldLoanApplicationById
    ) {
        if (listLoanApplications == null || listLoanApplications.isEmpty() || mapOldLoanApplicationById == null) {
            return;
        }

        List<Messaging.SingleEmailMessage> listEmailsToSend = new List<Messaging.SingleEmailMessage>();

        for (Loan_Application__c loanApplication : listLoanApplications) {
            Loan_Application__c oldLoanApplication = mapOldLoanApplicationById.get(loanApplication.Id);

            if (!isEligibleForApprovalEmail(loanApplication, oldLoanApplication)) {
                continue;
            }

            Decimal decLoanAmount = loanApplication.Total_Repayment_Amount__c;
            Decimal decAnnualInterestRate = loanApplication.Interest_Rate__c;
            Integer intRepaymentTenureMonths = loanApplication.Repayment_Tenure_Months__c == null
                ? null
                : Integer.valueOf(loanApplication.Repayment_Tenure_Months__c);

            if (decLoanAmount == null || decLoanAmount <= 0 ||
                decAnnualInterestRate == null ||
                intRepaymentTenureMonths == null ||
                intRepaymentTenureMonths <= 0) {
                System.debug(LoggingLevel.WARN, 'Skipping email for Loan: ' + loanApplication.Id);
                continue;
            }

            Decimal decEmiAmount = calculateEmi(decLoanAmount, decAnnualInterestRate, intRepaymentTenureMonths);
            List<AmortizationRowWrapper> listAmortizationRows = buildAmortizationSchedule(
                decLoanAmount,
                decAnnualInterestRate,
                intRepaymentTenureMonths,
                decEmiAmount
            );
            String strHtmlBody = buildApprovalEmailBody(loanApplication, decEmiAmount, listAmortizationRows);

            Messaging.SingleEmailMessage emailMessage = new Messaging.SingleEmailMessage();
            emailMessage.setToAddresses(new String[] { loanApplication.Customer_Email__c });
            emailMessage.setOrgWideEmailAddressId(ORG_WIDE_EMAIL_ADDRESS_ID);
            emailMessage.setSubject('Loan Approved - EMI Details');
            emailMessage.setHtmlBody(strHtmlBody);
            emailMessage.setSaveAsActivity(false);
            emailMessage.setUseSignature(false);
            listEmailsToSend.add(emailMessage);

            if (listEmailsToSend.size() == EMAIL_LIMIT_PER_TRANSACTION) {
                sendEmails(listEmailsToSend);
                listEmailsToSend.clear();
            }
        }

        if (!listEmailsToSend.isEmpty()) {
            sendEmails(listEmailsToSend);
        }
    }

    private static Boolean isEligibleForApprovalEmail(
        Loan_Application__c loanApplication,
        Loan_Application__c oldLoanApplication
    ) {
        if (loanApplication == null || oldLoanApplication == null) {
            return false;
        }
        if (String.isBlank(loanApplication.Customer_Email__c)) {
            return false;
        }
        String strNewStatus = loanApplication.Application_Status__c;
        String strOldStatus = oldLoanApplication.Application_Status__c;
        return strNewStatus == STATUS_APPROVED && strOldStatus != STATUS_APPROVED;
    }

    private static Decimal calculateEmi(
        Decimal decPrincipalAmount,
        Decimal decAnnualInterestRate,
        Integer intTenureMonths
    ) {
        if (decAnnualInterestRate == 0) {
            return (decPrincipalAmount / intTenureMonths).setScale(2);
        }
        Decimal decMonthlyInterestRate = (decAnnualInterestRate / 12) / 100;
        Double dblMonthlyInterestRate = Double.valueOf(String.valueOf(decMonthlyInterestRate));
        Double dblCompoundedRate = Math.pow(1 + dblMonthlyInterestRate, intTenureMonths);
        Double dblNumerator = Double.valueOf(String.valueOf(decPrincipalAmount)) * dblMonthlyInterestRate * dblCompoundedRate;
        Double dblDenominator = dblCompoundedRate - 1;
        if (dblDenominator == 0) {
            return (decPrincipalAmount / intTenureMonths).setScale(2);
        }
        return Decimal.valueOf(dblNumerator / dblDenominator).setScale(2);
    }

    private static List<AmortizationRowWrapper> buildAmortizationSchedule(
        Decimal decPrincipalAmount,
        Decimal decAnnualInterestRate,
        Integer intTenureMonths,
        Decimal decEmiAmount
    ) {
        List<AmortizationRowWrapper> listAmortizationRows = new List<AmortizationRowWrapper>();
        Decimal decRemainingBalance = decPrincipalAmount;
        Decimal decMonthlyInterestRate = ((decAnnualInterestRate / 12) / 100);
        Date dtCurrentMonth = Date.today().toStartOfMonth();

        for (Integer intMonthIndex = 1; intMonthIndex <= intTenureMonths; intMonthIndex++) {
            Decimal decInterestComponent = (decRemainingBalance * decMonthlyInterestRate).setScale(2);
            Decimal decPrincipalComponent = (decEmiAmount - decInterestComponent).setScale(2);
            Decimal decInstallmentAmount = decEmiAmount.setScale(2);

            if (intMonthIndex == intTenureMonths || decPrincipalComponent > decRemainingBalance) {
                decPrincipalComponent = decRemainingBalance.setScale(2);
                decInstallmentAmount = (decPrincipalComponent + decInterestComponent).setScale(2);
            }

            decRemainingBalance = (decRemainingBalance - decPrincipalComponent).setScale(2);
            if (decRemainingBalance < 0) {
                decRemainingBalance = 0;
            }

            Date dtInstallmentMonth = dtCurrentMonth.addMonths(intMonthIndex - 1);
            listAmortizationRows.add(new AmortizationRowWrapper(
                formatMonthName(dtInstallmentMonth),
                decInstallmentAmount,
                decInterestComponent,
                decPrincipalComponent,
                decRemainingBalance
            ));
        }
        return listAmortizationRows;
    }

    private static String buildApprovalEmailBody(
        Loan_Application__c loanApplication,
        Decimal decEmiAmount,
        List<AmortizationRowWrapper> listAmortizationRows
    ) {
        // ✅ Short style variables to prevent quoted-printable encoding corruption
        String sBdr = 'border:1px solid #ccc;';
        String sPad = 'padding:8px;';
        String sTh  = sPad + sBdr + 'background:#1f2937;color:#fff;';
        String sTdL = sPad + sBdr + 'text-align:left;';
        String sTdR = sPad + sBdr + 'text-align:right;';
        String sEven = 'background:#f9fafb;';
        String sOdd  = 'background:#e5e7eb;';

        String strCustomerName = String.isBlank(loanApplication.Name)
            ? 'Customer'
            : escapeHtml(loanApplication.Name);

        List<String> parts = new List<String>();

        parts.add('<html><body>');
        parts.add('<div style="font-family:Arial,sans-serif;padding:20px;">');
        parts.add('<div style="max-width:800px;margin:0 auto;background:#fff;">');
        parts.add('<div style="background:#1f2937;color:#fff;padding:16px;font-size:20px;">');
        parts.add('Loan Approval Summary</div>');
        parts.add('<div style="padding:20px;">');
        parts.add('<p>Dear ' + strCustomerName + ',</p>');
        parts.add('<p>Your loan has been approved.</p>');
        parts.add('<p>Monthly EMI: <b>' + formatCurrency(decEmiAmount) + '</b></p>');
        parts.add('<table cellpadding="0" cellspacing="0"');
        parts.add(' style="border-collapse:collapse;width:100%;">');
        parts.add('<tr>');
        parts.add('<th style="' + sTh + 'text-align:left;">Month</th>');
        parts.add('<th style="' + sTh + 'text-align:right;">EMI</th>');
        parts.add('<th style="' + sTh + 'text-align:right;">Interest</th>');
        parts.add('<th style="' + sTh + 'text-align:right;">Principal</th>');
        parts.add('<th style="' + sTh + 'text-align:right;">Balance</th>');
        parts.add('</tr>');

        for (Integer i = 0; i < listAmortizationRows.size(); i++) {
            AmortizationRowWrapper row = listAmortizationRows[i];
            String sBg = (Math.mod(i, 2) == 0) ? sEven : sOdd;
            parts.add('<tr style="' + sBg + '">');
            parts.add('<td style="' + sTdL + '">' + escapeHtml(row.strMonthName) + '</td>');
            parts.add('<td style="' + sTdR + '">' + formatCurrency(row.decEmiAmount) + '</td>');
            parts.add('<td style="' + sTdR + '">' + formatCurrency(row.decInterestComponent) + '</td>');
            parts.add('<td style="' + sTdR + '">' + formatCurrency(row.decPrincipalComponent) + '</td>');
            parts.add('<td style="' + sTdR + '">' + formatCurrency(row.decRemainingBalance) + '</td>');
            parts.add('</tr>');
        }

        parts.add('</table>');
        parts.add('<p>For queries, contact our loan servicing team.</p>');
        parts.add('<p>Regards,<br/>Loan Processing Team</p>');
        parts.add('</div></div></div>');
        parts.add('</body></html>');

        return String.join(parts, '');
    }

    private static void sendEmails(List<Messaging.SingleEmailMessage> listEmailsToSend) {
        try {
            Messaging.SendEmailResult[] listSendEmailResults = Messaging.sendEmail(listEmailsToSend, false);
            for (Integer i = 0; i < listSendEmailResults.size(); i++) {
                Messaging.SendEmailResult res = listSendEmailResults[i];
                if (!res.isSuccess()) {
                    for (Messaging.SendEmailError err : res.getErrors()) {
                        System.debug(LoggingLevel.ERROR, 'Email failed: ' + err.getMessage());
                    }
                }
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Exception: ' + ex.getMessage());
            System.debug(LoggingLevel.ERROR, ex.getStackTraceString());
        }
    }

    private static String formatCurrency(Decimal decAmount) {
        return 'Rs.' + String.valueOf(decAmount.setScale(2));
    }

    private static String formatMonthName(Date dtInstallmentMonth) {
        List<String> listMonthNames = new List<String>{
            'January','February','March','April',
            'May','June','July','August',
            'September','October','November','December'
        };
        return listMonthNames[dtInstallmentMonth.month() - 1]
            + ' ' + String.valueOf(dtInstallmentMonth.year());
    }

    private static String escapeHtml(String strValue) {
        if (strValue == null) return '';
        String s = strValue.replace('&', '&amp;');
        s = s.replace('<', '&lt;');
        s = s.replace('>', '&gt;');
        s = s.replace('"', '&quot;');
        return s;
    }

    public class AmortizationRowWrapper {
        public String strMonthName { get; private set; }
        public Decimal decEmiAmount { get; private set; }
        public Decimal decInterestComponent { get; private set; }
        public Decimal decPrincipalComponent { get; private set; }
        public Decimal decRemainingBalance { get; private set; }

        public AmortizationRowWrapper(
            String strMonthName,
            Decimal decEmiAmount,
            Decimal decInterestComponent,
            Decimal decPrincipalComponent,
            Decimal decRemainingBalance
        ) {
            this.strMonthName = strMonthName;
            this.decEmiAmount = decEmiAmount.setScale(2);
            this.decInterestComponent = decInterestComponent.setScale(2);
            this.decPrincipalComponent = decPrincipalComponent.setScale(2);
            this.decRemainingBalance = decRemainingBalance.setScale(2);
        }
    }
}