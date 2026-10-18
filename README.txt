Native AX Engine
===============

Purpose
Extract the complete accessibility graph currently exposed by a selected
running macOS app, and record additional states through explicitly selected
native accessibility actions. Native AX data is the only source of nodes.

The graph records both containment and other element relationships. A leaf
means no children under the declared containment attributes, with those
hierarchy reads resolved. Parent and cross-reference links can form cycles.
Failed reads, opaque native values, native absence, and retries are recorded.

An app's future states are not one fixed tree. Documents, dialogs, server
data, and input combinations can produce more states. This tool records
observed states and transitions; it does not claim that every future state
or parameterized query has been exhausted.

Requirements
macOS and the installed Apple Swift compiler. No packages or network calls.
The process running the tool must already have macOS Accessibility access.
The tool does not prompt for access or launch an app.

Start
Open Calculator normally, then run from this directory:

  ./ax-engine --app com.apple.calculator --output captures/calculator --verify

The launcher builds the executable when its source has changed. Use
./ax-engine --help for the full command syntax.

Exports stay in the chosen local directory. Native attributes can contain
visible document text, window titles, and menu contents; review an export
before sharing it. The console prints counts, not captured text.

Scope
Capture has no arbitrary node or depth cutoff. Each native request has a
bounded messaging timeout and cannotComplete reads get at most three attempts. An app
can still change while a snapshot is being collected; repeated captures
and recorded fingerprints provide evidence, not an atomic snapshot.

InvalidUIElement hierarchy failures trigger a completely new capture with a
fresh native reference registry. The default is at most three captures per
observation; --capture-attempts 1 disables whole-capture retries. Every completed
attempt is archived immediately. Only the latest attempt is published; graphs
are never merged or chosen by their error count. A vanished element in a later
capture does not resolve its older archived reference. If a later attempt fails,
capture-recovery.json records that failure rather than publishing an older attempt.

Node IDs are local to one snapshot. Native actions must re-resolve the
target against a fresh graph and validate its signature and app identity.
There is no screenshot, OCR, coordinate-click, or synthesized-node fallback.

Commands and output
  ./ax-engine snapshot --app com.apple.calculator --output captures/calculator --verify 3

snapshot.json is the latest full graph. leaves.ndjson contains its confirmed
containment leaves. coverage.json contains counts, errors, and scope.
metadata_read_failures contains failed native reads or malformed native returns.
serialization_warnings contains successful native reads the serializer could
not fully encode. metadata_failures is their combined array for compatibility.
Native noValue responses remain known absence, outside these failure counts.
capture_recovery and capture-recovery.json retain whole-capture attempt evidence.
verification.json describes only the latest repeated observation sequence;
it is invalidated when a later snapshot replaces the current graph.
stategraph.json records observed states and native action attempts.
states/<graph_digest>/snapshot.json retains every unique observed raw graph.

AXTextMarker payloads are captured byte-for-byte as base64 using public macOS
APIs. AXTextMarkerRange preserves both ordered endpoint payloads. They are opaque,
application-defined bytes, not decoded character offsets or persistent selectors.
Runtime API/accessor gaps remain explicit serialization warnings.

CGColor values preserve their native components, alpha, color-space model/name,
public ICC bytes, and indexed color tables/base spaces. CGPath values preserve
ordered native commands and control points without flattening. Numeric values
also carry binary64 bitstrings, including signed zero and nonfinite payloads.
Types are recognized through current public runtime type IDs, never older
exports' numeric IDs. Inaccessible pattern drawing callbacks and unknown
color-space models/path commands remain explicit partial serialization warnings.

