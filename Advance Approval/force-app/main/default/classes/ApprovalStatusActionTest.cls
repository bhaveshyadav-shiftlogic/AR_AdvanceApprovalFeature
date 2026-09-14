@IsTest
private class ApprovalStatusActionTest {

    // The status-monitor field is pointed at a writable text field (Description)
    // so the status updates succeed on a standard object that has no "Status" field.
    private static final String STATUS_FIELD = 'Description';

    private static Opportunity buildOpportunity() {
        Opportunity opp = new Opportunity(
            Name      = 'AR Test Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        return opp;
    }

    private static Approval_Framework_Config__c buildConfig() {
        Approval_Framework_Config__c cfg = new Approval_Framework_Config__c(
            Name                       = 'Status Monitor Config',
            Process_Name__c            = 'Test Process',
            Object_API_Name__c         = 'Opportunity',
            Level_Number__c            = 'Level 1',
            Approver_Type__c           = 'User',
            Approver_Value__c          = UserInfo.getUserId(),
            Active__c                  = true,
            AR_ApprovalStatusMonitor__c = STATUS_FIELD
        );
        insert cfg;
        return cfg;
    }

    private static ApprovalStatusAction.Request buildRequest(Id recordId, String updateType) {
        ApprovalStatusAction.Request req = new ApprovalStatusAction.Request();
        req.recordId   = recordId;
        req.UpdateType = updateType;
        return req;
    }

    @IsTest
    static void testSubmitted() {
        Opportunity opp = buildOpportunity();
        buildConfig();

        Test.startTest();
        ApprovalStatusAction.handleStatus(
            new List<ApprovalStatusAction.Request>{ buildRequest(opp.Id, 'SUBMITTED') }
        );
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('In Review', updated.Description, 'SUBMITTED should set status to In Review');
    }

    @IsTest
    static void testRejected() {
        Opportunity opp = buildOpportunity();
        buildConfig();

        Test.startTest();
        ApprovalStatusAction.handleStatus(
            new List<ApprovalStatusAction.Request>{ buildRequest(opp.Id, 'REJECTED') }
        );
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Rejected', updated.Description, 'REJECTED should set status to Rejected');
    }

    @IsTest
    static void testApprovedAsync() {
        Opportunity opp = buildOpportunity();
        buildConfig();

        // APPROVED routes through a @future method; Test.stopTest() forces it to run.
        Test.startTest();
        ApprovalStatusAction.handleStatus(
            new List<ApprovalStatusAction.Request>{ buildRequest(opp.Id, 'APPROVED') }
        );
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Approved', updated.Description, 'APPROVED should set status to Approved');
    }

    @IsTest
    static void testNullAndUnknownRequestsAreSkipped() {
        Opportunity opp = buildOpportunity();
        buildConfig();

        List<ApprovalStatusAction.Request> requests = new List<ApprovalStatusAction.Request>{
            buildRequest(null, 'SUBMITTED'),     // null recordId  -> skipped
            buildRequest(opp.Id, null),          // null UpdateType -> skipped
            buildRequest(opp.Id, 'SOMETHING')    // unknown type    -> skipped
        };

        Test.startTest();
        ApprovalStatusAction.handleStatus(requests);
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, updated.Description, 'No recognised action should have updated the record');
    }
}
