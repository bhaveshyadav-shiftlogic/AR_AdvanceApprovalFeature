public with sharing class ARQuoteApprovalLWCController {

    @AuraEnabled
    public static void submitForApproval(Id recordId, String submitterComments) {

        if (recordId == null) {
            AuraHandledException e = new AuraHandledException('Record Id is required.');
            e.setMessage('Record Id is required.');
            throw e;
        }

        try {

            String objectName = recordId.getSObjectType().getDescribe().getName();

            /*
            -----------------------------------------
            QUERY PARENT RULES
            -----------------------------------------
            */

            List<Approval_Framework_Config__c> rules = [
                SELECT Process_Name__c, Object_API_Name__c,
                       Approval_Type__c,
                       Approver_Value__c,
                       Approver_Value__r.Name, Approver_Value__r.Email, Approver_Value__r.Username,
                       Depends_On_Level__c,
                        Active__c,
                       Approver_Type__c, Level_Number__c,
                       isOptional__c, isSequencing__c,
                       Condition_Met__c, Evaluation_Condition__c,
                       AR_ApprovalStatusMonitor__c,
                       (
                           SELECT Criteria_Field__c, Object_API_Name__c,
                                  Values__c, Operator__c
                           FROM Approval_Conditions__r
                       )
                FROM Approval_Framework_Config__c
                WHERE Object_API_Name__c = :objectName
                AND Active__c = true
                ORDER BY Level_Number__c ASC
            ];

            if (rules.isEmpty()) {
                AuraHandledException e = new AuraHandledException('No active rules configured for ' + objectName);
                e.setMessage('No active rules configured for ' + objectName);
                throw e;
            }

            System.debug('=== TOTAL RULES: ' + rules.size() + ' ===');
            for (Approval_Framework_Config__c r : rules) {
                System.debug(
                    'RAW RULE >> ' +
                    'Process: ['        + r.Process_Name__c        + ']' +
                    ' ApprovalType: ['  + r.Approval_Type__c       + ']' +
                    ' Level: ['         + r.Level_Number__c         + ']' +
                    ' ConditionMet: ['  + r.Condition_Met__c        + ']' +
                    ' EvalCondition: [' + r.Evaluation_Condition__c + ']' +
                    ' Approver: ['      + r.Approver_Value__c       + ']' +
                    ' ApproverName: ['  + (r.Approver_Value__r != null ? r.Approver_Value__r.Name : 'NULL') + ']' +
                    ' Optional: ['      + r.isOptional__c           + ']' +
                    ' Sequencing: ['    + r.isSequencing__c         + ']' +
                    ' DependsOnLevel: ['+ r.Depends_On_Level__c     + ']' +
                    ' Conditions: ['    + r.Approval_Conditions__r.size() + ']'
                );
            }

            /*
            -----------------------------------------
            COLLECT REQUIRED FIELDS FROM CHILD CONDITIONS
            -----------------------------------------
            */

            Set<String> soqlFields = new Set<String>{ 'Id' };

            for (Approval_Framework_Config__c rule : rules) {
                for (Approval_Condition__c cond : rule.Approval_Conditions__r) {
                    if (String.isNotBlank(cond.Criteria_Field__c)) {
                        soqlFields.add(cond.Criteria_Field__c);
                    }
                }
            }

            /*
            -----------------------------------------
            BUILD DYNAMIC SOQL
            -----------------------------------------
            */

            String soql =
                'SELECT ' + String.join(new List<String>(soqlFields), ', ') +
                ' FROM ' + objectName +
                ' WHERE Id = :recordId LIMIT 1';

            System.debug('Dynamic SOQL: ' + soql);

            SObject record = Database.query(soql);

            for (String f : soqlFields) {
                System.debug('RECORD FIELD >> [' + f + '] = [' + record.get(f) + ']');
            }

            /*
            -----------------------------------------
            GROUP RULES BY PROCESS → THEN BY LEVEL
            -----------------------------------------
            */

            Map<String, Map<String, List<Approval_Framework_Config__c>>> processLevelRules =
                new Map<String, Map<String, List<Approval_Framework_Config__c>>>();

            Map<String, Map<String, Approval_Framework_Config__c>> processLevelApprover =
                new Map<String, Map<String, Approval_Framework_Config__c>>();

            Map<String, List<String>> processLevelOrder =
                new Map<String, List<String>>();

            for (Approval_Framework_Config__c rule : rules) {

                String pName = rule.Process_Name__c;
                String lvl   = rule.Level_Number__c;

                if (String.isBlank(lvl)) {
                    System.debug('WARNING — Blank Level_Number__c on rule: ' + rule.Id);
                    continue;
                }

                if (!processLevelRules.containsKey(pName)) {
                    processLevelRules.put(pName,    new Map<String, List<Approval_Framework_Config__c>>());
                    processLevelApprover.put(pName, new Map<String, Approval_Framework_Config__c>());
                    processLevelOrder.put(pName,    new List<String>());
                }

                if (!processLevelRules.get(pName).containsKey(lvl)) {
                    processLevelRules.get(pName).put(lvl, new List<Approval_Framework_Config__c>());
                    processLevelOrder.get(pName).add(lvl);
                }

                processLevelRules.get(pName).get(lvl).add(rule);

                System.debug(
                    'GROUPING >> Process: [' + pName + '] Level: [' + lvl + ']' +
                    ' Approver_Value__c: [' + rule.Approver_Value__c + ']' +
                    ' AlreadyHasApprover: [' + processLevelApprover.get(pName).containsKey(lvl) + ']'
                );

                if (rule.Approver_Value__c != null &&
                    !processLevelApprover.get(pName).containsKey(lvl)) {
                    processLevelApprover.get(pName).put(lvl, rule);
                    System.debug(
                        'APPROVER STORED >> Process: [' + pName + ']' +
                        ' Level: [' + lvl + ']' +
                        ' Approver: [' + (rule.Approver_Value__r != null ? rule.Approver_Value__r.Name : 'NULL') + ']'
                    );
                } else {
                    System.debug(
                        'APPROVER SKIPPED >> Process: [' + pName + ']' +
                        ' Level: [' + lvl + ']' +
                        ' Reason: ' + (rule.Approver_Value__c == null ? 'Approver_Value__c is null' : 'Level already has approver')
                    );
                }
            }

            System.debug('=== FINAL APPROVER MAP ===');
            for (String pName : processLevelApprover.keySet()) {
                for (String lvl : processLevelApprover.get(pName).keySet()) {
                    Approval_Framework_Config__c ar = processLevelApprover.get(pName).get(lvl);
                    System.debug(
                        'APPROVER MAP >> Process: [' + pName + ']' +
                        ' Level: [' + lvl + ']' +
                        ' Approver: [' + (ar.Approver_Value__r != null ? ar.Approver_Value__r.Name : 'NULL') + ']'
                    );
                }
            }

            System.debug('=== LEVEL ORDER MAP ===');
            for (String pName : processLevelOrder.keySet()) {
                System.debug('LEVEL ORDER >> Process: [' + pName + '] Levels: ' + processLevelOrder.get(pName));
            }

            /*
            -----------------------------------------
            EVALUATE EACH PROCESS
            -----------------------------------------
            */

            Map<String, List<MatchedRule>> matchedByProcess =
                new Map<String, List<MatchedRule>>();

            for (String processName : processLevelRules.keySet()) {

                System.debug('--- EVALUATING PROCESS: [' + processName + '] ---');

                Map<String, List<Approval_Framework_Config__c>> levelMap    = processLevelRules.get(processName);
                Map<String, Approval_Framework_Config__c>       approverMap = processLevelApprover.get(processName);
                List<String>                                    levelOrder  = processLevelOrder.get(processName);

                Map<String, Boolean> qualifiedLevels = new Map<String, Boolean>();

                for (String lvl : levelOrder) {

                    Boolean levelQualified = true;

                    for (Approval_Framework_Config__c rule : levelMap.get(lvl)) {

                        List<Approval_Condition__c> conditions = rule.Approval_Conditions__r;

                        if (conditions == null || conditions.isEmpty()) {
                            System.debug('NO CONDITIONS on Level [' + lvl + '] — auto-qualify');
                            continue;
                        }

                        String conditionMet        = rule.Condition_Met__c;
                        String evaluationCondition = rule.Evaluation_Condition__c;

                        Map<Integer, Boolean> condResults = new Map<Integer, Boolean>();
                        for (Integer i = 0; i < conditions.size(); i++) {
                            Approval_Condition__c cond = conditions[i];
                            Object  fieldVal    = getFieldValue(record, cond.Criteria_Field__c);
                            Boolean condMatched = (fieldVal != null &&
                                evaluateCondition(fieldVal, cond.Operator__c, cond.Values__c));
                            condResults.put(i + 1, condMatched);

                            System.debug(
                                'CONDITION [' + (i + 1) + '] >> Level [' + lvl + ']' +
                                ' Field: ['   + cond.Criteria_Field__c + ']' +
                                ' Op: ['      + cond.Operator__c     + ']' +
                                ' RuleVal: [' + cond.Values__c       + ']' +
                                ' Actual: ['  + fieldVal             + ']' +
                                ' Matched: [' + condMatched          + ']'
                            );
                        }

                        Boolean ruleMatched;

                        if (conditionMet == 'All') {
                            ruleMatched = true;
                            for (Boolean r : condResults.values()) {
                                if (!r) { ruleMatched = false; break; }
                            }
                        } else if (conditionMet == 'Any') {
                            ruleMatched = false;
                            for (Boolean r : condResults.values()) {
                                if (r) { ruleMatched = true; break; }
                            }
                        } else if (conditionMet == 'Custom') {
                            ruleMatched = evaluateCustomExpression(evaluationCondition, condResults);
                        } else {
                            ruleMatched = true;
                            for (Boolean r : condResults.values()) {
                                if (!r) { ruleMatched = false; break; }
                            }
                        }

                        System.debug(
                            'RULE RESULT >> Level [' + lvl + ']' +
                            ' ConditionMet: [' + conditionMet + ']' +
                            ' RuleMatched: [' + ruleMatched + ']' +
                            ' Optional: [' + rule.isOptional__c + ']'
                        );

                        if (!ruleMatched) {
                            if (rule.isOptional__c == true) {
                                continue;
                            } else {
                                System.debug('REQUIRED FAILED — Level [' + lvl + '] disqualified');
                                levelQualified = false;
                                break;
                            }
                        }
                    }

                    qualifiedLevels.put(lvl, levelQualified);
                    System.debug('Level [' + lvl + '] qualified: [' + levelQualified + ']');
                }

                // ---- Extract up to 3 level keys ----
                String  firstLevelKey   = levelOrder.size() > 0 ? levelOrder[0] : null;
                String  secondLevelKey  = levelOrder.size() > 1 ? levelOrder[1] : null;
                String  thirdLevelKey   = levelOrder.size() > 2 ? levelOrder[2] : null;

                Boolean firstLevelQual  = (firstLevelKey  != null && qualifiedLevels.containsKey(firstLevelKey))
                                           ? qualifiedLevels.get(firstLevelKey)  : false;
                Boolean secondLevelQual = (secondLevelKey != null && qualifiedLevels.containsKey(secondLevelKey))
                                           ? qualifiedLevels.get(secondLevelKey) : false;
                Boolean thirdLevelQual  = (thirdLevelKey  != null && qualifiedLevels.containsKey(thirdLevelKey))
                                           ? qualifiedLevels.get(thirdLevelKey)  : false;

                System.debug(
                    'RESULT >> Process: [' + processName + ']' +
                    ' firstLevelKey: ['   + firstLevelKey  + '] qualified: [' + firstLevelQual  + ']' +
                    ' secondLevelKey: ['  + secondLevelKey + '] qualified: [' + secondLevelQual + ']' +
                    ' thirdLevelKey: ['   + thirdLevelKey  + '] qualified: [' + thirdLevelQual  + ']'
                );

                if (!firstLevelQual && !secondLevelQual && !thirdLevelQual) {
                    System.debug('NO LEVELS QUALIFIED — skipping: [' + processName + ']');
                    continue;
                }

                Approval_Framework_Config__c firstApproverRule =
                    (firstLevelKey != null) ? approverMap.get(firstLevelKey) : null;

                System.debug(
                    'firstApproverRule >> ' +
                    (firstApproverRule != null
                        ? (firstApproverRule.Approver_Value__r != null
                            ? firstApproverRule.Approver_Value__r.Name
                            : 'Approver_Value__r is NULL')
                        : 'firstApproverRule is NULL — no approver stored for level: [' + firstLevelKey + ']')
                );

                if (firstApproverRule == null) {
                    AuraHandledException ex = new AuraHandledException(
                        'No Level 1 approver configured for process: ' + processName
                    );
                    ex.setMessage('No Level 1 approver configured for process: ' + processName);
                    throw ex;
                }

                /*
                -----------------------------------------
                BUILD levelsMatched USING isSequencing__c
                AND Depends_On_Level__c
                (supports up to Level 3)
                -----------------------------------------
                */

                List<MatchedRule> levelsMatched = new List<MatchedRule>();

                // ---- Resolve L2 rule (if qualified) ----
                Approval_Framework_Config__c secondApproverRule =
                    (secondLevelQual && secondLevelKey != null && approverMap.containsKey(secondLevelKey))
                        ? approverMap.get(secondLevelKey) : null;

                // ---- Resolve L3 rule (if qualified) ----
                Approval_Framework_Config__c thirdApproverRule =
                    (thirdLevelQual && thirdLevelKey != null && approverMap.containsKey(thirdLevelKey))
                        ? approverMap.get(thirdLevelKey) : null;

                if (thirdApproverRule != null) {

                    // ---- L3 sequencing/dependency check ----
                    Boolean l3IsSequencing   = (thirdApproverRule.isSequencing__c == true);
                    String  l3DependsOn      = thirdApproverRule.Depends_On_Level__c;

                    System.debug(
                        'L3 SEQUENCING CHECK >> ' +
                        'isSequencing__c: ['    + l3IsSequencing + ']' +
                        ' | Depends_On_Level__c: [' + l3DependsOn + ']'
                    );

                    if (l3IsSequencing && String.isNotBlank(l3DependsOn)) {

                        if (l3DependsOn == firstLevelKey && secondApproverRule != null) {
                            // L3 depends on L1, and L2 also exists → L1 → L2 → L3
                            System.debug('SEQUENTIAL L1 → L2 → L3 for process: [' + processName + ']');
                            levelsMatched.add(new MatchedRule(firstApproverRule));
                            levelsMatched.add(new MatchedRule(secondApproverRule));
                            levelsMatched.add(new MatchedRule(thirdApproverRule));

                        } else if (l3DependsOn == firstLevelKey) {
                            // L3 depends on L1, no L2 → L1 → L3
                            System.debug('SEQUENTIAL L1 → L3 (no L2) for process: [' + processName + ']');
                            levelsMatched.add(new MatchedRule(firstApproverRule));
                            levelsMatched.add(new MatchedRule(thirdApproverRule));

                        } else if (l3DependsOn == secondLevelKey && secondApproverRule != null) {
                            // L3 depends on L2 → L1 → L2 → L3
                            System.debug('SEQUENTIAL L1 → L2 → L3 (L3 depends on L2) for process: [' + processName + ']');
                            levelsMatched.add(new MatchedRule(firstApproverRule));
                            levelsMatched.add(new MatchedRule(secondApproverRule));
                            levelsMatched.add(new MatchedRule(thirdApproverRule));

                        } else {
                            // Dependency not satisfied — go directly to L3
                            System.debug('DIRECT TO L3 (dependency not matched) for process: [' + processName + ']');
                            levelsMatched.add(new MatchedRule(thirdApproverRule));
                        }

                    } else {
                        // Non-sequential L3 — go directly to L3
                        System.debug('DIRECT TO L3 (non-sequential) for process: [' + processName + ']');
                        levelsMatched.add(new MatchedRule(thirdApproverRule));
                    }

                } else if (secondApproverRule != null) {

                    // ---- Original L2 sequencing/dependency check ----
                    Boolean l2IsSequencing = (secondApproverRule.isSequencing__c == true);
                    String  l2DependsOn    = secondApproverRule.Depends_On_Level__c;

                    System.debug(
                        'L2 SEQUENCING CHECK >> ' +
                        'isSequencing__c: ['    + l2IsSequencing + ']' +
                        ' | Depends_On_Level__c: [' + l2DependsOn + ']' +
                        ' | firstLevelKey: ['   + firstLevelKey  + ']' +
                        ' | Match: [' + (l2DependsOn == firstLevelKey) + ']'
                    );

                    if (l2IsSequencing
                            && String.isNotBlank(l2DependsOn)
                            && l2DependsOn == firstLevelKey) {

                        // Sequential: L1 must approve first, then L2
                        System.debug(
                            'SEQUENTIAL + DEPENDS ON [' + l2DependsOn + ']' +
                            ' — Adding L1 then L2 for process: [' + processName + ']'
                        );
                        levelsMatched.add(new MatchedRule(firstApproverRule));
                        levelsMatched.add(new MatchedRule(secondApproverRule));

                    } else {

                        // Non-sequential or no matching dependency — go directly to L2
                        System.debug(
                            'DIRECT TO L2 — Reason: isSequencing=[' + l2IsSequencing + ']' +
                            ' dependsOnLevel=[' + l2DependsOn + ']' +
                            ' firstLevelKey=[' + firstLevelKey + ']' +
                            ' for process: [' + processName + ']'
                        );
                        levelsMatched.add(new MatchedRule(secondApproverRule));
                    }

                } else {

                    // Only L1 qualified — always route to L1
                    System.debug('ONLY L1 QUALIFIED — Adding L1 for process: [' + processName + ']');
                    levelsMatched.add(new MatchedRule(firstApproverRule));
                }

                matchedByProcess.put(processName, levelsMatched);
            }

            /*
            -----------------------------------------
            NO MATCH — FRIENDLY MESSAGE
            -----------------------------------------
            */

            if (matchedByProcess.isEmpty()) {
                AuraHandledException e = new AuraHandledException(
                    'Your record did not meet the approval criteria. Please review the record details and try again.'
                );
                e.setMessage(
                    'Your record did not meet the approval criteria. Please review the record details and try again.'
                );
                throw e;
            }

            /*
            -----------------------------------------
            UPDATE STATUS — uses AR_ApprovalStatusMonitor__c
            to get the customer-configured field API name
            -----------------------------------------
            */

            // Resolve the status field API name from the first active rule.
            // Fallback to 'Status' if the field is not configured.
            String statusFieldApiName = 'Status';
            for (Approval_Framework_Config__c rule : rules) {
                if (String.isNotBlank(rule.AR_ApprovalStatusMonitor__c)) {
                    statusFieldApiName = rule.AR_ApprovalStatusMonitor__c.trim();
                    break;
                }
            }
            System.debug('STATUS FIELD API NAME >> [' + statusFieldApiName + ']');

            SObject updateRecord = recordId.getSObjectType().newSObject(recordId);
            updateRecord.put(statusFieldApiName, 'In Review');
            update updateRecord;

            /*
            -----------------------------------------
            BUILD FLOW INPUTS — ONE KEY PER PROCESS
            (now supports L1, L2, and L3)
            -----------------------------------------
            */

            List<String> processNames = new List<String>(matchedByProcess.keySet());
            processNames.sort();

            Map<String, Object> inputs = new Map<String, Object>{
                'recordId'           => recordId,
                'submissionComments' => submitterComments,
                'submitter'          => UserInfo.getUserId(),
                'ObjectApiName'      => null
            };

            for (Integer i = 0; i < processNames.size(); i++) {

                String            processName = processNames[i];
                List<MatchedRule> levels      = matchedByProcess.get(processName);

                MatchedRule l1 = levels.size() > 0 ? levels[0] : null;
                MatchedRule l2 = levels.size() > 1 ? levels[1] : null;
                MatchedRule l3 = levels.size() > 2 ? levels[2] : null;

                String approvalTypeKey = (l1 != null && String.isNotBlank(l1.approvalType))
                    ? l1.approvalType.replace(' ', '')
                    : (l1 != null ? processName.replace(' ', '') : processName.replace(' ', ''));

                inputs.put(approvalTypeKey + '_FirstApprover',  l1 != null ? l1.approver      : null);
                inputs.put(approvalTypeKey + '_SecondApprover', l2 != null ? l2.approver      : null);
                inputs.put(approvalTypeKey + '_ThirdApprover',  l3 != null ? l3.approver      : null);
                inputs.put(approvalTypeKey + '_ApprovalLevel',  l1 != null ? l1.approvalLevel : null);
                inputs.put(approvalTypeKey + '_ApprovalType',   l1 != null ? l1.approvalType  : null);
                inputs.put(approvalTypeKey + '_ProcessName',    processName);
                inputs.put(approvalTypeKey + '_IsSequencing',   l1 != null ? l1.isSequencing  : false);

                if (i == 0 && l1 != null) {
                    inputs.put('ObjectApiName', l1.objectName);
                }

                System.debug(
                    '=== FLOW INPUT FOR PROCESS ===' +
                    ' | approvalTypeKey: [' + approvalTypeKey                               + ']' +
                    ' | processName: ['     + processName                                   + ']' +
                    ' | FirstApprover: ['   + (l1 != null ? l1.approver      : 'NONE')      + ']' +
                    ' | SecondApprover: ['  + (l2 != null ? l2.approver      : 'NONE')      + ']' +
                    ' | ThirdApprover: ['   + (l3 != null ? l3.approver      : 'NONE')      + ']' +
                    ' | ApprovalType: ['    + (l1 != null ? l1.approvalType  : 'NONE')      + ']' +
                    ' | ApprovalLevel: ['   + (l1 != null ? l1.approvalLevel : 'NONE')      + ']'
                );
            }

            /*
            -----------------------------------------
            START FLOW — SINGLE INVOCATION
            -----------------------------------------
            */

            System.debug('=== FINAL FLOW INPUTS: ' + inputs + ' ===');

            Flow.Interview interview = Flow.Interview.createInterview(
                'Accelerator_Approval_Process',
                inputs
            );

            interview.start();
        }
        catch (AuraHandledException e) {
            throw e;
        }
        catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    /*
    ------------------------------------------------
    CUSTOM EXPRESSION EVALUATOR
    ------------------------------------------------
    */

    @TestVisible
    private static Boolean evaluateCustomExpression(String expression, Map<Integer, Boolean> condResults) {

        if (String.isBlank(expression)) {
            System.debug('WARNING — Custom Evaluation_Condition__c is blank. Defaulting to false.');
            return false;
        }

        try {
            List<String> tokens = tokenize(expression.toUpperCase());
            Integer[] pos = new Integer[]{ 0 };
            Boolean result = parseOr(tokens, pos, condResults);
            System.debug('CUSTOM EXPRESSION [' + expression + '] => ' + result);
            return result;
        } catch (Exception e) {
            System.debug('ERROR evaluating custom expression [' + expression + ']: ' + e.getMessage());
            return false;
        }
    }

    private static List<String> tokenize(String expr) {
        List<String> tokens = new List<String>();
        Integer i = 0;
        while (i < expr.length()) {
            String ch = expr.substring(i, i + 1);
            if (ch == ' ') {
                i++;
            } else if (ch == '(' || ch == ')') {
                tokens.add(ch);
                i++;
            } else if (ch.isNumeric()) {
                Integer j = i;
                while (j < expr.length() && expr.substring(j, j + 1).isNumeric()) { j++; }
                tokens.add(expr.substring(i, j));
                i = j;
            } else {
                if (expr.length() >= i + 3 && expr.substring(i, i + 3) == 'AND') {
                    tokens.add('AND'); i += 3;
                } else if (expr.length() >= i + 2 && expr.substring(i, i + 2) == 'OR') {
                    tokens.add('OR'); i += 2;
                } else if (expr.length() >= i + 3 && expr.substring(i, i + 3) == 'NOT') {
                    tokens.add('NOT'); i += 3;
                } else {
                    i++;
                }
            }
        }
        return tokens;
    }

    private static Boolean parseOr(List<String> tokens, Integer[] pos, Map<Integer, Boolean> condResults) {
        Boolean left = parseAnd(tokens, pos, condResults);
        while (pos[0] < tokens.size() && tokens[pos[0]] == 'OR') {
            pos[0]++;
            Boolean right = parseAnd(tokens, pos, condResults);
            left = left || right;
        }
        return left;
    }

    private static Boolean parseAnd(List<String> tokens, Integer[] pos, Map<Integer, Boolean> condResults) {
        Boolean left = parseNot(tokens, pos, condResults);
        while (pos[0] < tokens.size() && tokens[pos[0]] == 'AND') {
            pos[0]++;
            Boolean right = parseNot(tokens, pos, condResults);
            left = left && right;
        }
        return left;
    }

    private static Boolean parseNot(List<String> tokens, Integer[] pos, Map<Integer, Boolean> condResults) {
        if (pos[0] < tokens.size() && tokens[pos[0]] == 'NOT') {
            pos[0]++;
            return !parsePrimary(tokens, pos, condResults);
        }
        return parsePrimary(tokens, pos, condResults);
    }

    private static Boolean parsePrimary(List<String> tokens, Integer[] pos, Map<Integer, Boolean> condResults) {
        if (pos[0] >= tokens.size()) return false;
        String token = tokens[pos[0]];

        if (token == '(') {
            pos[0]++;
            Boolean result = parseOr(tokens, pos, condResults);
            if (pos[0] < tokens.size() && tokens[pos[0]] == ')') {
                pos[0]++;
            }
            return result;
        }

        pos[0]++;
        try {
            Integer condNum = Integer.valueOf(token);
            Boolean val = condResults.containsKey(condNum) ? condResults.get(condNum) : false;
            System.debug('TOKEN [' + condNum + '] => ' + val);
            return val;
        } catch (Exception e) {
            System.debug('Unexpected token: ' + token);
            return false;
        }
    }

    /*
    ------------------------------------------------
    FIELD VALUE READER
    ------------------------------------------------
    */

    private static Object getFieldValue(SObject record, String fieldPath) {

        if (String.isBlank(fieldPath)) {
            return null;
        }

        if (!fieldPath.contains('.')) {
            try {
                return record.get(fieldPath);
            } catch (Exception e) {
                System.debug('Error reading field ' + fieldPath + ': ' + e.getMessage());
                return null;
            }
        }

        List<String> parts = fieldPath.split('\\.');
        SObject current = record;

        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) return null;
            try {
                current = current.getSObject(parts[i]);
            } catch (Exception e) {
                System.debug('Error traversing ' + parts[i] + ': ' + e.getMessage());
                return null;
            }
        }

        if (current == null) return null;

        try {
            return current.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            System.debug('Error reading final field: ' + e.getMessage());
            return null;
        }
    }

    /*
    ------------------------------------------------
    CONDITION EVALUATOR
    ------------------------------------------------
    */

    private static Boolean evaluateCondition(Object fieldVal, String operator, String ruleVal) {

        if (fieldVal == null) return false;

        String op = operator == null ? '' : operator.trim();

        if      (op.equalsIgnoreCase('Equals'))                   op = '=';
        else if (op.equalsIgnoreCase('Not equals To'))             op = '!=';
        else if (op.equalsIgnoreCase('Greater Than or Equal To')) op = '>=';
        else if (op.equalsIgnoreCase('Less Than or Equal To'))    op = '<=';
        else if (op.equalsIgnoreCase('Greater Than'))             op = '>';
        else if (op.equalsIgnoreCase('Less Than'))                op = '<';
        else if (op.equalsIgnoreCase('Contains'))                 op = 'CONTAINS';
        else if (op.equalsIgnoreCase('Starts With'))              op = 'STARTS_WITH';

        String strField = String.valueOf(fieldVal);

        if (op == '>' || op == '<' || op == '>=' || op == '<=') {
            try {
                Decimal numField = Decimal.valueOf(strField);
                Decimal numRule  = Decimal.valueOf(ruleVal);
                if (op == '>')  return numField > numRule;
                if (op == '<')  return numField < numRule;
                if (op == '>=') return numField >= numRule;
                if (op == '<=') return numField <= numRule;
            } catch (Exception e) {
                return false;
            }
        }

        if (op == '=')           return strField.equalsIgnoreCase(ruleVal);
        if (op == '!=')          return !strField.equalsIgnoreCase(ruleVal);
        if (op == 'CONTAINS')    return strField.toLowerCase().contains(ruleVal.toLowerCase());
        if (op == 'STARTS_WITH') return strField.toLowerCase().startsWith(ruleVal.toLowerCase());

        System.debug('WARNING — Unrecognised operator: [' + operator + ']');
        return false;
    }

    /*
    ------------------------------------------------
    INNER CLASS
    ------------------------------------------------
    */

    public class MatchedRule {

        public String  approver;
        public String  approverName;
        public String  approverEmail;
        public String  approverType;
        public String  approvalType;
        public String  approvalLevel;
        public String  objectName;
        public String  processName;
        public Boolean isSequencing;

        public MatchedRule(Approval_Framework_Config__c rule) {
            this.approver      = rule.Approver_Value__r != null ? rule.Approver_Value__r.Username : null;
            this.approverName  = rule.Approver_Value__r != null ? rule.Approver_Value__r.Name     : null;
            this.approverEmail = rule.Approver_Value__r != null ? rule.Approver_Value__r.Email    : null;
            this.approverType  = rule.Approver_Type__c;
            this.approvalType  = rule.Approval_Type__c;
            this.approvalLevel = rule.Level_Number__c;
            this.objectName    = rule.Object_API_Name__c;
            this.processName   = rule.Process_Name__c;
            this.isSequencing  = rule.isSequencing__c;
        }
    }
}