Advertised non-hierarchy attributes returning failure, cannotComplete, or
attributeUnsupported receive one native bulk query per node with options=0.
The engine validates the returned array length and each requested attribute's
slot. Actual native values, including false, zero, empty strings and empty
arrays, can resolve a read as a value. A successfully decoded noValue error
from a valid native bulk slot resolves the requested attribute as known absence:
the final status is noValue, no attribute payload or empty array is invented,
and the original failed query remains in the recovery trace. CFNull and other
AX error envelopes remain unresolved. Known scalar attributes AXGrowArea,
AXTopLevelUIElement, AXFrame, AXPosition and AXSize skip array recovery. A
failed/cannotComplete/attributeUnsupported scalar read may obtain a fresh reference from the same
verified application and recorded selector path, require native CFEqual and
owning-process continuity, then make one direct attribute query and recheck
process continuity before accepting its result. Only an
actual native value of the expected type or explicit noValue resolves it.
Failed identity/PID/process checks, nil-success and wrong types retain the
original error. Unsupported scalar reads receive the bounded native read after
an unresolved bulk result; if that native query also fails, its actual status
remains in the trace and the original unsupported error is retained. Returned
element references use normal registry
traversal; no value is inferred from a parent, child, geometry, or role.
For AXTopLevelUIElement on a successfully captured AXMenu/AXMenuItem, scalar
recovery version 3 can query the retained original registry reference when the
fresh path fails solely because one prefix is not CFEqual. Root and prior
prefix equality, every native path/read/type/PID check, and recorded process
continuity must otherwise succeed. The retained owner must match the original
registry node; its native PID, the root PID, and both captured launch identities
are checked before and after the one direct attribute query. The failed fresh
refresh remains recorded. query_target distinguishes fresh_exact_reference
from retained_original_reference; retained_reference and
query_retained_reference_validation retain the before/after native proof.
A retained query supplies the original object's native response at retry time.
It does not establish that object's current membership at the refreshed path.
An expired native UI object can still return invalidUIElement; it is not
converted to a value or inferred absence.
Other still-failed attributes retain native array-count and paged-array
recovery, including unknown/custom attributes. Counts must agree
before and after and each page must contain exactly its requested number of
values. A successful zero count is a genuine empty array; a failed query is
never replaced with one. Hierarchy reads do not use metadata recovery.

A failed action-name enumeration receives one bounded fresh native query;
only an actual successful string array can resolve it. Actions are never
inferred from another attribute or attempted as part of capture.
native_read_recoveries preserves the initial error and every recovery query.
Recovery counters count attributes/enumerations attempted and resolved, rather
than individual API calls. Outcome version 2 records resolution_kind as value,
absence, or unresolved. native_read_recovery_value_successes counts actual
native values; native_read_recovery_absence_successes counts confirmed noValue
responses. Their sum is native_read_recovery_successes, the total resolutions.
Known absence records remain itemized in absent_attribute_values. Older exports
retain their original classifications and original recovery counters.
Scalar recovery version 2 permits the fresh exact-target read for original
attributeUnsupported errors. Version 1 exports retain their earlier routing,
which only retried scalar failure/cannotComplete after bulk recovery.
Version 3 adds the narrowly validated original-menu-reference route. Version
1/2 exports retain their earlier requirement that scalar refresh must succeed.
native_scalar_retained_reference_attempts counts actual direct queries targeting
retained original references. native_scalar_retained_reference_withheld counts
retained validations that did not permit a query. The value_successes and
absence_successes counters under the same prefix count their respective native
outcomes; original errors and rejected refreshes remain in every trace.
native_metadata_failure_summary separately counts attribute_unsupported and
other_read_failures. Both remain included in metadata_read_failures with
their original statuses; the viewer itemizes each category. A provider can
advertise a name while returning attributeUnsupported when its value is read.
Existing exports cannot reconstruct marker bytes,
graphics data, or elements discarded at capture; a fresh native run is required.

Raw graph digests include geometry. Semantic graph digests omit only native
AXPosition/AXSize values, while retaining labels, values, ordering, actions,
other native attributes, and read status. Both are preserved in verification.

A guided transition requires the current snapshot-local node ID AND an exact
expected title or identifier. Inspect snapshot.json before choosing a node:

  ./ax-engine transition --app com.apple.calculator --output captures/calculator \
    --transition-from captures/calculator/snapshot.json --node CURRENT_NODE_ID \
    --action AXPress --expect-title Scientific --label scientific

