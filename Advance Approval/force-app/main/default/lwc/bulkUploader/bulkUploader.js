import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadScript } from 'lightning/platformResourceLoader';
import SHEETJS from '@salesforce/resourceUrl/sheetjs';
import insertBulkRecords from '@salesforce/apex/BulkUploaderController.insertBulkRecords';
import getTemplateFileId from '@salesforce/apex/BulkUploaderController.getTemplateFileId';

/**
 * PARENT field columns (columns 0–11 in the Excel, 0-indexed).
 * Column 12 onward are child fields.
 *
 * Multi-condition grouping strategy (group-by-Name):
 *  • To add a second (or third…) Approval_Condition__c to the SAME parent,
 *    repeat the full row with the SAME Name value and fill in the different
 *    condition columns (Criteria_Field__c, Operator__c, Values__c, child Active__c).
 *    All parent-column values on the repeated row are ignored — the first row wins.
 *  • The old blank-Name continuation format is still accepted for backwards
 *    compatibility (a blank Name row is treated as a continuation of the
 *    most-recently started parent).
 *
 * Example Excel layout (new format):
 *   │ Name           │ Process_Name │ … │ Criteria_Field │ Operator │ Values  │
 *   │ Parent Record 1│ Proc A       │ … │ Status__c      │ =        │ Active  │  ← parent + condition 1
 *   │ Parent Record 1│ Proc A       │ … │ Amount__c      │ >        │ 1000    │  ← same name → condition 2
 *   │ Parent Record 2│ Proc B       │ … │ Region__c      │ =        │ East    │  ← new name → new parent
 */
const PARENT_FIELDS = [
    'Name', 'Process_Name__c', 'Object_API_Name__c', 'Level_Number__c',
    'Approval_Type__c', 'Approver_Type__c', 'Approver_Value__c',
    'isSequencing__c', 'Active__c', 'Condition_Met__c',
    'Evaluation_Condition__c', 'Depends_On_Level__c'
];

const CHILD_FIELDS = [
    'Criteria_Field__c', 'Operator__c', 'Values__c',
    'Approval_Framework_Config__c', 'Active__c'     // Active__c here = child Active
];

const REQUIRED_PARENT = ['Name', 'Process_Name__c', 'Object_API_Name__c'];
const BOOLEAN_FIELDS  = ['isSequencing__c', 'Active__c'];

export default class BulkUploader extends LightningElement {
    @track currentStep = 1;
    @track isProcessing = false;
    @track fileName = '';
    @track parsedData = [];         // one entry per PARENT row (grouped)
    @track previewRows = [];
    @track validationErrors = [];
    @track totalRows = 0;
    @track validRows = 0;
    @track errorRows = 0;
    @track insertResults = [];
    @track insertedCount = 0;
    @track insertedChildCount = 0;
    @track insertSuccess = false;
    @track sheetJsLoaded = false;

    /* ── Path Steps ──────────────────────────────────────────────── */
    get pathSteps() {
        const steps = [
            { id: 's1', title: 'Download Template' },
            { id: 's2', title: 'Upload File' },
            { id: 's3', title: 'Preview & Validate' },
            { id: 's4', title: 'Insert Records' },
        ];
        return steps.map((s, i) => {
            const n          = i + 1;
            const isComplete = this.currentStep > n;
            const isActive   = this.currentStep === n;
            return {
                ...s,
                label: isComplete ? '✓' : String(n),
                wrapClass: `path-item${isComplete ? ' complete' : ''}${isActive ? ' active' : ''}`
            };
        });
    }

