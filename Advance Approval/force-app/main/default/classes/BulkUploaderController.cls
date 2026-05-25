/**
 * BulkUploaderController
 * ─────────────────────────────────────────────────────────────────────────────
 * Receives a JSON payload from the LWC, parses it, and performs bulk-safe
 * insert of Parent (Approval_Framework_Config__c) and multiple Child
 * (Approval_Condition__c) records per parent.
 *
 * Multi-child support:
 *  - Each RowPayload now carries a List<Map<String,String>> childDataList
 *    instead of a single childData map.
 *  - One parent row in the Excel can produce N child Approval_Condition__c
 *    records (one per entry in childDataList).
 *
 * Governor-limit safety:
 *  - Uses Database.insert(records, false) for partial success
 *  - Processes in chunks of 200 (DML row limit chunk)
 *  - Single bulk SOQL for user-name → Id resolution
 *
 * User lookup resolution:
 *  - Approver_Value__c in Excel must contain the User's full Name
 *  - Apex resolves name → User Id via a single bulk SOQL before DML
 *  - Rows whose user name is not found are rejected with a clear message
 */
public with sharing class BulkUploaderController {

    private static final Integer CHUNK_SIZE = 200;

    // ── Inner classes for JSON de-serialisation ──────────────────────────────

    public class RowPayload {
        public Integer                    rowNum;
        public String                     name;
        public Map<String, String>        parentData;
        /**
         * Each entry in childDataList becomes one Approval_Condition__c record
         * linked to the parent created from parentData.
         * The LWC populates this list by grouping "continuation" rows
         * (rows whose Name column is blank) under the preceding parent row.
         */
        public List<Map<String, String>>  childDataList;
    }

    public class InsertResult {
        public Integer rowNum;
        public String  name;
        public Boolean success;
        public String  detail;
        public String  parentId;
        public Integer childCount;      // total children attempted for this parent
        public Integer childInserted;   // children successfully inserted
    }

    public class BulkResponse {
        public Boolean            success;
        public Integer            parentInserted;
        public Integer            childInserted;
        public List<InsertResult> results;
    }

    // ── Main entry point ──────────────────────────────────────────────────────

    @AuraEnabled
    public static String insertBulkRecords(String payloadJson) {
        List<RowPayload> rows = (List<RowPayload>) JSON.deserialize(
            payloadJson, List<RowPayload>.class
        );

        BulkResponse response   = new BulkResponse();
        response.results        = new List<InsertResult>();
        response.parentInserted = 0;
        response.childInserted  = 0;
        response.success        = true;

        // ── 0. Bulk-resolve Approver User names → IDs ─────────────────────
        //  Only resolve rows where Approver_Type__c = 'User'.
        //  The Excel must contain the user's full Name (not ID).
        Set<String> approverNames = new Set<String>();
        for (RowPayload row : rows) {
            if (row.parentData == null) continue;
            String aType = row.parentData.get('Approver_Type__c');
            String aVal  = row.parentData.get('Approver_Value__c');
            if (isUserType(aType) && String.isNotBlank(aVal)) {
                approverNames.add(aVal.trim());
            }
        }

        Map<String, Id> nameToUserId = new Map<String, Id>();
        if (!approverNames.isEmpty()) {
            for (User u : [
                SELECT Id, Name FROM User
                WHERE Name IN :approverNames AND IsActive = true
                LIMIT 500
            ]) {
                nameToUserId.put(u.Name, u.Id);
            }
        }

        // ── 1. Pre-flight validation + build parent SObject list ──────────
        //  dmlToRowIndex maps each position in parentList → original rows[] index
        //  so that chunk index math stays correct when rows are skipped.
        List<Approval_Framework_Config__c> parentList    = new List<Approval_Framework_Config__c>();
        List<Integer>                      dmlToRowIndex = new List<Integer>();

        for (Integer i = 0; i < rows.size(); i++) {
            RowPayload row = rows[i];

            if (row.parentData != null) {
                String aType = row.parentData.get('Approver_Type__c');
                String aVal  = row.parentData.get('Approver_Value__c');

                if (isUserType(aType) && String.isNotBlank(aVal)) {
                    String trimmed = aVal.trim();
                    if (nameToUserId.containsKey(trimmed)) {
                        row.parentData.put('Approver_Value__c', nameToUserId.get(trimmed));
                    } else {
                        // Pre-flight error — skip this row entirely
                        InsertResult ir = new InsertResult();
                        ir.rowNum        = row.rowNum;
                        ir.name          = row.name;
                        ir.success       = false;
                        ir.childCount    = row.childDataList != null ? row.childDataList.size() : 0;
                        ir.childInserted = 0;
                        ir.detail        = 'User not found: "' + trimmed
                                         + '". Verify the name matches an active Salesforce user.';
                        response.results.add(ir);
                        response.success = false;
                        continue;
                    }
                }
            }

            parentList.add(buildParent(row.parentData));
            dmlToRowIndex.add(i);
        }

        // ── 2. Insert parents in chunks ───────────────────────────────────
        Map<Integer, Id> rowIndexToParentId = new Map<Integer, Id>();

        for (Integer chunkStart = 0; chunkStart < parentList.size(); chunkStart += CHUNK_SIZE) {
            Integer chunkEnd = Math.min(chunkStart + CHUNK_SIZE, parentList.size());
            List<Approval_Framework_Config__c> chunk = new List<Approval_Framework_Config__c>();
            for (Integer i = chunkStart; i < chunkEnd; i++) {
                chunk.add(parentList[i]);
            }

            Database.SaveResult[] parentResults = Database.insert(chunk, false);

            for (Integer i = 0; i < parentResults.size(); i++) {
                Integer dmlIdx         = chunkStart + i;
                Integer rowIdx         = dmlToRowIndex[dmlIdx];
                Database.SaveResult sr = parentResults[i];
                InsertResult ir        = new InsertResult();
                ir.rowNum              = rows[rowIdx].rowNum;
                ir.name                = rows[rowIdx].name;
                ir.success             = sr.isSuccess();
                ir.childCount          = rows[rowIdx].childDataList != null
                                            ? rows[rowIdx].childDataList.size() : 0;
                ir.childInserted       = 0;

                if (sr.isSuccess()) {
                    ir.detail      = 'Parent inserted: ' + sr.getId();
                    ir.parentId    = sr.getId();
                    rowIndexToParentId.put(rowIdx, sr.getId());
                    response.parentInserted++;
                } else {
                    ir.detail        = sr.getErrors()[0].getMessage();
                    response.success = false;
                }
                response.results.add(ir);
            }
        }

        // ── 3. Build child records (one per childDataList entry, per parent) ─
        //  childOwnerRowIndex tracks which original rows[] index each child
        //  belongs to, so we can update that parent's InsertResult on completion.
        List<Approval_Condition__c> childList           = new List<Approval_Condition__c>();
        List<Integer>               childOwnerRowIndex  = new List<Integer>();

        for (Integer i = 0; i < rows.size(); i++) {
            if (!rowIndexToParentId.containsKey(i)) continue;
            if (rows[i].childDataList == null || rows[i].childDataList.isEmpty()) continue;

            Id parentId = rowIndexToParentId.get(i);

            for (Map<String, String> cd : rows[i].childDataList) {
                Approval_Condition__c child = buildChild(cd, parentId);
                if (child != null) {
                    childList.add(child);
                    childOwnerRowIndex.add(i);
                }
            }
        }

        // ── 4. Insert children in chunks ──────────────────────────────────
        if (!childList.isEmpty()) {
            for (Integer chunkStart = 0; chunkStart < childList.size(); chunkStart += CHUNK_SIZE) {
                Integer chunkEnd = Math.min(chunkStart + CHUNK_SIZE, childList.size());
                List<Approval_Condition__c> chunk = new List<Approval_Condition__c>();
                for (Integer i = chunkStart; i < chunkEnd; i++) {
                    chunk.add(childList[i]);
                }

                Database.SaveResult[] childResults = Database.insert(chunk, false);

                for (Integer i = 0; i < childResults.size(); i++) {
                    Integer globalIdx      = childOwnerRowIndex[chunkStart + i];
                    Database.SaveResult sr = childResults[i];
                    InsertResult parentIR  = getResultByRowNum(response.results, rows[globalIdx].rowNum);

                    if (sr.isSuccess()) {
                        response.childInserted++;
                        if (parentIR != null) {
                            parentIR.childInserted++;
                            parentIR.detail += ' | Child[' + parentIR.childInserted + '] inserted: ' + sr.getId();
                        }
                    } else {
                        if (parentIR != null) {
                            parentIR.detail  += ' | Child FAILED: ' + sr.getErrors()[0].getMessage();
                            parentIR.success  = false;
                            response.success  = false;
                        }
                    }
                }
            }
        }

        return JSON.serialize(response);
    }

    // ── Template file lookup ──────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static String getTemplateFileId() {
        List<ContentDocument> docs = [
            SELECT Id FROM ContentDocument
            WHERE Title = 'BulkUploadTemplate'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return docs.isEmpty() ? null : docs[0].Id;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static Boolean isUserType(String approverType) {
        return String.isNotBlank(approverType)
            && approverType.trim().equalsIgnoreCase('User');
    }

    private static Approval_Framework_Config__c buildParent(Map<String, String> data) {
        Approval_Framework_Config__c rec = new Approval_Framework_Config__c();
        rec.Name                         = strVal(data, 'Name');
        rec.Process_Name__c              = strVal(data, 'Process_Name__c');
        rec.Object_API_Name__c           = strVal(data, 'Object_API_Name__c');
        rec.Level_Number__c              = strVal(data, 'Level_Number__c');
        rec.Approval_Type__c             = strVal(data, 'Approval_Type__c');
        rec.Approver_Type__c             = strVal(data, 'Approver_Type__c');
        rec.Approver_Value__c            = strVal(data, 'Approver_Value__c');
        rec.isSequencing__c              = boolVal(data, 'isSequencing__c');
        rec.Active__c                    = boolVal(data, 'Active__c');
        rec.Condition_Met__c             = strVal(data, 'Condition_Met__c');
        rec.Evaluation_Condition__c      = strVal(data, 'Evaluation_Condition__c');
        rec.Depends_On_Level__c          = strVal(data, 'Depends_On_Level__c');
        rec.AR_ApprovalStatusMonitor__c  = strVal(data, 'AR_ApprovalStatusMonitor__c');
        return rec;
    }

    private static Approval_Condition__c buildChild(Map<String, String> data, Id parentId) {
        // Skip child if all key child fields are empty
        if (String.isBlank(strVal(data, 'Criteria_Field__c')) &&
            String.isBlank(strVal(data, 'Operator__c'))       &&
            String.isBlank(strVal(data, 'Values__c'))) {
            return null;
        }

        Approval_Condition__c rec        = new Approval_Condition__c();
        rec.Criteria_Field__c            = strVal(data, 'Criteria_Field__c');
        rec.Operator__c                  = strVal(data, 'Operator__c');
        rec.Values__c                    = strVal(data, 'Values__c');
        rec.Active__c                    = boolVal(data, 'Active__c');
        rec.Approval_Framework_Config__c = parentId;
        return rec;
    }

    private static String strVal(Map<String, String> m, String key) {
        return m != null && m.containsKey(key) ? m.get(key) : null;
    }

    private static Boolean boolVal(Map<String, String> m, String key) {
        String raw = strVal(m, key);
        if (raw == null) return false;
        return raw.toLowerCase() == 'true';
    }

    private static InsertResult getResultByRowNum(List<InsertResult> results, Integer rowNum) {
        for (InsertResult ir : results) {
            if (ir.rowNum == rowNum) return ir;
        }
        return null;
    }
}