The tool validates the expected identity in the recorded, fresh, and immediate
native control, plus semantic graph freshness, ancestor/sibling context, and
process launch identity. It refuses stale, ambiguous, or unresolved states.
This is guided exploration; there is no blind click-all-controls crawler.

Transitions are journaled before execution and immediately after their single
attempt. A prepared journal with outcome_not_recorded means the outcome may
be uncertain after interruption; it does not prove that no action occurred.
Actions are never automatically retried. AX success does not prove workflow
completion; inspect the resulting state.

The same output directory supports continued captures of the same running
app. After an app restart, use a new output directory; launch identity checks
refuse reuse of an unrelated process's exports. Running external processes are
followed only when reached through returned native element references. Their
launch identities are recorded and checked; other apps are not extra roots.

Transition exclusions
StudyLock state-changing actions are refused.
Native restart, shutdown, logout, sleep, lock, and force-quit actions are
excluded from guided exploration; read-only capture still records the nodes.

Inspect and verify an export
  python3 audit.py captures/calculator
  python3 report.py captures/calculator
  python3 tree_report.py captures/calculator

audit.py independently checks reachability, shared references, selector paths,
read/failure consistency, leaf classifications, process boundaries, counts,
and leaf/coverage file consistency. report.py creates a local searchable HTML
viewer from retained native graphs, with escaped app text and linked node IDs.
tree_report.py creates the standalone expandable report.html with search,
virtualized rows, native attributes, references, and recovery diagnostics.
Each summary count opens an itemized, searchable list. Node categories contain
one entry per captured node; issue categories contain one entry per recorded
event, including multiple events on the same node. Select an item to inspect
that node and its evidence in the tree.

Validation performed on October 10, 2026
Calculator Basic/View and Scientific states were captured, with a native
Scientific transition and native return to Basic. The original expression
1!×ln(π)×3 and Basic mode were restored and checked through Computer Use.
TextEdit's Open panel exposed 518 nodes / 373 confirmed leaves in a final
resolved capture, including its separate native AppKit helper process.
Calculator captures exposed 235–265 nodes / 201–231 confirmed leaves.
Some optional metadata requests failed or returned opaque native types; these
are reported separately from hierarchy resolution. A transient external
reference cutoff in an earlier TextEdit observation remains in its archive.

