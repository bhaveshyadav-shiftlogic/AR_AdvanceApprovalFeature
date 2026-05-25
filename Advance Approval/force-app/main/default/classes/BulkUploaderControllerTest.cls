@IsTest
private class BulkUploaderControllerTest {

    // ── Helper: build a minimal JSON payload ────────────────────
    private static String buildPayload(Integer count) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer i = 1; i <= count; i++) {
            Map<String, String> parent = new Map<String, String>{
                'Name'                    => 'Test Config ' + i,
                'Process_Name__c'         => 'Test Process',
                'Object_API_Name__c'      => 'Opportunity',
                'Level_Number__c'         => 'Level ' + i,
                'Approval_Type__c'        => 'Amount',
                'Approver_Type__c'        => 'User',
                'Approver_Value__c'       => 'test@test.com',
                'isSequencing__c'         => 'true',
                'Active__c'               => 'true',
                'Condition_Met__c'        => 'All',
                'Evaluation_Condition__c' => '1 AND 2',
                'Depends_On_Level__c'     => ''
            };
            Map<String, String> child = new Map<String, String>{
                'Criteria_Field__c' => 'Amount',
                'Operator__c'     => 'Greater Than',
                'Values__c'       => '1000',
                'Active__c'       => 'true'
            };
            Map<String, Object> row = new Map<String, Object>{
                'rowNum'     => i,
                'name'       => 'Test Config ' + i,
                'parentData' => parent,
                'childData'  => child
            };
            rows.add(row);
        }
        return JSON.serialize(rows);
    }

    @IsTest
    static void testInsertSingleRecord() {
        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(buildPayload(1));
        Test.stopTest();

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.assertEquals(1, (Integer) response.get('parentInserted'), 'Expected 1 parent inserted');
        System.assertEquals(1, (Integer) response.get('childInserted'),  'Expected 1 child inserted');
        System.assertEquals(true, (Boolean) response.get('success'));

        System.assertEquals(1, [SELECT COUNT() FROM Approval_Framework_Config__c WHERE Name LIKE 'Test Config%']);
        System.assertEquals(1, [SELECT COUNT() FROM Approval_Condition__c WHERE Criteria_Field__c = 'Amount']);
    }

    @IsTest
    static void testInsertBulk200Records() {
        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(buildPayload(200));
        Test.stopTest();

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.assertEquals(200, (Integer) response.get('parentInserted'));
        System.assertEquals(200, (Integer) response.get('childInserted'));
    }

    @IsTest
    static void testGetTemplateFileId_NoFile() {
        Test.startTest();
        String fileId = BulkUploaderController.getTemplateFileId();
        Test.stopTest();
        // No template in test context — should return null
        System.assertEquals(null, fileId);
    }

    @IsTest
    static void testGetTemplateFileId_WithFile() {
        // Insert a dummy ContentDocument named BulkUploadTemplate
        ContentVersion cv = new ContentVersion(
            Title           = 'BulkUploadTemplate',
            PathOnClient    = 'BulkUploadTemplate.xlsx',
            VersionData     = Blob.valueOf('fake'),
            IsMajorVersion  = true
        );
        insert cv;

        Test.startTest();
        String fileId = BulkUploaderController.getTemplateFileId();
        Test.stopTest();
        System.assertNotEquals(null, fileId);
    }
}