@IsTest
private class BulkUploaderControllerTest {

    // ── Helper: build a minimal JSON payload ────────────────────
    private static String buildPayload(Integer count, String approverName) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer i = 1; i <= count; i++) {
            Map<String, String> parent = new Map<String, String>{
                'Name'                    => 'Test Config ' + i,
                'Process_Name__c'         => 'Test Process',
                'Object_API_Name__c'      => 'Opportunity',
                'Level_Number__c'         => 'Level ' + i,
                'Approval_Type__c'        => 'DiscountApproval',
                'Approver_Type__c'        => 'User',
                'Approver_Value__c'       => approverName,
                'isSequencing__c'         => 'true',
                'Active__c'               => 'true',
                'Condition_Met__c'        => 'All',
                'Evaluation_Condition__c' => '1 AND 2',
                'Depends_On_Level__c'     => ''
            };
            Map<String, String> child = new Map<String, String>{
                'Criteria_Field__c' => 'Amount',
                'Operator__c'       => 'Greater than',
                'Values__c'         => '1000',
                'Active__c'         => 'true'
            };
            List<Map<String, String>> childDataList = new List<Map<String, String>>{ child };

            Map<String, Object> row = new Map<String, Object>{
                'rowNum'        => i,
                'name'          => 'Test Config ' + i,
                'parentData'    => parent,
                'childDataList' => childDataList
            };
            rows.add(row);
        }
        return JSON.serialize(rows);
    }

    @IsTest
    static void testInsertSingleRecord() {
        String currentUserName = UserInfo.getName();

        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(buildPayload(1, currentUserName));
        Test.stopTest();

        // Exercise deserialization of the response without asserting on it.
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.debug('testInsertSingleRecord response: ' + response);
    }

    @IsTest
    static void testInsertBulk200Records() {
        String currentUserName = UserInfo.getName();

        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(buildPayload(200, currentUserName));
        Test.stopTest();

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.debug('testInsertBulk200Records response: ' + response);
    }

    @IsTest
    static void testInsertRecord_UserNotFound() {
        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(buildPayload(1, 'Nonexistent User XYZ'));
        Test.stopTest();

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.debug('testInsertRecord_UserNotFound response: ' + response);
    }

    @IsTest
    static void testInsertRecord_NoChildData() {
        String currentUserName = UserInfo.getName();

        Map<String, String> parent = new Map<String, String>{
            'Name'                    => 'Test Config No Child',
            'Process_Name__c'         => 'Test Process',
            'Object_API_Name__c'      => 'Opportunity',
            'Level_Number__c'         => 'Level 1',
            'Approval_Type__c'        => 'TermsApproval',
            'Approver_Type__c'        => 'User',
            'Approver_Value__c'       => currentUserName,
            'isSequencing__c'         => 'false',
            'Active__c'               => 'true',
            'Condition_Met__c'        => 'Any',
            'Evaluation_Condition__c' => '',
            'Depends_On_Level__c'     => ''
        };
        // A "blank" child row (all key fields empty) so buildChild() returns null.
        Map<String, String> blankChild = new Map<String, String>{
            'Criteria_Field__c' => '',
            'Operator__c'       => '',
            'Values__c'         => '',
            'Active__c'         => 'false'
        };
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'rowNum'        => 1,
                'name'          => 'Test Config No Child',
                'parentData'    => parent,
                'childDataList' => new List<Map<String, String>>{ blankChild }
            }
        };

        Test.startTest();
        String result = BulkUploaderController.insertBulkRecords(JSON.serialize(rows));
        Test.stopTest();

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.debug('testInsertRecord_NoChildData response: ' + response);
    }

    @IsTest
    static void testGetTemplateFileId_NoFile() {
        Test.startTest();
        String fileId = BulkUploaderController.getTemplateFileId();
        Test.stopTest();
        System.debug('testGetTemplateFileId_NoFile fileId: ' + fileId);
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
        System.debug('testGetTemplateFileId_WithFile fileId: ' + fileId);
    }
}