The original Swift core passed 44 offline fixtures before the recovery fixes.
Current --self-test includes public text-marker and graphics values, bulk-slot
validation, native-array recovery, bounded action-name reads, and mocked
fresh-capture recovery. It needs no app access. Independent auditor
cases and allowed-app CLI output-integrity checks are included in test_audit.py
and verify_cli.py. Current evidence is in artifacts/native-ax-engine-fixes-20261010.
Graphics/metadata recovery evidence is in artifacts/native-graphics-recovery-20261010:
107 Swift fixtures, 51 auditor tests, 18 viewer projection fixtures and 13
actual-template JavaScript recovery fixtures passed. The six itemized groups
also passed all 1,830 saved-Codex-export pagination checks. Actual Swift helper
JSON passed independent recovery auditing (15 traces across 13 synthetic nodes).
Confirmed-absence recovery evidence is in artifacts/native-absence-recovery-20261010:
123 Swift fixtures, 65 auditor tests, 19 viewer projection fixtures and 14
actual-template JavaScript fixtures passed. Actual bridged helper evidence
contains 22 recovery traces, with seven real values and three confirmed
absences, and passed independent auditing. The saved Codex capture has 1,392
exact decoded noValue bulk replies among 1,458 recorded failures; applying
the corrected classification to those replies leaves 65 unsupported reads
and one failed AXGrowArea read. This is an offline diagnosis, not a new capture.
The raw export and its original counts remain unchanged.
Scalar recovery evidence is in artifacts/native-scalar-recovery-20261010:
173 Swift fixtures, 86 auditor tests, 29 viewer projection fixtures and 23
actual-template JavaScript fixtures passed (311 offline checks). Forty
independent Swift-helper cases passed 3,338 recovery audit checks, including
11 typed values and one confirmed absence. These cases use native value
constructors with mocked reads and process identities; they are not app captures.
The user-run codex-absence-recheck capture records 60 unsupported reads
(57 menu top-level shortcuts and three application-root geometry attributes)
and one failed AXGrowArea read. The original errors remain itemized; the viewer
separates unsupported results from the remaining failure. The new GrowArea
scalar path still needs a fresh authorized capture to measure its live result.
Unsupported-scalar retry evidence is in artifacts/native-scalar-unsupported-recovery-20261010:
188 Swift fixtures, 95 auditor tests, 36 viewer projection fixtures and 30
actual-template JavaScript fixtures passed (349 offline checks). Forty-four
independent constructor-based helper cases passed 3,907 recovery audit checks,
with 13 typed values and three confirmed absences. These mocked native-query
cases cover original attributeUnsupported errors for all five known scalar
attributes; they do not establish live recovery in Codex. Earlier v1 evidence
and saved raw app exports remain unchanged. All 57 captured menu parent chains
lack a window, sheet, or drawer, where the top-level shortcut is required;
the actual window already supplies geometry that the application root does not.
The engine does not substitute either relationship or geometry for the requested
native attribute. A genuinely returned element that fails registration retains
an explicit reference cutoff and incomplete coverage in its export.
Retained menu-reference evidence is in artifacts/native-menu-reference-retry-20261010:
218 Swift fixtures, 106 auditor tests, 43 viewer projection fixtures and 37
actual-template JavaScript fixtures passed (404 offline checks). Seven synthetic
generic-report cases also passed. Thirty-five independent native-helper contexts
passed 3,855 audit checks. Instrumented callbacks issued 14 original-reference
queries and withheld eight after failed validation; retained results included
two typed values and one confirmed absence. These are constructor-based cases
with mocked app/PID/process callbacks, not live menu captures. The self-tests
exercise native Int32 status values before JSON serialization, including the
successful captured AXRole status used by production routing.
All 36 withheld reads in the saved codex-unsupported-recheck capture qualify
for original-reference validation under the new policy. The saved export remains
unchanged and cannot supply a live retained object to a later process; a new
capture must measure whether original references remain usable and return values.
These are offline checks. The agent's CLI process lacked macOS Accessibility
permission at its Calculator capture check. Later user-run captures are saved
in artifacts/calculator-recheck-native and artifacts/codex-recheck-native.
Run the rebuilt launcher from a Terminal process already authorized for
Accessibility to measure native recovery on the live app. The older saved
captures retain their original values, failures and serialization warnings.
Native containment coverage describes the recorded states, not every possible
future state or all optional cross-reference values.

Test incident
A stale node number in the test driver's return-to-Basic command invoked the
native Restart… menu action. No reboot occurred: kern.boottime remained
October 4. No restart confirmation was found in the checked app UI. The
incorrect attempt remains in the transition log. The CLI now requires an
expected title/identifier and refuses system lifecycle actions. The original
Calculator mode and expression were restored. No power action was repeated
to test the refusal; its guards were tested with pure offline fixtures.

Offline validation
Run these commands from this directory. They use synthetic fixtures, do not
capture a running app, and do not require Accessibility access:

  ./ax-engine --self-test
  python3 -m unittest -q test_audit.py
  python3 tree_report.py --self-test
  node verify_recovery_ui.js

The Swift launcher compiles Sources/main.swift into .build/ on first use.
The Python tools use the standard library. The JavaScript verifier requires
Node.js and uses built-in modules; no package installation is needed.
verify_cli.py requires existing Calculator and TextEdit captures and can act
on those apps. verify_tree_groups.js expects a saved report with the original
capture-specific counts; verify_recovery_ui.js uses its offline DOM helper
with synthetic data.

Repository contents
Source, tests, the viewer template, and this documentation are versioned.
Local artifacts/, captures/, and exports/ are excluded because native exports
can contain private app text. Historical captures remain on the original Mac
and are not part of a fresh clone. Build products and local credentials are
also excluded. Review native exports before choosing to share them.
