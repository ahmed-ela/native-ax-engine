"""Offline adversarial export checks; never reads or acts on a macOS app."""
import unittest
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from audit import apply_recovery_sidecar, check, recovery_checks


def status(code=0):
    return {"code": code, "attempts": 1, "name": "fixture"}


def fixture():
    root = {"id": 0, "selector_path": [], "first_depth": 0,
            "attribute_names_status": status(), "attribute_names": ["AXRole", "AXChildren"],
            "attributes": {"AXRole": "AXApplication", "AXChildren": [{"type": "AXUIElement", "id": 1}]},
            "attribute_statuses": {"AXRole": status(), "AXChildren": status()},
            "hierarchy": {"AXChildren": [1]}, "hierarchy_child_count": 1,
            "leaf_status": "branch", "hierarchy_leaf": False}
    leaf = {"id": 1, "selector_path": [{"attribute": "AXChildren", "value_path": [0]}], "first_depth": 1,
            "attribute_names_status": status(), "attribute_names": ["AXRole", "AXChildren", "AXParent"],
            "attributes": {"AXRole": "AXButton", "AXChildren": [], "AXParent": {"type": "AXUIElement", "id": 0}},
            "attribute_statuses": {"AXRole": status(), "AXChildren": status(), "AXParent": status()},
            "hierarchy": {"AXChildren": []}, "hierarchy_child_count": 0,
            "leaf_status": "leaf", "hierarchy_leaf": True}
    edges = [{"from": 0, "to": 1, "attribute": "AXChildren", "relationship": "hierarchy", "value_path": [0]},
             {"from": 1, "to": 0, "attribute": "AXParent", "relationship": "reference", "value_path": []}]
    return {"root_id": 0, "node_count": 2, "nodes": [root, leaf], "all_reference_edges": edges,
            "scope": {"hierarchy_attributes": ["AXChildren", "AXRows"]}, "hierarchy_failures": [],
            "metadata_failures": [], "cutoffs": [], "exposed_hierarchy_resolved": True,
            "leaf_ids": [1], "leaf_count": 1, "unknown_leaf_ids": [], "unknown_leaf_count": 0,
            "role_counts": {"AXApplication": 1, "AXButton": 1}, "maximum_depth": 1}


def v2_fixture():
    data = fixture()
    data.update(metadata_classification_version=2, metadata_read_failures=[], serialization_warnings=[],
                native_read_recovery_attempts=0, native_read_recovery_successes=0,
                graph_digest="a" * 64, semantic_graph_digest="b" * 64)
    for node in data["nodes"]:
        node["native_read_recoveries"] = {}
    return data


def recovered_array_fixture(count=0):
    data = v2_fixture()
    node = data["nodes"][1]
    trace = {"method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues",
             "initial_status": status(-25200), "resolved": True,
             "count_before_status": status(), "count_before": count,
             "count_after_status": status(), "count_after": count, "returned_count": count}
    if count:
        trace["pages"] = [{"index": index, "requested": min(256, count - index), "status": status()}
                          for index in range(0, count, 256)]
    node["attribute_names"].append("AXSelectedTextRanges")
    node["attributes"]["AXSelectedTextRanges"] = list(range(count))
    node["native_read_recoveries"]["AXSelectedTextRanges"] = trace
    node["attribute_statuses"]["AXSelectedTextRanges"] = {**status(), "native_read_recovery": deepcopy(trace)}
    data.update(native_read_recovery_attempts=1, native_read_recovery_successes=1)
    return data


def set_trace(data, trace, successful):
    node = data["nodes"][1]
    node["native_read_recoveries"]["AXSelectedTextRanges"] = deepcopy(trace)
    state = {**status(0 if successful else -25200), "native_read_recovery": deepcopy(trace)}
    node["attribute_statuses"]["AXSelectedTextRanges"] = state
    if not successful:
        node["attributes"].pop("AXSelectedTextRanges", None)
        failure = {"node": 1, "attribute": "AXSelectedTextRanges", "stage": "attribute_read", "status": deepcopy(state)}
        data["metadata_failures"] = [failure]
        data["metadata_read_failures"] = [deepcopy(failure)]
    data["native_read_recovery_successes"] = int(successful)


def invalid_fixture():
    data = v2_fixture()
    node = data["nodes"][1]
    node["attribute_statuses"]["AXChildren"] = status(-25202)
    del node["attributes"]["AXChildren"]
    del node["hierarchy"]["AXChildren"]
    node.update(leaf_status="unknown", hierarchy_leaf=None)
    data.update(leaf_ids=[], leaf_count=0, unknown_leaf_ids=[1], unknown_leaf_count=1, exposed_hierarchy_resolved=False,
                hierarchy_failures=[{"node": 1, "attribute": "AXChildren", "stage": "hierarchy_read", "status": status(-25202)}])
    return data


def capture_record(data, attempt):
    invalid = [item for item in data["hierarchy_failures"] if item["status"]["code"] == -25202]
    return {"attempt": attempt, "status": "captured", "identity_continuity": True, "archived": True,
            **{key: data[key] for key in ("graph_digest", "semantic_graph_digest", "node_count", "leaf_count", "unknown_leaf_count", "exposed_hierarchy_resolved")},
            "invalid_reference_count": len({item["node"] for item in invalid}), "invalid_hierarchy_failure_count": len(invalid),
            "hierarchy_failure_count": len(data["hierarchy_failures"]), "metadata_read_failure_count": len(data["metadata_read_failures"]),
            "serialization_warning_count": len(data["serialization_warnings"])}


def add_capture_recovery(data, earlier=(), budget=3):
    records = [capture_record(old, index + 1) for index, old in enumerate(earlier)] + [capture_record(data, len(earlier) + 1)]
    exhausted = bool(records[-1]["invalid_hierarchy_failure_count"])
    data["capture_recovery"] = {"attempts": records, "max_attempts": budget, "attempt_count": len(records),
                                "completed_capture_count": len(records), "archived_capture_count": len(records),
                                "selected_attempt": len(records), "succeeded": True, "budget_exhausted": exhausted,
                                "stop_reason": "capture_attempt_budget_exhausted" if exhausted else "no_retryable_invalid_hierarchy_references"}
    return data


def bulk_trace(name="AXValueDescription", kind="value", item_error=None):
    resolved = kind == "value"
    result = {"method": "AXUIElementCopyMultipleAttributeValues", "query_attributes": [name], "options": 0,
              "query_status": status(), "has_array": True, "returned_slot_count": 1,
              "slot_index": 0, "slot_attribute": name, "item_kind": kind,
              "item_status": {"code": item_error, "name": "fixture"} if item_error is not None else None,
              "item_error_decoded": item_error is not None, "cf_type_id": 7, "resolved": resolved}
    if not resolved:
        result["reason"] = "Native alternate slot returned no recoverable value."
    return result


def set_metadata_trace(data, trace, name="AXValueDescription", value=False):
    node = data["nodes"][1]
    if name not in node["attribute_names"]:
        node["attribute_names"].append(name)
    resolved = trace["resolved"]
    final = {**trace["initial_status"], "native_read_recovery": deepcopy(trace)}
    if resolved:
        final["code"] = 0
        node["attributes"][name] = value
    else:
        node["attributes"].pop(name, None)
    node["attribute_statuses"][name] = final
    node["native_read_recoveries"][name] = deepcopy(trace)
    data.update(native_read_recovery_attempts=1, native_read_recovery_successes=int(resolved))
    failures = [] if resolved else [{"node": 1, "attribute": name, "stage": "attribute_read", "status": deepcopy(final)}]
    data["metadata_read_failures"] = deepcopy(failures)
    data["metadata_failures"] = deepcopy(failures)


def composite_fixture(value=False, code=-25200, query=None, name="AXValueDescription"):
    data = v2_fixture()
    query = deepcopy(query if query is not None else bulk_trace(name))
    trace = {"method": "native_metadata_recovery", "initial_status": status(code), "queries": [query],
             "resolved": query["resolved"], "selected_method": query["method"] if query["resolved"] else None}
    set_metadata_trace(data, trace, name, value)
    return data


def action_fixture(names=None, resolved=True):
    data = v2_fixture()
    names = names if names is not None else []
    trace = {"method": "native_action_names_recovery", "initial_status": status(-25200),
             "query_status": status(0 if resolved else -25200), "has_array": resolved,
             "returned_count": len(names) if resolved else None, "names_valid": resolved,
             "strings_count": len(names) if resolved else None, "resolved": resolved}
    set_action_trace(data, trace, names)
    return data


def set_action_trace(data, trace, names=None):
    node = data["nodes"][1]
    final = {**trace["initial_status"], "native_read_recovery": deepcopy(trace)}
    if trace["resolved"]:
        final["code"] = 0
    node["action_names_status"] = final
    node["action_names"] = list(names or []) if trace["resolved"] else []
    node["native_read_recoveries"] = {"action_names": deepcopy(trace)}
    data.update(native_read_recovery_attempts=1, native_read_recovery_successes=int(trace["resolved"]))
    failures = [] if trace["resolved"] else [{"node": 1, "attribute": "action_names", "stage": "enumeration", "status": deepcopy(final)}]
    data["metadata_read_failures"] = deepcopy(failures)
    data["metadata_failures"] = deepcopy(failures)


