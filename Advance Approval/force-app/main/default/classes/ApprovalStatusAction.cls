public with sharing class ApprovalStatusAction {

    public class Request {

        @InvocableVariable(required=true)
        public Id recordId;

        @InvocableVariable(required=true)
        public String UpdateType; // SUBMITTED / APPROVED / REJECTED
    }

    @InvocableMethod(label='Handle Approval Status')
    public static void handleStatus(List<Request> requests) {

        List<SObject> recordsToUpdate = new List<SObject>();

        for(Request req : requests){

            if(req.recordId == null || req.UpdateType == null){
                continue;
            }

            Id recId = req.recordId;
            String action = req.UpdateType;

            // Resolve the object name from the record Id
            String objectName = recId.getSObjectType().getDescribe().getName();

            // Look up the status field API name configured in AR_ApprovalStatusMonitor__c.
            // Fallback to 'Status' if no rule is found or field is blank.
            String statusFieldApiName = resolveStatusFieldApiName(objectName);

            // APPROVED — push to async to avoid DML conflict
            // with native approval step commit in same transaction
            if(action == 'APPROVED'){
                updateApprovedStatusAsync(recId, statusFieldApiName);
                continue;
            }

            String statusValue;

            if(action == 'SUBMITTED'){
                statusValue = 'In Review';
            }
            else if(action == 'REJECTED'){
                statusValue = 'Rejected';
            }
            else{
                continue;
            }

            String soql =
                'SELECT Id, OwnerId FROM ' + objectName +
                ' WHERE Id = :recId LIMIT 1';

            SObject record = Database.query(soql);
            record.put(statusFieldApiName, statusValue);
            recordsToUpdate.add(record);
        }

        if(!recordsToUpdate.isEmpty()){
            update recordsToUpdate;
        }
    }

    /*
    ------------------------------------------------
    Resolve the status field API name by querying
    AR_ApprovalStatusMonitor__c on the matching config.
    Falls back to 'Status' if not configured.
    ------------------------------------------------
    */
    private static String resolveStatusFieldApiName(String objectName) {
        List<Approval_Framework_Config__c> configs = [
            SELECT AR_ApprovalStatusMonitor__c
            FROM   Approval_Framework_Config__c
            WHERE  Object_API_Name__c = :objectName
            AND    Active__c = true
            AND    AR_ApprovalStatusMonitor__c != null
            LIMIT  1
        ];

        if (!configs.isEmpty() && String.isNotBlank(configs[0].AR_ApprovalStatusMonitor__c)) {
            System.debug('APPROVAL STATUS FIELD >> [' + configs[0].AR_ApprovalStatusMonitor__c.trim() + '] for object: ' + objectName);
            return configs[0].AR_ApprovalStatusMonitor__c.trim();
        }

        System.debug('APPROVAL STATUS FIELD >> Defaulting to [Status] for object: ' + objectName);
        return 'Status';
    }

    /*
    ------------------------------------------------
    ASYNC — runs in a fresh transaction after the
    approval step has fully committed.
    Flow exit condition already guarantees all
    approvals are complete before this is called,
    so we just update the status directly.
    The statusFieldApiName is passed in so the
    @future method knows which field to update.
    ------------------------------------------------
    */

    @future
    private static void updateApprovedStatusAsync(Id recId, String statusFieldApiName) {

        String objectName = recId.getSObjectType().getDescribe().getName();

        String soql =
            'SELECT Id, OwnerId FROM ' + objectName +
            ' WHERE Id = :recId LIMIT 1';

        SObject record = Database.query(soql);
        record.put(statusFieldApiName, 'Approved');
        update record;
    }
}