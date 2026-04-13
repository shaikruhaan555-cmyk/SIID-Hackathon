import { LightningElement } from 'lwc';
import getLoanApplicationForCurrentUser from '@salesforce/apex/LoanApplicationDocumentController.getLoanApplicationForCurrentUser';
import uploadFile from '@salesforce/apex/LoanApplicationDocumentController.uploadFile';
import markDocumentsSubmitted from '@salesforce/apex/LoanApplicationDocumentController.markDocumentsSubmitted';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class LoanDocumentUpload extends LightningElement {

    loanApplicationId;
    aadharFile;
    panFile;
    isLoading = true;

    connectedCallback() {
        this.init();
    }

    async init() {
        try {
            const res = await getLoanApplicationForCurrentUser();
            this.loanApplicationId = res.loanApplicationId;
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Error loading data', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleAadharFile(e) {
        this.aadharFile = e.target.files[0];
    }

    handlePanFile(e) {
        this.panFile = e.target.files[0];
    }

    async handleSubmit() {

        if (!this.aadharFile || !this.panFile) {
            this.showToast('Error', 'Upload both files', 'error');
            return;
        }

        this.isLoading = true;

        try {
            await this.upload(this.aadharFile, 'Aadhar');
            await this.upload(this.panFile, 'PAN');

            await markDocumentsSubmitted({ loanId: this.loanApplicationId });

            this.showToast('Success', 'Documents submitted successfully', 'success');

        } catch (e) {
            this.showToast('Error', e.body?.message || 'Error occurred', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    upload(file, prefix) {
        return new Promise((resolve, reject) => {

            const reader = new FileReader();

            reader.onload = () => {
                const base64 = reader.result.split(',')[1];

                uploadFile({
                    fileName: prefix + '_' + file.name,
                    base64Data: base64,
                    recordId: this.loanApplicationId
                })
                .then(resolve)
                .catch(reject);
            };

            reader.readAsDataURL(file);
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}