def outcome_v2_fixture(data):
    """Upgrade fixture evidence without changing any native result."""
    def kinds(trace):
        trace["resolution_kind"] = "value" if trace["resolved"] else "unresolved"
        for query in trace.get("queries", []):
            kinds(query)
    for node in data["nodes"]:
        for name, trace in node["native_read_recoveries"].items():
            kinds(trace)
            state = node["action_names_status"] if name == "action_names" else node["attribute_statuses"][name]
            state["native_read_recovery"] = deepcopy(trace)
    for record in data["metadata_failures"]:
        node = data["nodes"][record["node"]]
        state = node[record["attribute"] + "_status"] if record["stage"] == "enumeration" else node["attribute_statuses"][record["attribute"]]
        record["status"] = deepcopy(state)
    data["metadata_read_failures"] = deepcopy(data["metadata_failures"])
    data.update(native_read_recovery_outcome_version=2,
                native_read_recovery_value_successes=data["native_read_recovery_successes"],
                native_read_recovery_absence_successes=0, absent_attribute_values=[])
    return data


def absence_fixture():
    name = "AXSelectedTextRanges"
    data = outcome_v2_fixture(composite_fixture(query=bulk_trace(name, "ax_error", -25212), name=name))
    node = data["nodes"][1]
    trace = node["native_read_recoveries"][name]
    query = trace["queries"][0]
    query.update(resolved=True, resolution_kind="absence", item_status={"code": -25212, "name": "noValue"})
    query.pop("reason")
    trace.update(resolved=True, resolution_kind="absence", selected_method=query["method"])
    node["attribute_statuses"][name] = {"code": -25212, "name": "noValue", "attempts": 1,
                                        "native_read_recovery": deepcopy(trace)}
    data.update(native_read_recovery_successes=1, native_read_recovery_absence_successes=1,
                metadata_failures=[], metadata_read_failures=[],
                absent_attribute_values=[{"node": 1, "attribute": name, "status": deepcopy(node["attribute_statuses"][name])}])
    return data


def mutate_absence_trace(data, change):
    trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
    change(trace)
    state = data["nodes"][1]["attribute_statuses"]["AXSelectedTextRanges"]
    state["native_read_recovery"] = deepcopy(trace)
    data["absent_attribute_values"][0]["status"] = deepcopy(state)


def scalar_fixture(name="AXGrowArea", resolution="value", initial_code=-25200, scalar_version=1):
    kind = {"AXGrowArea": "AXUIElement", "AXTopLevelUIElement": "AXUIElement", "AXFrame": "CGRect",
            "AXPosition": "CGPoint", "AXSize": "CGSize"}[name]
    data = outcome_v2_fixture(composite_fixture(query=bulk_trace(name, "ax_error", initial_code), name=name, code=initial_code))
    identity = {"pid": 100, "launch_date": "fixture-launch", "bundle_id": "fixture", "executable_path": "/fixture"}
    data.update(app=identity, process_identities=[identity], scalar_recovery_version=scalar_version)
    data["scope"]["process_traversal_policy"] = "native_references_with_launch_identity"
    for node in data["nodes"]:
        node.update(pid=100, process_identity=deepcopy(identity))
    node = data["nodes"][1]
    trace = node["native_read_recoveries"][name]
    trace["documented_scalar"] = {"attribute": name, "expected_value_kind": kind, "array_query_skipped": True,
                                  "scalar_retry_eligible": initial_code in (-25200, -25204) or scalar_version in (2, 3) and initial_code == -25205}
    if initial_code != -25205 or scalar_version in (2, 3):
        validation = {"expected_value_kind": kind, "expected_cf_type_id": 44 if kind == "AXUIElement" else 79,
                      "has_value": resolution == "value", "cf_type_id": (44 if kind == "AXUIElement" else 79) if resolution == "value" else None,
                      "ax_value_type": {"CGRect": "cgRect", "CGPoint": "cgPoint", "CGSize": "cgSize"}.get(kind) if resolution == "value" else None,
                      "ax_value_decoded": True if resolution == "value" and kind != "AXUIElement" else None,
                      "valid": resolution == "value"}
        refresh = {"attempted": True, "selector_path": deepcopy(node["selector_path"]), "root_pid": 100,
                   "expected_pid": 100, "process_identity_matches": True, "root_same_element": True,
                   "root_timeout_status": status(), "same_element": True, "pid_status": status(), "pid": 100, "resolved": True,
                   "steps": [{"step": 0, "attribute": "AXChildren", "query_status": status(), "has_value": True, "value_path": [0],
                              "path_steps": [{"component_kind": "array_index", "container_cf_type_id": 19, "index": 0,
                                              "selected_has_value": True, "resolved": True}],
                              "selected_cf_type_id": 44, "selected_is_element": True, "same_element": True,
                              "expected_pid": 100, "process_identity_matches": True, "pid_status": status(), "pid": 100, "resolved": True}]}
        scalar = {"method": "native_scalar_recovery", "initial_status": deepcopy(trace["initial_status"]), "attribute": name,
                  "expected_value_kind": kind, "query_method": "AXUIElementCopyAttributeValue", "refresh": refresh,
                  "query_status": {**status(-25212), "name": "noValue"} if resolution == "absence" else status(0 if resolution == "value" else -25200),
                  "query_process_identity_matches": True, "value_validation": validation,
                  "resolved": resolution != "unresolved", "resolution_kind": resolution}
        if resolution == "unresolved":
            scalar["reason"] = "Native scalar query failed."
        if scalar_version == 3:
            scalar.update(query_target="fresh_exact_reference", retained_reference=None, query_retained_reference_validation=None)
        trace["queries"].append(scalar)
        trace.update(resolved=scalar["resolved"], resolution_kind=resolution,
                     selected_method=scalar["method"] if scalar["resolved"] else None)
        if kind == "AXUIElement" and resolution == "value":
            value = {"type": "AXUIElement", "id": 0}
            data["all_reference_edges"].append({"from": 1, "to": 0, "attribute": name, "relationship": "reference", "value_path": []})
        else:
            value = {"type": kind, **({"x": 1, "y": 2} if kind != "CGSize" else {}),
                     **({"width": 3, "height": 4} if kind != "CGPoint" else {})}
        if resolution == "value":
            node["attributes"][name] = value
    sync_scalar_fixture(data, name)
    return data


def sync_scalar_fixture(data, name="AXGrowArea"):
    node = data["nodes"][1]
    trace = node["native_read_recoveries"][name]
    final = {**trace["initial_status"], "native_read_recovery": deepcopy(trace)}
    resolution = trace["resolution_kind"]
    if trace["resolved"]:
        final["code"] = -25212 if resolution == "absence" else 0
        if resolution == "absence":
            final["name"] = "noValue"
    if resolution != "value":
        node["attributes"].pop(name, None)
    node["attribute_statuses"][name] = final
    failures = [] if trace["resolved"] else [{"node": 1, "attribute": name, "stage": "attribute_read", "status": deepcopy(final)}]
    data.update(metadata_failures=deepcopy(failures), metadata_read_failures=deepcopy(failures),
                native_read_recovery_successes=int(trace["resolved"]),
                native_read_recovery_value_successes=int(trace["resolved"] and resolution == "value"),
                native_read_recovery_absence_successes=int(trace["resolved"] and resolution == "absence"),
                absent_attribute_values=[{"node": 1, "attribute": name, "status": deepcopy(final)}] if trace["resolved"] and resolution == "absence" else [],
                native_metadata_failure_summary={"attribute_unsupported": int(bool(failures) and final["code"] == -25205),
                                                 "other_read_failures": int(bool(failures) and final["code"] != -25205)})
    if data.get("scalar_recovery_version") == 3:
        queries = [query for query in trace["queries"] if query.get("method") == "native_scalar_recovery"]
        retained = [query for query in queries if query.get("query_target") == "retained_original_reference"]
        data.update(native_scalar_retained_reference_attempts=len(retained),
                    native_scalar_retained_reference_withheld=sum(query.get("retained_reference") is not None and
                        query.get("query_target") is None for query in queries),
                    native_scalar_retained_reference_value_successes=sum(query.get("resolved") is True and
                        query.get("resolution_kind") == "value" for query in retained),
                    native_scalar_retained_reference_absence_successes=sum(query.get("resolved") is True and
                        query.get("resolution_kind") == "absence" for query in retained))


def retained_scalar_fixture(resolution="value", role="AXMenu"):
    name = "AXTopLevelUIElement"
    data = scalar_fixture(name, resolution, initial_code=-25205, scalar_version=3)
    node = data["nodes"][1]
    node["attributes"]["AXRole"] = role
    data["role_counts"] = {"AXApplication": 1, role: 1}
    scalar = node["native_read_recoveries"][name]["queries"][1]
    scalar["refresh"]["steps"][0].update(same_element=False, resolved=False)
    scalar["refresh"].update(same_element=False, resolved=False, pid_status=None, pid=None,
                              reason="Fresh native prefix is not CFEqual to the recorded native prefix.")
    proof = {"attempted": True, "source": "capture_registry", "node_id": 1, "root_id": 0, "root_pid": 100,
             "expected_pid": 100, "owner_role": role, "owner_role_status": deepcopy(node["attribute_statuses"]["AXRole"]),
             "expected_cf_type_id": 44, "owner_cf_type_id": 44, "registry_binding_matches": True,
             "root_pid_status": status(), "root_native_pid": 100, "owner_pid_status": status(), "owner_native_pid": 100,
             "root_process_identity_matches": True, "owner_process_identity_matches": True, "resolved": True}
    scalar.update(query_target="retained_original_reference", retained_reference=deepcopy(proof),
                  query_retained_reference_validation=deepcopy(proof))
    sync_scalar_fixture(data, name)
    return data


