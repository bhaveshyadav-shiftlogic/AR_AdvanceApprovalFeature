import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import submitforApproval from '@salesforce/apex/ARQuoteApprovalLWCController.submitForApproval';

export default class ArSubmitForApporval extends LightningElement {
    @api recordId;
    submitterComments = '';
    isSubmitting = false;

    handleCommentChange(event) {
        this.submitterComments = event.target.value;
    }

    async handleSubmit() {
        // Guard: prevent double execution
        if (this.isSubmitting) {
            return;
        }

        this.isSubmitting = true;

        try {
            await submitforApproval({
                recordId: this.recordId,
                submitterComments: this.submitterComments
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Submitted for approval',
                    variant: 'success'
                })
            );

            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (error) {
            let message =
                error?.body?.message ||
                'An unexpected error occurred while submitting the Approval.';

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Submission Failed',
                    message: message,
                    variant: 'error'
                })
            );

            // Re-enable button only if submission failed
            this.isSubmitting = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}