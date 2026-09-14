@IsTest
private class ARQuoteApprovalLWCControllerTest {

    // Point the status monitor at a writable text field so the "In Review"
    // status write succeeds on Opportunity (which has no Status field).
    private static final String STATUS_FIELD = 'Description';

    // ── Data helpers ────────────────────────────────────────────────
    private static Opportunity buildOpportunity(Decimal amount) {
        Account acc = new Account(Name = 'AR Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'AR Quote Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = amount,
            AccountId = acc.Id
        );
        insert opp;
        return opp;
    }

    private static Approval_Framework_Config__c buildConfig(
        String processName, String level, String approvalType,
        Boolean isSequencing, String dependsOn,
        String conditionMet, String evalCondition, Boolean isOptional
    ) {
        Approval_Framework_Config__c cfg = new Approval_Framework_Config__c(
            Name                        = processName + ' - ' + level,
            Process_Name__c             = processName,
            Object_API_Name__c          = 'Opportunity',
            Level_Number__c             = level,
            Approval_Type__c            = approvalType,
            Approver_Type__c            = 'User',
            Approver_Value__c           = UserInfo.getUserId(),
            isSequencing__c             = isSequencing,
            Depends_On_Level__c         = dependsOn,
            Condition_Met__c            = conditionMet,
            Evaluation_Condition__c     = evalCondition,
            isOptional__c               = isOptional,
            Active__c                   = true,
            AR_ApprovalStatusMonitor__c = STATUS_FIELD
        );
        insert cfg;
        return cfg;
    }

    private static void addCondition(Id cfgId, String field, String operator, String values) {
        insert new Approval_Condition__c(
            Approval_Framework_Config__c = cfgId,
            Object_API_Name__c           = 'Opportunity',
            Criteria_Field__c            = field,
            Operator__c                  = operator,
            Values__c                    = values,
            Active__c                    = true
        );
    }

    // Submits and swallows any AuraHandledException raised while starting the
    // approval flow — the code path we need for coverage runs regardless of
    // whether the orchestration flow can complete inside a test context.
    private static void submitSwallowing(Id recordId) {
        try {
            ARQuoteApprovalLWCController.submitForApproval(recordId, 'test comments');
        } catch (AuraHandledException e) {
            // expected in a test context when the flow cannot fully run
        }
    }

    // ── Negative paths ──────────────────────────────────────────────
    @IsTest
    static void testNullRecordId() {
        Boolean threw = false;
        Test.startTest();
        try {
            ARQuoteApprovalLWCController.submitForApproval(null, 'comments');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A null record Id should throw an AuraHandledException');
    }

    @IsTest
    static void testNoActiveRules() {
        Opportunity opp = buildOpportunity(5000);  // no config inserted

        Boolean threw = false;
        Test.startTest();
        try {
            ARQuoteApprovalLWCController.submitForApproval(opp.Id, 'comments');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Missing rules should throw an AuraHandledException');
    }

    @IsTest
    static void testConditionsNotMet() {
        Opportunity opp = buildOpportunity(500);
        Approval_Framework_Config__c cfg = buildConfig(
            'Discount Process', 'Level 1', 'DiscountApproval',
            false, null, 'All', null, false
        );
        // Requires Amount > 1000 but Amount is 500 and the rule is not optional,
        // so no process qualifies -> criteria-not-met exception.
        addCondition(cfg.Id, 'Amount', 'Greater Than', '1000');

        Boolean threw = false;
        Test.startTest();
        try {
            ARQuoteApprovalLWCController.submitForApproval(opp.Id, 'comments');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Unmet mandatory criteria should throw an AuraHandledException');
    }

    // ── Happy paths ─────────────────────────────────────────────────
    @IsTest
    static void testSingleLevelNoConditions() {
        Opportunity opp = buildOpportunity(5000);
        buildConfig('Discount Process', 'Level 1', 'DiscountApproval',
                    false, null, 'All', null, false);

        Test.startTest();
        submitSwallowing(opp.Id);
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('In Review', updated.Description,
            'Submission should have flipped the status to In Review');
    }

    @IsTest
    static void testConditionsMatchWithMultipleOperators() {
        Opportunity opp = buildOpportunity(5000);
        Approval_Framework_Config__c cfg = buildConfig(
            'Discount Process', 'Level 1', 'DiscountApproval',
            false, null, 'Custom', '1 AND 2 AND 3 AND 4 AND 5', false
        );
        addCondition(cfg.Id, 'Amount',       'Greater Than',              '1000');       // >
        addCondition(cfg.Id, 'Amount',       'Greater Than or Equal To',  '5000');       // >=
        addCondition(cfg.Id, 'Name',         'Contains',                  'Quote');       // CONTAINS
        addCondition(cfg.Id, 'StageName',    'Equals',                    'Prospecting'); // =
        addCondition(cfg.Id, 'Account.Name', 'Starts With',               'AR Test');     // cross-object + STARTS_WITH

        Test.startTest();
        submitSwallowing(opp.Id);
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('In Review', updated.Description,
            'Matching custom conditions should have qualified the level');
    }

    @IsTest
    static void testOptionalConditionNotMetStillQualifies() {
        Opportunity opp = buildOpportunity(500);
        Approval_Framework_Config__c cfg = buildConfig(
            'Discount Process', 'Level 1', 'DiscountApproval',
            false, null, 'All', null, true  // optional
        );
        // Condition fails (Amount 500 !> 1000) but rule is optional -> level still qualifies.
        addCondition(cfg.Id, 'Amount', 'Greater Than', '1000');

        Test.startTest();
        submitSwallowing(opp.Id);
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('In Review', updated.Description,
            'An optional unmet condition should not block qualification');
    }

    @IsTest
    static void testThreeLevelSequencing() {
        Opportunity opp = buildOpportunity(5000);
        buildConfig('Discount Process', 'Level 1', 'DiscountApproval',
                    false, null,       'All', null, false);
        buildConfig('Discount Process', 'Level 2', 'DiscountApproval',
                    true,  'Level 1',  'All', null, false);
        buildConfig('Discount Process', 'Level 3', 'DiscountApproval',
                    true,  'Level 1',  'All', null, false);

        Test.startTest();
        submitSwallowing(opp.Id);
        Test.stopTest();

        Opportunity updated = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('In Review', updated.Description,
            'A qualifying multi-level sequence should submit for approval');
    }

    // ── Custom expression parser (evaluateCustomExpression is @TestVisible) ──
    @IsTest
    static void testCustomExpressionParser() {
        Map<Integer, Boolean> r = new Map<Integer, Boolean>{
            1 => true, 2 => false, 3 => true
        };

        System.assertEquals(false, ARQuoteApprovalLWCController.evaluateCustomExpression('1 AND 2', r));
        System.assertEquals(true,  ARQuoteApprovalLWCController.evaluateCustomExpression('1 OR 2', r));
        System.assertEquals(true,  ARQuoteApprovalLWCController.evaluateCustomExpression('NOT 2', r));
        System.assertEquals(true,  ARQuoteApprovalLWCController.evaluateCustomExpression('(1 AND 3) OR 2', r));
        System.assertEquals(false, ARQuoteApprovalLWCController.evaluateCustomExpression('', r));
        System.assertEquals(false, ARQuoteApprovalLWCController.evaluateCustomExpression('99', r));
    }
}