class AuditTests(unittest.TestCase):
    def test_parent_cycle_is_valid(self):
        self.assertTrue(check(fixture())["passed"])

    def test_shared_relationship_does_not_duplicate_nodes(self):
        data = fixture()
        root = data["nodes"][0]
        root["attribute_names"].append("AXRows")
        root["attributes"]["AXRows"] = [{"type": "AXUIElement", "id": 1}]
        root["attribute_statuses"]["AXRows"] = status()
        root["hierarchy"]["AXRows"] = [1]
        data["all_reference_edges"].append({"from": 0, "to": 1, "attribute": "AXRows", "relationship": "hierarchy", "value_path": [0]})
        self.assertTrue(check(data)["passed"])

    def test_empty_children_after_read_failure_is_not_leaf(self):
        data = fixture()
        data["nodes"][1]["attribute_statuses"]["AXChildren"] = status(-25200)
        self.assertFalse(check(data)["passed"])

    def test_failed_supplemental_hierarchy_is_not_leaf(self):
        data = fixture()
        node = data["nodes"][1]
        node["attribute_names"].append("AXRows")
        node["attribute_statuses"]["AXRows"] = status(-25202)
        self.assertFalse(check(data)["passed"])

    def test_native_no_value_is_known_absence(self):
        data = fixture()
        node = data["nodes"][1]
        del node["attributes"]["AXChildren"]
        del node["hierarchy"]["AXChildren"]
        node["attribute_statuses"]["AXChildren"] = status(-25212)
        self.assertTrue(check(data)["passed"])

    def test_success_with_nil_cannot_confirm_leaf(self):
        data = fixture()
        del data["nodes"][1]["attributes"]["AXChildren"]
        self.assertFalse(check(data)["passed"])

    def test_failed_hierarchy_cannot_claim_complete_even_with_unknown_leaf(self):
        data = fixture()
        node = data["nodes"][1]
        node["attribute_statuses"]["AXChildren"] = status(-25200)
        del node["attributes"]["AXChildren"]
        del node["hierarchy"]["AXChildren"]
        node["leaf_status"], node["hierarchy_leaf"] = "unknown", None
        data.update(leaf_ids=[], leaf_count=0, unknown_leaf_ids=[1], unknown_leaf_count=1)
        self.assertFalse(check(data)["passed"])

    def test_unresolved_reference_requires_cutoff_record(self):
        data = fixture()
        node = data["nodes"][1]
        node["attributes"]["AXParent"]["id"] = None
        data["all_reference_edges"][1]["to"] = None
        self.assertFalse(check(data)["passed"])

    def test_missing_reference_target_is_rejected(self):
        data = fixture()
        data["all_reference_edges"][0]["to"] = 99
        self.assertFalse(check(data)["passed"])

    def test_invalid_selector_is_rejected(self):
        data = fixture()
        data["nodes"][1]["selector_path"][0]["value_path"] = [99]
        self.assertFalse(check(data)["passed"])

    def test_unattempted_attribute_is_rejected(self):
        data = fixture()
        data["nodes"][1]["attribute_names"].append("AXValue")
        self.assertFalse(check(data)["passed"])

    def test_primary_process_registry_cannot_change_app_identity(self):
        data = fixture()
        primary = {"pid": 100, "bundle_id": "fixture.primary", "executable_path": "/fixture"}
        wrong = {"pid": 100, "bundle_id": "fixture.other", "executable_path": "/other"}
        data["app"] = primary
        data["process_identities"] = [wrong]
        for node in data["nodes"]:
            node.update(pid=100, process_identity=wrong)
        self.assertFalse(check(data)["passed"])

    def test_metadata_v2_empty_partition_and_legacy_export(self):
        self.assertTrue(check(v2_fixture())["passed"])
        self.assertTrue(check(fixture())["passed"])
        data = v2_fixture()
        data["metadata_read_failures"] = None
        self.assertFalse(check(data)["passed"])

    def test_metadata_v2_warning_is_successfully_read_serialization(self):
        data = v2_fixture()
        warning = {"node": 1, "attribute": "AXRole", "stage": "serialization", "status": {"code": 0}, "reason": "Opaque native fixture"}
        data["metadata_failures"] = [warning]
        data["serialization_warnings"] = [deepcopy(warning)]
        self.assertTrue(check(data)["passed"])
        data["serialization_warnings"][0]["status"]["code"] = -25200
        self.assertFalse(check(data)["passed"])

    def test_metadata_read_cannot_be_recategorized_as_serialization(self):
        data = recovered_array_fixture()
        trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
        trace = {key: value for key, value in trace.items() if key not in {"count_after", "count_after_status", "returned_count", "count_before"}}
        trace.update(resolved=False, count_before_status=status(-25200), reason="Native array count could not be read.")
        set_trace(data, trace, False)
        self.assertTrue(check(data)["passed"])
        data["serialization_warnings"] = data["metadata_read_failures"]
        data["metadata_read_failures"] = []
        self.assertFalse(check(data)["passed"])

    def test_native_recovery_confirms_real_empty_array_and_pages(self):
        self.assertTrue(check(recovered_array_fixture())["passed"])
        self.assertTrue(check(recovered_array_fixture(600))["passed"])

    def test_native_failed_count_preserves_error_without_empty_value(self):
        data = recovered_array_fixture()
        trace = {"method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues", "initial_status": status(-25200),
                 "resolved": False, "count_before_status": status(-25200), "reason": "Native array count could not be read."}
        set_trace(data, trace, False)
        self.assertTrue(check(data)["passed"])
        data["nodes"][1]["attributes"]["AXSelectedTextRanges"] = []
        self.assertFalse(check(data)["passed"])

    def test_native_failed_page_and_short_page_keep_original_error(self):
        for code in (0, -25204):
            with self.subTest(code=code):
                data = recovered_array_fixture(2)
                trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
                trace = {key: value for key, value in trace.items() if key not in {"count_after", "count_after_status", "returned_count"}}
                trace.update(resolved=False, reason="Native array page failed or its length changed during reading.")
                trace["pages"][-1]["status"] = status(code)
                set_trace(data, trace, False)
                self.assertTrue(check(data)["passed"])

    def test_native_count_instability_cannot_confirm_empty_array(self):
        data = recovered_array_fixture()
        trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
        trace = {key: value for key, value in trace.items() if key != "returned_count"}
        trace.update(resolved=False, count_after=1, reason="Native array count changed or could not be confirmed after reading.")
        set_trace(data, trace, False)
        self.assertTrue(check(data)["passed"])
        trace.update(resolved=True, returned_count=0)
        trace.pop("reason")
        set_trace(data, trace, True)
        data["nodes"][1]["attributes"]["AXSelectedTextRanges"] = []
        data["metadata_failures"] = data["metadata_read_failures"] = []
        self.assertFalse(check(data)["passed"])

    def test_forged_native_recovery_missing_count_after_is_rejected(self):
        data = recovered_array_fixture()
        trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
        del trace["count_after_status"]
        set_trace(data, trace, True)
        self.assertFalse(check(data)["passed"])

    def test_forged_native_recovery_page_holes_and_failed_page_are_rejected(self):
        for modification in (lambda trace: trace["pages"][1].update(index=257),
                             lambda trace: trace["pages"][0].update(status=status(-25204)),
                             lambda trace: trace.update(returned_count=599)):
            data = recovered_array_fixture(600)
            trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
            modification(trace)
            set_trace(data, trace, True)
            self.assertFalse(check(data)["passed"])

    def test_native_trace_copies_and_summary_counts_must_agree(self):
        data = recovered_array_fixture()
        data["nodes"][1]["attribute_statuses"]["AXSelectedTextRanges"]["native_read_recovery"]["count_after"] = 1
        self.assertFalse(check(data)["passed"])
        data = recovered_array_fixture()
        data["native_read_recovery_attempts"] = 2
        self.assertFalse(check(data)["passed"])

    def test_page_length_evidence_confirms_only_real_complete_pages(self):
        data = recovered_array_fixture(600)
        trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
        for page in trace["pages"]:
            page.update(has_value=True, returned_count=page["requested"])
        set_trace(data, trace, True)
        self.assertTrue(check(data)["passed"])
        trace["pages"][-1]["returned_count"] -= 1
        set_trace(data, trace, True)
        self.assertFalse(check(data)["passed"])

    def test_page_length_failure_evidence_cannot_claim_complete_success(self):
        data = recovered_array_fixture(2)
        trace = data["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"]
        trace = {key: value for key, value in trace.items() if key not in {"count_after", "count_after_status", "returned_count"}}
        trace.update(resolved=False, reason="Native array page failed or its length changed during reading.")
        trace["pages"][-1].update(has_value=True, returned_count=1)
        set_trace(data, trace, False)
        self.assertTrue(check(data)["passed"])
        trace["pages"][-1].update(returned_count=2)
        set_trace(data, trace, False)
        self.assertFalse(check(data)["passed"])

    def test_capture_recovery_selects_latest_fresh_capture(self):
        old = invalid_fixture()
        old["graph_digest"] = "c" * 64
        self.assertTrue(check(add_capture_recovery(v2_fixture(), [old]))["passed"])
        self.assertTrue(check(add_capture_recovery(invalid_fixture(), [old, old]))["passed"])
        self.assertTrue(check(add_capture_recovery(v2_fixture()))["passed"])

    def test_capture_recovery_cannot_select_earlier_less_bad_snapshot(self):
        data = add_capture_recovery(invalid_fixture(), [invalid_fixture(), invalid_fixture()])
        data["capture_recovery"]["selected_attempt"] = 1
        self.assertFalse(check(data)["passed"])
        data = add_capture_recovery(v2_fixture(), [invalid_fixture()])
        data["capture_recovery"]["attempts"][-1]["graph_digest"] = "c" * 64
        self.assertFalse(check(data)["passed"])

    def test_capture_recovery_retry_requires_invalid_hierarchy_trigger(self):
        self.assertFalse(check(add_capture_recovery(v2_fixture(), [v2_fixture()]))["passed"])

    def test_capture_recovery_failed_attempt_cannot_publish_old_snapshot(self):
        data = add_capture_recovery(v2_fixture(), [invalid_fixture()])
        data["capture_recovery"]["attempts"][-1].update(status="capture_failed", archived=False)
        self.assertFalse(check(data)["passed"])

    def test_capture_recovery_bounded_and_summaries_agree(self):
        for modification in (lambda recovery: recovery.update(max_attempts=4),
                             lambda recovery: recovery.update(archived_capture_count=0),
                             lambda recovery: recovery["attempts"][-1].update(invalid_reference_count=1),
                             lambda recovery: recovery.update(stop_reason="capture_attempt_budget_exhausted", budget_exhausted=True)):
            data = add_capture_recovery(v2_fixture())
            modification(data["capture_recovery"])
            self.assertFalse(check(data)["passed"])

    def test_failed_sidecar_retains_historically_valid_graph_without_current_success(self):
        data = v2_fixture()
        data["app"] = {"pid": 100}
        sidecar = {"app_identity": data["app"], "latest_snapshot_published": False, "failed_observation": 1,
                   "capture_recovery_observations": [{"observation": 1, "succeeded": False, "selected_attempt": None}]}
        result = apply_recovery_sidecar(data, check(data), sidecar)
        self.assertTrue(result["historically_valid_graph"])
        self.assertTrue(result["latest_capture_failed"])
        self.assertFalse(result["latest_capture_available"])
        self.assertFalse(result["passed"])

    def test_cli_failed_latest_capture_exits_without_rewriting_raw_snapshot(self):
        data = v2_fixture()
        data["app"] = {"pid": 100}
        sidecar = {"app_identity": data["app"], "latest_snapshot_published": False, "failed_observation": 1,
                   "capture_recovery_observations": [{"observation": 1, "succeeded": False, "selected_attempt": None}]}
        with TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot_path = root / "snapshot.json"
            raw = json.dumps(data)
            snapshot_path.write_text(raw)
            (root / "capture-recovery.json").write_text(json.dumps(sidecar))
            process = subprocess.run([sys.executable, str(Path(__file__).with_name("audit.py")), str(root)],
                                     capture_output=True, text=True)
            self.assertEqual(process.returncode, 1, process.stderr)
            result = json.loads(process.stdout)
            self.assertFalse(result["passed"])
            self.assertFalse(result["latest_capture_available"])
            self.assertTrue(result["snapshots"][0]["historically_valid_graph"])
            self.assertTrue(result["snapshots"][0]["latest_capture_failed"])
            self.assertEqual(snapshot_path.read_text(), raw)

    def test_published_sidecar_must_match_latest_snapshot_recovery(self):
        data = add_capture_recovery(v2_fixture())
        data["app"] = {"pid": 100}
        sidecar = {"app_identity": data["app"], "latest_snapshot_published": True,
                   "capture_recovery_observations": [{**deepcopy(data["capture_recovery"]), "observation": 1}]}
        self.assertTrue(apply_recovery_sidecar(data, check(data), sidecar)["passed"])
        sidecar["capture_recovery_observations"][-1]["selected_attempt"] = 2
        self.assertFalse(apply_recovery_sidecar(data, check(data), sidecar)["passed"])

    def test_audit_summary_separates_metadata_reads_and_serialization(self):
        data = fixture()
        data["metadata_failures"] = [{"stage": "attribute_read"}, {"stage": "serialization"}]
        result = check(data)
        self.assertEqual((result["metadata_failures"], result["metadata_read_failures"], result["serialization_warnings"]), (2, 1, 1))

    def test_native_reference_policy_accepts_actual_external_ingress(self):
        data = fixture()
        data["scope"]["process_traversal_policy"] = "native_references_with_launch_identity"
        primary = {"pid": 100, "bundle_id": "fixture.primary", "executable_path": "/fixture", "launch_date": "fixture-launch"}
        external = {"pid": 101, "bundle_id": "fixture.external", "executable_path": "/external", "launch_date": "fixture-launch"}
        data["app"] = primary
        data["process_identities"] = [primary, external]
        data["nodes"][0].update(pid=100, process_identity=deepcopy(primary))
        data["nodes"][1].update(pid=101, process_identity=deepcopy(external))
        self.assertTrue(check(data)["passed"])
        data["process_identities"].append({"pid": 102, "launch_date": "fixture-launch"})
        self.assertFalse(check(data)["passed"])

    def test_legacy_external_policy_still_requires_exact_helper(self):
        data = fixture()
        primary = {"pid": 100, "bundle_id": "fixture.primary", "executable_path": "/fixture"}
        external = {"pid": 101, "bundle_id": "fixture.external", "executable_path": "/external"}
        data["app"] = primary
        data["process_identities"] = [primary, external]
        data["nodes"][0].update(pid=100, process_identity=deepcopy(primary))
        data["nodes"][1].update(pid=101, process_identity=deepcopy(external))
        self.assertFalse(check(data)["passed"])
        data["scope"]["allowlisted_helper_executable"] = "/external"
        self.assertTrue(check(data)["passed"])

    def test_bulk_alternate_preserves_genuine_false_zero_and_empty_native_values(self):
        for value in (False, 0, "", [], {"type": "opaque_native", "cf_type_id": 7}):
            with self.subTest(value=value):
                self.assertTrue(check(composite_fixture(value))["passed"])

    def test_bulk_null_and_error_slots_never_become_empty_or_absent_success(self):
        for kind, error in (("null", None), ("ax_error", -25200), ("ax_error", -25205),
                            ("ax_error", -25212), ("ax_error", -25202), ("ax_error", 0), ("ax_error", None)):
            with self.subTest(kind=kind, error=error):
                query = bulk_trace(kind=kind, item_error=error)
                data = composite_fixture(query=query)
                self.assertTrue(check(data)["passed"])
                trace = data["nodes"][1]["native_read_recoveries"]["AXValueDescription"]
                trace.update(resolved=True, selected_method=query["method"])
                set_metadata_trace(data, trace, value=[])
                self.assertFalse(check(data)["passed"])

    def test_bulk_outer_failure_and_malformed_cardinality_remain_native_errors(self):
        for patch in ({"query_status": status(-25200), "has_array": False, "returned_slot_count": None},
                      {"query_status": status(), "has_array": False, "returned_slot_count": None},
                      {"returned_slot_count": 0}, {"returned_slot_count": 2}):
            query = bulk_trace(kind="malformed")
            query.update(cf_type_id=None, **patch)
            data = composite_fixture(query=query)
            self.assertTrue(check(data)["passed"])
            trace = data["nodes"][1]["native_read_recoveries"]["AXValueDescription"]
            trace.update(resolved=True, selected_method=query["method"])
            set_metadata_trace(data, trace, value="fabricated")
            self.assertFalse(check(data)["passed"])

    def test_bulk_batched_index_maps_to_exact_requested_attribute(self):
        query = bulk_trace()
        query.update(query_attributes=["AXHelp", "AXValueDescription"], returned_slot_count=2, slot_index=1)
        self.assertTrue(check(composite_fixture(query=query))["passed"])
        for patch in ({"slot_index": 0}, {"slot_attribute": "AXHelp"}, {"query_attributes": ["AXValueDescription", "AXValueDescription"]},
                      {"query_attributes": []}, {"slot_index": -1}):
            bad = deepcopy(query); bad.update(patch)
            self.assertFalse(check(composite_fixture(query=bad))["passed"])

    def test_bulk_options_attempts_and_native_type_evidence_are_checked(self):
        for patch in ({"options": 1}, {"options": False}, {"query_status": {**status(), "attempts": 2}},
                      {"cf_type_id": None}, {"item_error_decoded": True}, {"has_array": False}, {"returned_slot_count": None}):
            query = bulk_trace(); query.update(patch)
            self.assertFalse(check(composite_fixture(query=query))["passed"])

    def test_composite_selected_method_and_final_status_cannot_be_forged(self):
        for patch in ({"selected_method": None}, {"selected_method": "array"}, {"resolved": False}):
            data = composite_fixture()
            trace = data["nodes"][1]["native_read_recoveries"]["AXValueDescription"]
            trace.update(patch)
            set_metadata_trace(data, trace)
            self.assertFalse(check(data)["passed"])
        data = composite_fixture(query=bulk_trace(kind="null"))
        data["nodes"][1]["attribute_statuses"]["AXValueDescription"]["code"] = -25212
        self.assertFalse(check(data)["passed"])

    def test_generalized_array_recovery_preserves_original_unsupported_metadata(self):
        data = recovered_array_fixture()
        node = data["nodes"][1]
        trace = deepcopy(node["native_read_recoveries"]["AXSelectedTextRanges"])
        node["attribute_names"].remove("AXSelectedTextRanges")
        node["attributes"].pop("AXSelectedTextRanges")
        node["attribute_statuses"].pop("AXSelectedTextRanges")
        node["native_read_recoveries"].clear()
        trace["initial_status"] = status(-25205)
        set_metadata_trace(data, trace, "AXAllowedValues", [])
        self.assertTrue(check(data)["passed"])

    def test_bulk_error_followed_by_real_array_count_zero_is_valid(self):
        array = deepcopy(recovered_array_fixture()["nodes"][1]["native_read_recoveries"]["AXSelectedTextRanges"])
        data = composite_fixture(query=bulk_trace(kind="null"), name="AXAllowedValues")
        trace = data["nodes"][1]["native_read_recoveries"]["AXAllowedValues"]
        # Bind the failed batch query to the same advertised array name.
        trace["queries"][0]["query_attributes"] = ["AXAllowedValues"]
        trace["queries"][0]["slot_attribute"] = "AXAllowedValues"
        trace["queries"].append(array)
        trace.update(resolved=True, selected_method=array["method"])
        set_metadata_trace(data, trace, "AXAllowedValues", [])
        self.assertTrue(check(data)["passed"])
        trace["queries"][1]["count_after"] = 1
        set_metadata_trace(data, trace, "AXAllowedValues", [])
        self.assertFalse(check(data)["passed"])

    def test_composite_array_failure_retains_original_and_must_not_retry_after_success(self):
        array = {"method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues", "initial_status": status(-25200),
                 "resolved": False, "count_before_status": status(-25201), "reason": "Native array count could not be read."}
        data = composite_fixture(query=bulk_trace(kind="null"))
        trace = data["nodes"][1]["native_read_recoveries"]["AXValueDescription"]
        trace["queries"].append(array)
        set_metadata_trace(data, trace)
        self.assertTrue(check(data)["passed"])
        trace["queries"][0] = bulk_trace()
        set_metadata_trace(data, trace)
        self.assertFalse(check(data)["passed"])

    def test_hierarchy_attributes_cannot_use_metadata_recovery_to_hide_failures(self):
        data = composite_fixture(name="AXRows", value=[])
        self.assertFalse(check(data)["passed"])

    def test_bulk_recovered_native_reference_is_recorded_in_graph(self):
        data = composite_fixture(name="AXLinkedUIElements", value=[{"type": "AXUIElement", "id": 0}])
        data["all_reference_edges"].append({"from": 1, "to": 0, "attribute": "AXLinkedUIElements", "relationship": "reference", "value_path": [0]})
        self.assertTrue(check(data)["passed"])
        data["all_reference_edges"].pop()
        self.assertFalse(check(data)["passed"])

    def test_action_alternate_native_success_including_real_empty_names(self):
        self.assertTrue(check(action_fixture([]))["passed"])
        self.assertTrue(check(action_fixture(["AXPress", "AXShowMenu"]))["passed"])
        self.assertTrue(check(action_fixture(resolved=False))["passed"])

    def test_action_malformed_native_names_array_is_not_success_or_empty_absence(self):
        data = action_fixture(resolved=False)
        trace = data["nodes"][1]["native_read_recoveries"]["action_names"]
        trace.update(query_status=status(), has_array=True, returned_count=2, names_valid=False, strings_count=1)
        set_action_trace(data, trace)
        self.assertTrue(check(data)["passed"])
        trace["resolved"] = True
        set_action_trace(data, trace)
        self.assertFalse(check(data)["passed"])

    def test_action_error_with_returned_strings_keeps_status_failed_and_names_unadvertised(self):
        data = action_fixture(resolved=False)
        trace = data["nodes"][1]["native_read_recoveries"]["action_names"]
        trace.update(has_array=True, returned_count=1, names_valid=True, strings_count=1)
        set_action_trace(data, trace)
        self.assertTrue(check(data)["passed"])
        data["nodes"][1]["action_names"] = ["AXPress"]
        self.assertFalse(check(data)["passed"])

    def test_action_query_requires_one_call_original_failure_and_actual_strings(self):
        for patch in ({"query_status": {**status(), "attempts": 2}}, {"returned_count": 1}, {"strings_count": 1},
                      {"has_array": False}, {"names_valid": False}, {"initial_status": status(-25204)}):
            data = action_fixture([])
            trace = data["nodes"][1]["native_read_recoveries"]["action_names"]
            trace.update(patch)
            set_action_trace(data, trace)
            self.assertFalse(check(data)["passed"])
        data = action_fixture(["AXPress"])
        data["nodes"][1]["action_names"] = [0]
        self.assertFalse(check(data)["passed"])

    def test_action_status_trace_map_and_metadata_evidence_must_agree(self):
        data = action_fixture(resolved=False)
        data["nodes"][1]["action_names_status"]["native_read_recovery"]["resolved"] = True
        self.assertFalse(check(data)["passed"])
        data = action_fixture(resolved=False)
        data["metadata_failures"] = data["metadata_read_failures"] = []
        self.assertFalse(check(data)["passed"])

    def test_decoded_bulk_no_value_confirms_absence_without_array_or_content(self):
        data = absence_fixture()
        result = check(data)
        self.assertTrue(result["passed"], result["errors"])
        self.assertEqual((result["native_read_recovery_successes"], result["native_read_recovery_value_successes"],
                          result["native_read_recovery_absence_successes"]), (1, 0, 1))
        self.assertNotIn("AXSelectedTextRanges", data["nodes"][1]["attributes"])

    def test_absence_requires_exact_native_slot_and_successful_outer_query(self):
        for patch in ({"query_status": status(-25200)}, {"returned_slot_count": 0}, {"returned_slot_count": 2},
                      {"slot_index": 1}, {"slot_attribute": "AXHelp"}, {"query_attributes": ["AXHelp"]},
                      {"has_array": False}, {"options": 1}, {"cf_type_id": None}):
            with self.subTest(patch=patch):
                data = absence_fixture()
                mutate_absence_trace(data, lambda trace: trace["queries"][0].update(patch))
                self.assertFalse(check(data)["passed"])

    def test_absence_requires_decoded_no_value_not_null_unsupported_or_error_zero(self):
        for patch in ({"item_kind": "null", "item_status": None, "item_error_decoded": False},
                      {"item_status": {"code": -25205, "name": "attributeUnsupported"}},
                      {"item_status": {"code": 0, "name": "success"}},
                      {"item_status": {"code": -25212, "name": "failure"}},
                      {"item_status": None, "item_error_decoded": False}):
            with self.subTest(patch=patch):
                data = absence_fixture()
                mutate_absence_trace(data, lambda trace: trace["queries"][0].update(patch))
                self.assertFalse(check(data)["passed"])

    def test_absence_final_status_requires_no_value_code_and_label(self):
        for patch in ({"code": 0, "name": "success"}, {"code": -25200, "name": "failure"},
                      {"name": "failure"}, {"attempts": 2}):
            data = absence_fixture()
            state = data["nodes"][1]["attribute_statuses"]["AXSelectedTextRanges"]
            state.update(patch)
            data["absent_attribute_values"][0]["status"] = deepcopy(state)
            self.assertFalse(check(data)["passed"])

    def test_absence_cannot_fabricate_null_empty_or_selected_contents(self):
        for value in (None, [], "", [0], False):
            data = absence_fixture()
            data["nodes"][1]["attributes"]["AXSelectedTextRanges"] = value
            self.assertFalse(check(data)["passed"])

    def test_absence_record_must_match_final_status_and_exact_owner(self):
        for patch in ({"node": 0}, {"node": 99}, {"attribute": "AXHelp"}, {"status": status(-25212)},
                      {"status": {"code": -25212, "name": "noValue", "attempts": 1}}):
            data = absence_fixture()
            data["absent_attribute_values"][0].update(patch)
            self.assertFalse(check(data)["passed"])
        data = absence_fixture(); data["absent_attribute_values"] = []
        self.assertFalse(check(data)["passed"])
        data = absence_fixture(); data["absent_attribute_values"] *= 2
        self.assertFalse(check(data)["passed"])

    def test_absence_is_not_a_final_metadata_failure(self):
        data = absence_fixture()
        failure = {"node": 1, "attribute": "AXSelectedTextRanges", "stage": "attribute_read",
                   "status": deepcopy(data["nodes"][1]["attribute_statuses"]["AXSelectedTextRanges"])}
        data["metadata_failures"] = [failure]
        data["metadata_read_failures"] = [deepcopy(failure)]
        self.assertFalse(check(data)["passed"])

    def test_absence_is_terminal_and_does_not_continue_to_array_fallback(self):
        data = absence_fixture()
        mutate_absence_trace(data, lambda trace: trace["queries"].append({
            "method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues", "initial_status": status(-25200),
            "resolved": False, "resolution_kind": "unresolved", "count_before_status": status(-25200),
            "reason": "Native array count could not be read."}))
        self.assertFalse(check(data)["passed"])

    def test_absence_composite_and_query_kinds_and_selected_method_must_agree(self):
        for change in (lambda trace: trace.update(resolution_kind="value"),
                       lambda trace: trace.update(resolved=False),
                       lambda trace: trace.update(selected_method=None),
                       lambda trace: trace["queries"][0].update(resolution_kind="unresolved"),
                       lambda trace: trace["queries"][0].update(resolved=False)):
            data = absence_fixture(); mutate_absence_trace(data, change)
            self.assertFalse(check(data)["passed"])

    def test_outcome_v2_preserves_real_native_values_and_non_absence_failures(self):
        for value in (False, 0, "", [], {"type": "opaque_native", "cf_type_id": 7}):
            data = outcome_v2_fixture(composite_fixture(value))
            result = check(data)
            self.assertTrue(result["passed"], result["errors"])
            self.assertEqual((result["native_read_recovery_value_successes"], result["native_read_recovery_absence_successes"]), (1, 0))
        for kind, error in (("null", None), ("ax_error", -25205), ("ax_error", 0), ("ax_error", None)):
            self.assertTrue(check(outcome_v2_fixture(composite_fixture(query=bulk_trace(kind=kind, item_error=error))))["passed"])

    def test_outcome_v2_array_and_action_can_resolve_only_values(self):
        for data in (recovered_array_fixture(), recovered_array_fixture(600), action_fixture([]), action_fixture(resolved=False)):
            data = outcome_v2_fixture(data)
            self.assertTrue(check(data)["passed"])
            node = data["nodes"][1]
            name, trace = next(iter(node["native_read_recoveries"].items()))
            trace["resolution_kind"] = "absence"
            state = node["action_names_status"] if name == "action_names" else node["attribute_statuses"][name]
            state["native_read_recovery"] = deepcopy(trace)
            self.assertFalse(check(data)["passed"])

    def test_outcome_v2_requires_kinds_version_and_split_counter_concordance(self):
        for patch in ({"native_read_recovery_value_successes": 1}, {"native_read_recovery_absence_successes": 0},
                      {"native_read_recovery_successes": 0}, {"native_read_recovery_absence_successes": True},
                      {"native_read_recovery_outcome_version": 1}, {"native_read_recovery_outcome_version": True}):
            data = absence_fixture(); data.update(patch)
            self.assertFalse(check(data)["passed"])
        for key in ("native_read_recovery_outcome_version", "native_read_recovery_absence_successes",
                    "native_read_recovery_value_successes", "absent_attribute_values"):
            data = absence_fixture(); del data[key]
            self.assertFalse(check(data)["passed"])
        data = absence_fixture()
        mutate_absence_trace(data, lambda trace: trace.pop("resolution_kind"))
        self.assertFalse(check(data)["passed"])

    def test_legacy_no_value_envelope_remains_unresolved_without_silent_upgrade(self):
        data = composite_fixture(query=bulk_trace(kind="ax_error", item_error=-25212))
        self.assertTrue(check(data)["passed"])
        trace = data["nodes"][1]["native_read_recoveries"]["AXValueDescription"]
        trace.update(resolved=True, selected_method=trace["queries"][0]["method"])
        trace["queries"][0]["resolved"] = True
        set_metadata_trace(data, trace, value=[])
        self.assertFalse(check(data)["passed"])

    def test_outcome_v2_zero_recovery_and_direct_absence_records(self):
        data = outcome_v2_fixture(v2_fixture())
        self.assertTrue(check(data)["passed"])
        node = data["nodes"][1]
        name = "AXHelp"
        node["attribute_names"].append(name)
        node["attribute_statuses"][name] = {"code": -25212, "name": "noValue", "attempts": 1}
        data["absent_attribute_values"] = [{"node": 1, "attribute": name, "status": deepcopy(node["attribute_statuses"][name])}]
        self.assertTrue(check(data)["passed"])
        data["absent_attribute_values"] = []
        self.assertFalse(check(data)["passed"])

    def test_fresh_scalar_typed_references_geometry_and_native_absence(self):
        for name in ("AXGrowArea", "AXTopLevelUIElement", "AXFrame", "AXPosition", "AXSize"):
            for resolution in ("value", "absence", "unresolved"):
                with self.subTest(name=name, resolution=resolution):
                    result = check(scalar_fixture(name, resolution))
                    self.assertTrue(result["passed"], result["errors"])

    def test_documented_unsupported_scalar_uses_bulk_only_and_keeps_error(self):
        data = scalar_fixture(initial_code=-25205)
        self.assertTrue(check(data)["passed"])
        self.assertEqual(data["native_metadata_failure_summary"], {"attribute_unsupported": 1, "other_read_failures": 0})
        other = scalar_fixture()
        data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"].append(
            deepcopy(other["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]))
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_fresh_scalar_root_owner_path_and_equality_are_required(self):
        for patch in ({"root_pid": 101}, {"expected_pid": 101}, {"selector_path": []}, {"root_same_element": False},
                      {"process_identity_matches": False}, {"same_element": False}, {"pid": 101}, {"pid_status": status(-25200)},
                      {"root_timeout_status": status(-25200)}, {"steps": []}):
            data = scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["refresh"].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_fresh_scalar_prefix_must_match_exact_native_saved_reference(self):
        for patch in ({"step": 1}, {"attribute": "AXRows"}, {"value_path": [1]}, {"has_value": False},
                      {"query_status": status(-25200)}, {"same_element": False}, {"selected_is_element": False},
                      {"selected_cf_type_id": None}, {"expected_pid": 101}, {"pid": 101}, {"resolved": False}):
            data = scalar_fixture()
            step = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["refresh"]["steps"][0]
            step.update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_fresh_scalar_native_component_and_one_call_evidence_are_required(self):
        for patch in ({"index": 1}, {"selected_has_value": False}, {"resolved": False}, {"component_kind": "unsupported"},
                      {"container_cf_type_id": None}):
            data = scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["refresh"]["steps"][0]["path_steps"][0].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])
        for field in ("query_status", "pid_status", "root_timeout_status"):
            data = scalar_fixture()
            scalar = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]
            state = scalar[field] if field == "query_status" else scalar["refresh"][field]
            state["attempts"] = 2
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_failed_scalar_refresh_is_unresolved_and_issues_no_query(self):
        data = scalar_fixture(resolution="unresolved")
        scalar = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]
        scalar["refresh"].update(root_same_element=False, root_timeout_status=None, steps=[], same_element=False,
                                 pid_status=None, pid=None, resolved=False, reason="Fresh root differs from the saved native root.")
        scalar.update(query_status=None, value_validation=None, query_process_identity_matches=None)
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        scalar["query_status"] = status()
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_post_query_process_change_blocks_scalar_value_and_absence(self):
        for resolution in ("value", "absence"):
            data = scalar_fixture(resolution=resolution)
            trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
            scalar = trace["queries"][1]
            scalar["query_process_identity_matches"] = False
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])
            scalar.update(resolved=False, resolution_kind="unresolved", reason="Owner changed after query.")
            trace.update(resolved=False, resolution_kind="unresolved", selected_method=None)
            data["all_reference_edges"] = [edge for edge in data["all_reference_edges"] if edge["attribute"] != "AXGrowArea"]
            sync_scalar_fixture(data)
            self.assertTrue(check(data)["passed"])

    def test_scalar_native_type_and_geometry_decode_cannot_be_forged(self):
        for patch in ({"cf_type_id": 19}, {"expected_cf_type_id": None}, {"has_value": False}, {"valid": False},
                      {"ax_value_type": "cgPoint"}, {"ax_value_decoded": True}):
            data = scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["value_validation"].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])
        for patch in ({"ax_value_type": "cgSize"}, {"ax_value_decoded": False}, {"ax_value_decoded": None}):
            data = scalar_fixture("AXPosition")
            data["nodes"][1]["native_read_recoveries"]["AXPosition"]["queries"][1]["value_validation"].update(patch)
            sync_scalar_fixture(data, "AXPosition")
            self.assertFalse(check(data)["passed"])

    def test_scalar_no_value_discards_untrusted_returned_native_value(self):
        data = scalar_fixture(resolution="absence")
        validation = deepcopy(scalar_fixture()["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["value_validation"])
        data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["value_validation"] = validation
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])

    def test_scalar_routing_marker_contract_and_summary_are_required(self):
        for patch in ({"scalar_recovery_version": 4}, {"scalar_recovery_version": True},
                      {"native_metadata_failure_summary": {"attribute_unsupported": 1, "other_read_failures": 0}},
                      {"native_metadata_failure_summary": {"attribute_unsupported": False, "other_read_failures": 1}}):
            data = scalar_fixture(resolution="unresolved"); data.update(patch)
            self.assertFalse(check(data)["passed"])
        for patch in ({"expected_value_kind": "CGPoint"}, {"array_query_skipped": False}, {"scalar_retry_eligible": False}):
            data = scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["documented_scalar"].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_documented_scalar_cannot_route_to_array_or_rebind_attribute(self):
        for patch in ({"method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues"},
                      {"attribute": "AXHelp"}, {"query_method": "AXUIElementCopyMultipleAttributeValues"},
                      {"expected_value_kind": "CGPoint"}, {"initial_status": status(-25205)}):
            data = scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_scalar_encoded_value_must_match_native_type_evidence(self):
        for value in ([], None, False, {"type": "AXUIElement", "id": None}, {"type": "CGPoint", "x": 1, "y": 2}):
            data = scalar_fixture()
            data["nodes"][1]["attributes"]["AXGrowArea"] = value
            self.assertFalse(check(data)["passed"])
        data = scalar_fixture("AXPosition")
        data["nodes"][1]["attributes"]["AXPosition"]["type"] = "CGSize"
        self.assertFalse(check(data)["passed"])

    def test_documented_scalar_bulk_value_requires_the_native_slot_type(self):
        data = scalar_fixture()
        trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
        validation = deepcopy(trace["queries"][1]["value_validation"])
        bulk = bulk_trace("AXGrowArea")
        bulk.update(resolution_kind="value", cf_type_id=44, value_validation=validation)
        trace.update(queries=[bulk], selected_method=bulk["method"])
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        for patch in ({"cf_type_id": 19}, {"value_validation": None}):
            bad = deepcopy(data)
            bad["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][0].update(patch)
            sync_scalar_fixture(bad)
            self.assertFalse(check(bad)["passed"])

    def test_wrong_typed_scalar_bulk_slot_remains_unresolved_before_fresh_retry(self):
        data = scalar_fixture()
        trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
        validation = deepcopy(trace["queries"][1]["value_validation"])
        validation.update(cf_type_id=19, valid=False)
        bulk = bulk_trace("AXGrowArea")
        bulk.update(resolved=False, resolution_kind="unresolved", cf_type_id=19, value_validation=validation,
                    reason="Native scalar slot has the wrong native type.")
        trace["queries"][0] = bulk
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        trace["queries"][0].update(resolved=True, resolution_kind="value")
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_original_unsupported_documented_scalar_may_resolve_from_bulk_value(self):
        data = scalar_fixture(initial_code=-25205)
        node = data["nodes"][1]
        trace = node["native_read_recoveries"]["AXGrowArea"]
        validation = deepcopy(scalar_fixture()["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["value_validation"])
        bulk = bulk_trace("AXGrowArea")
        bulk.update(resolution_kind="value", cf_type_id=44, value_validation=validation)
        trace.update(queries=[bulk], resolved=True, resolution_kind="value", selected_method=bulk["method"])
        node["attributes"]["AXGrowArea"] = {"type": "AXUIElement", "id": 0}
        data["all_reference_edges"].append({"from": 1, "to": 0, "attribute": "AXGrowArea", "relationship": "reference", "value_path": []})
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])

    def test_fresh_scalar_prefix_process_change_keeps_error_and_issues_no_query(self):
        data = scalar_fixture(resolution="unresolved")
        scalar = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]
        refresh = scalar["refresh"]
        refresh["steps"][0].update(process_identity_matches=False, resolved=False)
        refresh.update(process_identity_matches=False, resolved=False, same_element=False, pid_status=None, pid=None,
                       reason="Prefix process launch identity changed.")
        scalar.update(query_status=None, value_validation=None, query_process_identity_matches=None)
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        refresh["process_identity_matches"] = True
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_fresh_scalar_foreign_native_prefix_requires_its_own_saved_pid(self):
        data = scalar_fixture()
        foreign = {"pid": 101, "launch_date": "foreign-launch", "bundle_id": "foreign", "executable_path": "/foreign"}
        data["process_identities"].append(foreign)
        data["nodes"][1].update(pid=101, process_identity=deepcopy(foreign))
        refresh = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["refresh"]
        refresh.update(expected_pid=101, pid=101)
        refresh["steps"][0].update(expected_pid=101, pid=101)
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        refresh["steps"][0].update(expected_pid=100, pid=100)
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_scalar_marker_preserves_array_discovery_for_other_attributes(self):
        data = outcome_v2_fixture(recovered_array_fixture(600))
        data.update(scalar_recovery_version=1, native_metadata_failure_summary={"attribute_unsupported": 0, "other_read_failures": 0})
        self.assertTrue(check(data)["passed"])

    def test_fresh_scalar_requires_recorded_process_launch_identity(self):
        data = scalar_fixture()
        data["app"].pop("launch_date")
        self.assertFalse(check(data)["passed"])
        data = scalar_fixture()
        data["nodes"][1]["process_identity"].pop("launch_date")
        self.assertFalse(check(data)["passed"])

    def test_scalar_standalone_audit_binds_saved_path_to_exact_owner(self):
        data = scalar_fixture()
        other = deepcopy(data["nodes"][1])
        other.update(id=2, native_read_recoveries={})
        other["attribute_statuses"] = {}
        data["nodes"].append(other)
        data["nodes"][0]["attributes"]["AXChildren"][0]["id"] = 2
        errors = []
        recovery_checks(data, data["nodes"], {node["id"]: node for node in data["nodes"]},
                        lambda ok, message: errors.append(message) if not ok else None)
        self.assertTrue(any("does not resolve the original owner" in error for error in errors), errors)

    def test_scalar_standalone_audit_rejects_malformed_saved_selectors(self):
        for path in (None, False, [{"attribute": "AXChildren", "value_path": [True]}], [{}]):
            data = scalar_fixture()
            data["nodes"][1]["selector_path"] = path
            errors = []
            recovery_checks(data, data["nodes"], {node["id"]: node for node in data["nodes"]},
                            lambda ok, message: errors.append(message) if not ok else None)
            self.assertTrue(any("selector path is malformed" in error for error in errors), errors)

    def test_scalar_v2_unsupported_can_return_typed_values_absence_or_original_error(self):
        for name in ("AXGrowArea", "AXTopLevelUIElement", "AXFrame", "AXPosition", "AXSize"):
            for resolution in ("value", "absence", "unresolved"):
                with self.subTest(name=name, resolution=resolution):
                    data = scalar_fixture(name, resolution, initial_code=-25205, scalar_version=2)
                    result = check(data)
                    self.assertTrue(result["passed"], result["errors"])
                    final = data["nodes"][1]["attribute_statuses"][name]
                    self.assertEqual(final["code"], {"value": 0, "absence": -25212, "unresolved": -25205}[resolution])
                    self.assertEqual(data["native_metadata_failure_summary"]["attribute_unsupported"], int(resolution == "unresolved"))

    def test_scalar_unsupported_retry_is_versioned_without_rewriting_v1_rules(self):
        legacy = scalar_fixture(initial_code=-25205)
        self.assertTrue(check(legacy)["passed"])
        legacy["scalar_recovery_version"] = 2
        self.assertFalse(check(legacy)["passed"])
        newer = scalar_fixture(initial_code=-25205, scalar_version=2)
        self.assertTrue(check(newer)["passed"])
        newer["scalar_recovery_version"] = 1
        self.assertFalse(check(newer)["passed"])

    def test_scalar_v2_successful_bulk_value_stops_before_unsupported_retry(self):
        data = scalar_fixture(initial_code=-25205, scalar_version=2)
        trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
        validation = deepcopy(trace["queries"][1]["value_validation"])
        bulk = bulk_trace("AXGrowArea")
        bulk.update(resolution_kind="value", cf_type_id=44, value_validation=validation)
        trace.update(queries=[bulk], selected_method=bulk["method"])
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        trace["queries"].append(deepcopy(scalar_fixture(initial_code=-25205, scalar_version=2)["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]))
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_scalar_v2_unsupported_retry_has_one_call_and_exact_original_status(self):
        for patch in ({"query_status": {**status(), "attempts": 2}}, {"initial_status": status(-25200)},
                      {"query_method": "AXUIElementGetAttributeValueCount"}):
            data = scalar_fixture(initial_code=-25205, scalar_version=2)
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1].update(patch)
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_scalar_v2_wrong_target_retains_unsupported_without_issuing_query(self):
        data = scalar_fixture(resolution="unresolved", initial_code=-25205, scalar_version=2)
        scalar = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]
        scalar["refresh"]["steps"][0].update(same_element=False, resolved=False)
        scalar["refresh"].update(same_element=False, pid_status=None, pid=None, resolved=False,
                                 reason="Fresh selector differs from the recorded native owner.")
        scalar.update(query_status=None, value_validation=None, query_process_identity_matches=None)
        sync_scalar_fixture(data)
        self.assertTrue(check(data)["passed"])
        scalar["query_status"] = status()
        sync_scalar_fixture(data)
        self.assertFalse(check(data)["passed"])

    def test_scalar_v2_nil_or_wrong_type_is_unresolved_and_never_faked_value(self):
        for patch in ({"has_value": False, "cf_type_id": None, "valid": False},
                      {"has_value": True, "cf_type_id": 19, "valid": False}):
            data = scalar_fixture(resolution="unresolved", initial_code=-25205, scalar_version=2)
            trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
            scalar = trace["queries"][1]
            scalar["query_status"] = status()
            scalar["value_validation"].update(patch)
            sync_scalar_fixture(data)
            self.assertTrue(check(data)["passed"])
            scalar.update(resolved=True, resolution_kind="value")
            trace.update(resolved=True, resolution_kind="value", selected_method="native_scalar_recovery")
            data["nodes"][1]["attributes"]["AXGrowArea"] = False
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_scalar_v2_process_change_after_unsupported_retry_preserves_failure(self):
        for resolution in ("value", "absence"):
            data = scalar_fixture(resolution=resolution, initial_code=-25205, scalar_version=2)
            trace = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]
            scalar = trace["queries"][1]
            scalar.update(query_process_identity_matches=False, resolved=False, resolution_kind="unresolved",
                          reason="Process changed during query.")
            trace.update(resolved=False, resolution_kind="unresolved", selected_method=None)
            data["all_reference_edges"] = [edge for edge in data["all_reference_edges"] if edge["attribute"] != "AXGrowArea"]
            sync_scalar_fixture(data)
            self.assertTrue(check(data)["passed"])
            self.assertEqual(data["nodes"][1]["attribute_statuses"]["AXGrowArea"]["code"], -25205)

    def test_typed_scalar_reference_with_native_registration_failure_retains_cutoff(self):
        for resolution in ("pid_read_failed", "outside_selected_process"):
            data = scalar_fixture(initial_code=-25205, scalar_version=2)
            value = {"type": "AXUIElement", "id": None, "resolution": resolution}
            cutoff = {"from": 1, "to": None, "attribute": "AXGrowArea", "value_path": [],
                      "relationship": "reference", "resolution": resolution}
            if resolution == "pid_read_failed":
                cutoff["status"] = {"code": -25202, "name": "invalidUIElement"}
            else:
                value["external_pid"] = 102
                cutoff["external_pid"] = 102
            data["nodes"][1]["attributes"]["AXGrowArea"] = value
            data["all_reference_edges"] = [edge for edge in data["all_reference_edges"] if edge["attribute"] != "AXGrowArea"] + [deepcopy(cutoff)]
            data.update(cutoffs=[deepcopy(cutoff)], exposed_hierarchy_resolved=False)
            result = check(data)
            self.assertTrue(result["passed"], result["errors"])
            self.assertFalse(data["exposed_hierarchy_resolved"])
            self.assertEqual(data["native_read_recovery_value_successes"], 1)
            for mutate in (lambda d: d.update(cutoffs=[]),
                           lambda d: d["cutoffs"][0].update(attribute="AXHelp"),
                           lambda d: d["nodes"][1]["attributes"]["AXGrowArea"].update(resolution="unknown")):
                malformed = deepcopy(data)
                mutate(malformed)
                self.assertFalse(check(malformed)["passed"])
            malformed = deepcopy(data)
            if resolution == "pid_read_failed":
                malformed["cutoffs"][0]["status"]["code"] = 0
            else:
                malformed["nodes"][1]["attributes"]["AXGrowArea"]["external_pid"] = 103
            self.assertFalse(check(malformed)["passed"])

    def test_scalar_v2_trace_requires_native_booleans_and_integer_path_indices(self):
        for field in ("array_query_skipped", "scalar_retry_eligible"):
            data = scalar_fixture(initial_code=-25205, scalar_version=2)
            data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["documented_scalar"][field] = 1
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])
        for field in ("step", "index"):
            data = scalar_fixture(initial_code=-25205, scalar_version=2)
            step = data["nodes"][1]["native_read_recoveries"]["AXGrowArea"]["queries"][1]["refresh"]["steps"][0]
            (step if field == "step" else step["path_steps"][0])[field] = False
            sync_scalar_fixture(data)
            self.assertFalse(check(data)["passed"])

    def test_scalar_v3_fresh_exact_queries_keep_retained_proofs_null(self):
        for name in ("AXGrowArea", "AXTopLevelUIElement", "AXFrame", "AXPosition", "AXSize"):
            data = scalar_fixture(name, initial_code=-25205, scalar_version=3)
            result = check(data)
            self.assertTrue(result["passed"], result["errors"])
            scalar = data["nodes"][1]["native_read_recoveries"][name]["queries"][1]
            self.assertEqual(scalar["query_target"], "fresh_exact_reference")
            self.assertEqual(data["native_scalar_retained_reference_attempts"], 0)
            scalar["query_target"] = "retained_original_reference"
            sync_scalar_fixture(data, name)
            self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_original_values_absence_and_errors_preserve_fresh_mismatch(self):
        for role in ("AXMenu", "AXMenuItem"):
            for resolution in ("value", "absence", "unresolved"):
                data = retained_scalar_fixture(resolution, role)
                result = check(data)
                self.assertTrue(result["passed"], result["errors"])
                scalar = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]
                self.assertFalse(scalar["refresh"]["resolved"])
                self.assertFalse(scalar["refresh"]["steps"][0]["same_element"])
                self.assertEqual(data["native_scalar_retained_reference_attempts"], 1)
                self.assertEqual(data["native_scalar_retained_reference_value_successes"], int(resolution == "value"))
                self.assertEqual(data["native_scalar_retained_reference_absence_successes"], int(resolution == "absence"))

    def test_scalar_v3_retained_retry_is_blocked_by_any_other_native_refresh_failure(self):
        for target, patch in (("refresh", {"root_same_element": False}), ("refresh", {"process_identity_matches": False}),
                              ("refresh", {"root_timeout_status": status(-25200)}), ("step", {"query_status": status(-25200)}),
                              ("step", {"has_value": False}), ("step", {"selected_is_element": False}),
                              ("step", {"pid_status": status(-25200)}), ("step", {"pid": 101}),
                              ("step", {"process_identity_matches": False}), ("part", {"resolved": False}),
                              ("part", {"selected_has_value": False}), ("part", {"index": 1})):
            data = retained_scalar_fixture()
            refresh = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]["refresh"]
            destination = refresh if target == "refresh" else refresh["steps"][0] if target == "step" else refresh["steps"][0]["path_steps"][0]
            destination.update(patch)
            sync_scalar_fixture(data, "AXTopLevelUIElement")
            self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_reference_requires_exact_original_registry_and_native_role(self):
        for patch in ({"node_id": 0}, {"root_id": 1}, {"source": "fresh_selector"}, {"root_pid": 101},
                      {"expected_pid": 101}, {"owner_role": "AXButton"}, {"owner_role_status": status(-25200)},
                      {"registry_binding_matches": False}, {"owner_cf_type_id": 19}, {"expected_cf_type_id": None},
                      {"root_native_pid": 101}, {"owner_native_pid": 101}, {"root_process_identity_matches": False},
                      {"owner_process_identity_matches": False}):
            data = retained_scalar_fixture()
            data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]["retained_reference"].update(patch)
            sync_scalar_fixture(data, "AXTopLevelUIElement")
            self.assertFalse(check(data)["passed"])

    def test_scalar_v3_failed_original_registry_validation_withholds_the_single_query(self):
        data = retained_scalar_fixture("unresolved")
        scalar = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]
        scalar["retained_reference"].update(registry_binding_matches=False, root_pid_status=None, root_native_pid=None,
            owner_pid_status=None, owner_native_pid=None, resolved=False, reason="Original registry binding no longer matches.")
        scalar.update(query_target=None, query_retained_reference_validation=None, query_status=None,
                      query_process_identity_matches=None, value_validation=None)
        sync_scalar_fixture(data, "AXTopLevelUIElement")
        result = check(data)
        self.assertTrue(result["passed"], result["errors"])
        self.assertEqual(data["native_scalar_retained_reference_withheld"], 1)
        self.assertEqual(data["native_scalar_retained_reference_attempts"], 0)
        scalar["query_status"] = status()
        sync_scalar_fixture(data, "AXTopLevelUIElement")
        self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_launch_change_after_query_preserves_original_error(self):
        for resolution in ("value", "absence"):
            data = retained_scalar_fixture(resolution)
            trace = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]
            scalar = trace["queries"][1]
            scalar["query_retained_reference_validation"].update(root_process_identity_matches=False, root_pid_status=None,
                root_native_pid=None, owner_pid_status=None, owner_native_pid=None, resolved=False,
                reason="Original process changed after query.")
            scalar.update(resolved=False, resolution_kind="unresolved", reason="Original retained reference no longer validates.")
            trace.update(resolved=False, resolution_kind="unresolved", selected_method=None)
            data["all_reference_edges"] = [edge for edge in data["all_reference_edges"] if edge["attribute"] != "AXTopLevelUIElement"]
            sync_scalar_fixture(data, "AXTopLevelUIElement")
            result = check(data)
            self.assertTrue(result["passed"], result["errors"])
            self.assertEqual(data["nodes"][1]["attribute_statuses"]["AXTopLevelUIElement"]["code"], -25205)

    def test_scalar_v3_retained_after_query_pid_failure_cannot_be_marked_resolved(self):
        data = retained_scalar_fixture()
        scalar = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]
        scalar["query_retained_reference_validation"].update(owner_pid_status=status(-25202), owner_native_pid=None,
            resolved=False, reason="Original owner is no longer a valid native element.")
        sync_scalar_fixture(data, "AXTopLevelUIElement")
        self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_query_is_narrow_to_native_menu_top_level_attribute(self):
        data = retained_scalar_fixture(role="AXButton")
        self.assertFalse(check(data)["passed"])
        data = retained_scalar_fixture()
        node = data["nodes"][1]
        trace = node["native_read_recoveries"].pop("AXTopLevelUIElement")
        node["native_read_recoveries"]["AXGrowArea"] = trace
        node["attribute_names"] = ["AXGrowArea" if name == "AXTopLevelUIElement" else name for name in node["attribute_names"]]
        node["attribute_statuses"].pop("AXTopLevelUIElement")
        node["attributes"]["AXGrowArea"] = node["attributes"].pop("AXTopLevelUIElement")
        trace["documented_scalar"]["attribute"] = "AXGrowArea"
        trace["queries"][0].update(query_attributes=["AXGrowArea"], slot_attribute="AXGrowArea")
        trace["queries"][1]["attribute"] = "AXGrowArea"
        sync_scalar_fixture(data, "AXGrowArea")
        self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_counters_and_version_are_exact(self):
        for key in ("native_scalar_retained_reference_attempts", "native_scalar_retained_reference_withheld",
                    "native_scalar_retained_reference_value_successes", "native_scalar_retained_reference_absence_successes"):
            data = retained_scalar_fixture()
            data[key] += 1
            self.assertFalse(check(data)["passed"])
        for version in (1, 2):
            data = retained_scalar_fixture()
            data["scalar_recovery_version"] = version
            self.assertFalse(check(data)["passed"])
        data = scalar_fixture(scalar_version=2)
        data["native_scalar_retained_reference_attempts"] = 0
        self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_pid_reads_and_scalar_query_each_make_one_native_call(self):
        for field in ("root_pid_status", "owner_pid_status"):
            for proof_key in ("retained_reference", "query_retained_reference_validation"):
                data = retained_scalar_fixture()
                data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1][proof_key][field]["attempts"] = 2
                sync_scalar_fixture(data, "AXTopLevelUIElement")
                self.assertFalse(check(data)["passed"])
        data = retained_scalar_fixture()
        data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]["query_status"]["attempts"] = 2
        sync_scalar_fixture(data, "AXTopLevelUIElement")
        self.assertFalse(check(data)["passed"])

    def test_scalar_v3_retained_native_cf_type_is_consistent_across_all_evidence(self):
        for proof_key in ("retained_reference", "query_retained_reference_validation", "value_validation"):
            data = retained_scalar_fixture()
            scalar = data["nodes"][1]["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]
            proof = scalar[proof_key]
            proof["expected_cf_type_id"] = 45
            proof["cf_type_id" if proof_key == "value_validation" else "owner_cf_type_id"] = 45
            sync_scalar_fixture(data, "AXTopLevelUIElement")
            self.assertFalse(check(data)["passed"])


if __name__ == "__main__":
    unittest.main()