    /* ── Step visibility getters ─────────────────────────────────── */
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }

    get hasErrors()      { return this.errorRows > 0; }
    get insertDisabled() { return this.validRows === 0; }

    /* ── Lifecycle ───────────────────────────────────────────────── */
    connectedCallback() {
        this._loadSheetJs();
    }

    _loadSheetJs() {
        loadScript(this, SHEETJS)
            .then(() => { this.sheetJsLoaded = true; })
            .catch(err => {
                this._toast('Error', 'Failed to load SheetJS library: ' + err.message, 'error');
            });
    }

    /* ── Navigation ──────────────────────────────────────────────── */
    goToStep1() { this.currentStep = 1; }
    goToStep2() { this.currentStep = 2; }

    /* ── Step 1: Download Template ───────────────────────────────── */
    downloadTemplate() {
        getTemplateFileId()
            .then(fileId => {
                if (fileId) {
                    const url = `/sfc/servlet.shepherd/document/download/${fileId}`;
                    window.open(url, '_blank');
                } else {
                    this._toast('Info', 'Template file not configured in org. Please contact your admin.', 'info');
                }
            })
            .catch(() => {
                this._toast('Info', 'Template file not found. Please contact your admin.', 'info');
            });
    }

    /* ── Step 2: File Upload ─────────────────────────────────────── */
    triggerFileInput() {
        const input = this.template.querySelector('.hidden-file-input');
        if (input) input.click();
    }

    handleFileChange(event) {
        const files = event.target.files;
        if (!files || files.length === 0) return;

        if (!this.sheetJsLoaded) {
            this._toast('Error', 'SheetJS not loaded yet. Please try again.', 'error');
            return;
        }

        const file        = files[0];
        this.fileName     = file.name;
        this.isProcessing = true;

        const reader = new FileReader();
        reader.onload = (e) => { this._parseExcel(e.target.result); };
        reader.onerror = () => {
            this.isProcessing = false;
            this._toast('Error', 'Failed to read the selected file. Please try again.', 'error');
        };
        reader.readAsArrayBuffer(file);
    }

    /* ── Excel Parsing ───────────────────────────────────────────── */
    _parseExcel(buffer) {
        try {
            // eslint-disable-next-line no-undef
            const XLSX      = window.XLSX;
            const workbook  = XLSX.read(buffer, { type: 'array', cellDates: true });
            const sheetName = workbook.SheetNames[0];
            const sheet     = workbook.Sheets[sheetName];

            // Skip section-label row (row 1), use row 2 as header
            const rawRows = XLSX.utils.sheet_to_json(sheet, {
                header: 1,
                range: 1,
                defval: ''
            });

            if (rawRows.length < 2) {
                this.isProcessing = false;
                this._toast('Warning', 'No data rows found in the Excel file.', 'warning');
                return;
            }

            const headerRow = rawRows[0];
            const dataRows  = rawRows.slice(1);
            const colMap    = this._buildColumnMap(headerRow);

            // ── Multi-child grouping (group-by-Name strategy) ─────────────
            //
            // Rules:
            //  1. A row whose Name is NON-BLANK and has NOT been seen before
            //     starts a fresh parent group.
            //  2. A row whose Name matches an ALREADY-SEEN parent name appends
            //     its child columns (Criteria_Field, Operator, Values, Active)
            //     as an additional Approval_Condition__c on that parent.
            //     All other parent-column values on the duplicate-name row are
            //     ignored — the first occurrence wins for parent fields.
            //  3. A row whose Name is BLANK still works as a "continuation"
            //     row appended to the most-recently started parent (backwards
            //     compatible with the old blank-name format).
            //
            // Excel layout expected (new format):
            //   Row A  │ Parent Record 1 │ Process_Name │ ... │ Criteria_Field1 │ Operator1 │ Values1 │ Active1 │
            //   Row B  │ Parent Record 1 │ Process_Name │ ... │ Criteria_Field2 │ Operator2 │ Values2 │ Active2 │  ← same name → extra condition
            //   Row C  │ Parent Record 1 │ Process_Name │ ... │ Criteria_Field3 │ Operator3 │ Values3 │ Active3 │  ← same name → extra condition
            //   Row D  │ Parent Record 2 │ Process_Name │ ... │ Criteria_Field1 │ Operator1 │ Values1 │ Active1 │  ← new name → new parent
            //
            // Result: 2 Approval_Framework_Config__c records,
            //         3 Approval_Condition__c for Parent Record 1,
            //         1 Approval_Condition__c for Parent Record 2.

            const allMappedRows = dataRows
                .filter(row => row.some(cell => cell !== '' && cell !== null && cell !== undefined))
                .map((row, idx) => this._mapRawRow(row, colMap, idx + 3));

            const grouped = [];
            // Map from normalised Name → index in grouped[] for O(1) lookup
            const nameToGroupIdx = {};
            let excelDataRowOffset = 0;

            allMappedRows.forEach(mapped => {
                const nameVal = mapped.Name ? String(mapped.Name).trim() : '';

                if (nameVal !== '') {
                    const normName = nameVal.toLowerCase();

                    if (nameToGroupIdx.hasOwnProperty(normName)) {
                        // ── Duplicate name → add child to existing parent ──
                        grouped[nameToGroupIdx[normName]]._childDataList.push(
                            this._extractChildData(mapped)
                        );
                    } else {
                        // ── New name → start a fresh parent group ──────────
                        nameToGroupIdx[normName] = grouped.length;
                        grouped.push({
                            ...mapped,
                            _childDataList: [ this._extractChildData(mapped) ]
                        });
                    }
                } else if (grouped.length > 0) {
                    // ── Blank name → legacy continuation row ───────────────
                    // Attach child to the most recently started parent
                    grouped[grouped.length - 1]._childDataList.push(
                        this._extractChildData(mapped)
                    );
                }
                // Rows before the first parent (orphan blank-name rows) are ignored.
                excelDataRowOffset++;
            });

            this.parsedData   = grouped;
            this._validate();
            this.isProcessing = false;
            this.currentStep  = 3;

        } catch (err) {
            this.isProcessing = false;
            this._toast('Error', 'Failed to parse Excel: ' + err.message, 'error');
        }
    }

    _buildColumnMap(headerRow) {
        const map = {};
        headerRow.forEach((cell, idx) => {
            const name = String(cell || '').trim();
            if (name) map[idx] = name;
        });
        return map;
    }

    /**
     * Maps a single raw Excel row to a flat object using the column map.
     * Boolean fields are normalised to 'true'/'false' strings.
     * The child Active__c column (which shares the same header as parent Active__c
     * but sits at index >= PARENT_FIELDS.length) is stored as `childActive`.
     */
    _mapRawRow(row, colMap, excelRowNum) {
        const record = { _rowNum: excelRowNum, _errors: [] };

        Object.entries(colMap).forEach(([idxStr, fieldName]) => {
            const idx = parseInt(idxStr, 10);
            let val   = row[idx];

            if (BOOLEAN_FIELDS.includes(fieldName)) {
                val = this._parseBoolean(val);
            } else {
                val = val !== undefined && val !== null ? String(val).trim() : '';
            }

            // Column index >= PARENT_FIELDS.length AND named Active__c
            // → this is the child Active__c, not the parent one
            if (idx >= PARENT_FIELDS.length && fieldName === 'Active__c') {
                record['childActive'] = val;
            } else {
                record[fieldName] = val;
            }
        });

        return record;
    }

    /**
     * Extracts only the child-relevant fields from a mapped row.
     * This object becomes one entry in the parent's _childDataList
     * and is sent as one element of childDataList in the Apex payload.
     */
    _extractChildData(mappedRow) {
        return {
            Criteria_Field__c: mappedRow.Criteria_Field__c || '',
            Operator__c:       mappedRow.Operator__c       || '',
            Values__c:         mappedRow.Values__c         || '',
            Active__c:         mappedRow.childActive       || ''
        };
    }

    _parseBoolean(val) {
        if (val === true  || String(val).toLowerCase() === 'true')  return 'true';
        if (val === false || String(val).toLowerCase() === 'false') return 'false';
        return String(val || '').trim();
    }

    /* ── Validation ──────────────────────────────────────────────── */
    _validate() {
        this.validationErrors = [];

        this.parsedData.forEach(row => {
            row._errors = [];

            // Required parent fields
            REQUIRED_PARENT.forEach(field => {
                if (!row[field] || row[field] === '') {
                    row._errors.push({ field, message: `${field} is required` });
                }
            });

            // Boolean parent fields
            BOOLEAN_FIELDS.forEach(field => {
                const val = row[field];
                if (val && val !== 'true' && val !== 'false') {
                    row._errors.push({ field, message: `${field} must be TRUE or FALSE` });
                }
            });

            // Validate each child entry — child Active__c must be boolean if provided
            (row._childDataList || []).forEach((cd, cdIdx) => {
                const childActive = cd.Active__c;
                if (childActive && childActive !== 'true' && childActive !== 'false') {
                    row._errors.push({
                        field:   `Child[${cdIdx + 1}] Active__c`,
                        message: `Child row ${cdIdx + 1} Active__c must be TRUE or FALSE`
                    });
                }
            });

            if (row._errors.length > 0) {
                row._errors.forEach(err => {
                    this.validationErrors.push({
                        id:      `${row._rowNum}-${err.field}`,
                        row:     row._rowNum,
                        field:   err.field,
                        message: err.message
                    });
                });
            }
        });

        this.totalRows   = this.parsedData.length;
        this.errorRows   = this.parsedData.filter(r => r._errors.length > 0).length;
        this.validRows   = this.totalRows - this.errorRows;

        // Build preview rows — one entry per PARENT (grouped record)
        this.previewRows = this.parsedData.slice(0, 10).map(row => {
            // Flatten first child data for column display convenience
            const firstChild   = (row._childDataList && row._childDataList.length > 0)
                                    ? row._childDataList[0] : {};
            const conditionCount = (row._childDataList || []).filter(cd =>
                cd.Criteria_Field__c || cd.Operator__c || cd.Values__c
            ).length;

            return {
                ...row,
                rowNum:          row._rowNum,
                hasError:        row._errors.length > 0,
                rowClass:        row._errors.length > 0 ? 'slds-hint-parent error-row' : 'slds-hint-parent',
                conditionCount:  conditionCount,
                // First child preview columns
                previewCriteria: firstChild.Criteria_Field__c || '',
                previewOperator: firstChild.Operator__c       || '',
                previewValues:   firstChild.Values__c         || '',
                previewChildAct: firstChild.Active__c         || '',
                // Tooltip-friendly summary of all conditions
                conditionSummary: (row._childDataList || [])
                    .filter(cd => cd.Criteria_Field__c || cd.Operator__c || cd.Values__c)
                    .map((cd, i) => `#${i + 1}: ${cd.Criteria_Field__c} ${cd.Operator__c} ${cd.Values__c}`)
                    .join(' | ')
            };
        });
    }

    /* ── Step 3 → 4: Insert ──────────────────────────────────────── */
    insertRecords() {
        this._doInsert(this.parsedData);
    }

    insertValidOnly() {
        this._doInsert(this.parsedData.filter(r => r._errors.length === 0));
    }

    _doInsert(rows) {
        if (rows.length === 0) {
            this._toast('Warning', 'No valid rows to insert.', 'warning');
            return;
        }

        this.currentStep  = 4;
        this.isProcessing = true;

        const payload = rows.map(row => ({
            rowNum: row._rowNum,
            name:   row.Name,
            parentData: {
                Name:                       row.Name,
                Process_Name__c:            row.Process_Name__c,
                Object_API_Name__c:         row.Object_API_Name__c,
                Level_Number__c:            row.Level_Number__c,
                Approval_Type__c:           row.Approval_Type__c,
                Approver_Type__c:           row.Approver_Type__c,
                Approver_Value__c:          row.Approver_Value__c,
                isSequencing__c:            row.isSequencing__c,
                Active__c:                  row.Active__c,
                Condition_Met__c:           row.Condition_Met__c,
                Evaluation_Condition__c:    row.Evaluation_Condition__c,
                Depends_On_Level__c:        row.Depends_On_Level__c,
                AR_ApprovalStatusMonitor__c: row.AR_ApprovalStatusMonitor__c
            },
            // childDataList replaces the old single childData —
            // each entry produces one Approval_Condition__c in Apex.
            childDataList: (row._childDataList || []).map(cd => ({
                Criteria_Field__c: cd.Criteria_Field__c || '',
                Operator__c:       cd.Operator__c       || '',
                Values__c:         cd.Values__c         || '',
                Active__c:         cd.Active__c         || ''
                // Approval_Framework_Config__c is intentionally omitted;
                // Apex auto-assigns it from the newly created parent Id.
            }))
        }));

        insertBulkRecords({ payloadJson: JSON.stringify(payload) })
            .then(result => {
                const parsed            = JSON.parse(result);
                this.insertResults      = parsed.results;
                this.insertedCount      = parsed.parentInserted;
                this.insertedChildCount = parsed.childInserted;
                this.insertSuccess      = parsed.success;
                this.isProcessing       = false;

                if (parsed.success) {
                    this._toast('Success',
                        `Inserted ${parsed.parentInserted} parent and ${parsed.childInserted} child records.`,
                        'success');
                    // Redirect to Approval Framework Config list view after a short delay
                    // so the user can see the success toast before navigating away.
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => {
                        window.location.href = '/lightning/o/Approval_Framework_Config__c/list?filterName=__Recent';
                    }, 1500);
                } else {
                    this._toast('Warning', 'Some records failed to insert. See results for details.', 'warning');
                }
            })
            .catch(err => {
                this.isProcessing  = false;
                this.insertSuccess = false;
                this._toast('Error', 'Insert failed: ' + (err.body ? err.body.message : err.message), 'error');
            });
    }

    /* ── Reset ───────────────────────────────────────────────────── */
    resetUploader() {
        this.currentStep        = 1;
        this.parsedData         = [];
        this.previewRows        = [];
        this.validationErrors   = [];
        this.totalRows          = 0;
        this.validRows          = 0;
        this.errorRows          = 0;
        this.insertResults      = [];
        this.insertedCount      = 0;
        this.insertedChildCount = 0;
        this.insertSuccess      = false;
        this.fileName           = '';
        const input = this.template.querySelector('.hidden-file-input');
        if (input) input.value = '';
    }

    /* ── Utility ─────────────────────────────────────────────────── */
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}