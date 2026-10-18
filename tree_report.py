#!/usr/bin/env python3
"""Create a standalone expandable tree from a saved native AX snapshot."""
import argparse
from collections import Counter, defaultdict, deque
import hashlib
import json
from pathlib import Path


def plain(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, dict):
        for key in ("string", "value"):
            if key in value and isinstance(value[key], (str, int, float, bool)):
                return str(value[key])
    return ""


def metadata_records(snapshot):
    """Read the additive classification, or derive it from an older export."""
    legacy = snapshot.get("metadata_failures", [])
    reads = snapshot.get("metadata_read_failures")
    serialization = snapshot.get("serialization_warnings")
    if reads is None:
        reads = [item for item in legacy if item.get("stage") != "serialization"]
    if serialization is None:
        serialization = [item for item in legacy if item.get("stage") == "serialization"]
    if not isinstance(reads, list) or not isinstance(serialization, list):
        raise ValueError("Metadata classifications must be arrays")
    return reads, serialization


def project(snapshot):
    nodes = snapshot["nodes"]
    by_id = {n["id"]: n for n in nodes}
    if len(by_id) != len(nodes) or any(type(i) is not int or i < 0 for i in by_id):
        raise ValueError("Native node IDs must be unique nonnegative integers")
    root = snapshot["root_id"]
    if root not in by_id:
        raise ValueError("Native root is missing")
    adjacency = {}
    for n in nodes:
        targets = []
        seen = set()
        hierarchy = n.get("hierarchy", {})
        names = sorted(hierarchy, key=lambda name: (name != "AXChildren", name))
        for name in names:
            for target in hierarchy[name]:
                if type(target) is not int or target not in by_id:
                    raise ValueError("A containment edge has no captured native target")
                if target not in seen:
                    targets.append(target)
                    seen.add(target)
        adjacency[n["id"]] = targets
    parents, depths, children, roots = {}, {}, defaultdict(list), []
    for seed in [root] + sorted(i for i in by_id if i != root):
        if seed in parents:
            continue
        roots.append(seed)
        parents[seed], depths[seed] = None, 0
        pending = deque([seed])
        while pending:
            parent = pending.popleft()
            for target in adjacency[parent]:
                if target not in parents:
                    parents[target] = parent
                    depths[target] = depths[parent] + 1
                    children[parent].append(target)
                    pending.append(target)
    if set(parents) != set(by_id):
        raise ValueError("Tree projection omitted captured native IDs")
    issues = defaultdict(list)
    metadata_reads, serialization_warnings = metadata_records(snapshot)
    for records, kind in ((snapshot.get("hierarchy_failures", []), "hierarchy"),
                          (metadata_reads, "native_read"),
                          (serialization_warnings, "serialization")):
        for item in records:
            if item["node"] not in by_id:
                raise ValueError("Failure record has no captured node")
            record = {"kind": kind, **item}
            if kind == "native_read":
                owner = by_id[item["node"]]
                names = owner.get("attribute_names")
                confirmed_names = isinstance(names, list) \
                    and owner.get("attribute_names_status", {}).get("code") == 0
                record["native_attribute_advertised"] = (
                    item.get("attribute") in names if item.get("stage") == "attribute_read"
                    and confirmed_names else None)
            issues[item["node"]].append(record)
    references = defaultdict(list)
    for edge in snapshot.get("all_reference_edges", []):
        if edge.get("relationship") != "hierarchy" and edge.get("to") in by_id:
            references[edge["from"]].append([edge["attribute"], edge["to"]])
    rendered = []
    for n in nodes:
        a = n.get("attributes", {})
        title, description, identifier, value = [plain(a.get(name)) for name in
                                               ("AXTitle", "AXDescription", "AXIdentifier", "AXValue")]
        rendered.append({
            "id": n["id"], "parent": parents[n["id"]],
            "children": children[n["id"]], "native_children": adjacency[n["id"]],
            "role": plain(a.get("AXRole")) or "Unknown role",
            "label": title or description or identifier or value or "(unlabelled)",
            "value": value, "identifier": identifier, "description": description,
            "actions": n.get("action_names", []), "leaf": n.get("leaf_status", "unknown"),
            "depth": depths[n["id"]], "attributes": a,
            "hierarchy": n.get("hierarchy", {}), "references": references[n["id"]],
            "issues": issues[n["id"]],
            "parameterized_names": n.get("parameterized_attribute_names", []),
            "attribute_names_status": n.get("attribute_names_status", {}),
            "action_names_status": n.get("action_names_status", {}),
            "parameterized_names_status": n.get("parameterized_attribute_names_status", {}),
        })
        if "native_read_recoveries" in n:
            rendered[-1]["native_read_recoveries"] = n["native_read_recoveries"]
    statuses = Counter(n.get("leaf_status", "unknown") for n in nodes)
    incoming = defaultdict(set)
    for parent, targets in adjacency.items():
        for target in targets:
            incoming[target].add(parent)
    api_success_warnings = sum(i.get("status", {}).get("code") == 0
                               for i in serialization_warnings)
    selected_text_range_failures = sum(i.get("attribute") == "AXSelectedTextRanges"
                                       for i in metadata_reads)
    unsupported_reads = sum(i.get("status", {}).get("code") == -25205
                            for i in metadata_reads)
    derived_failure_summary = {"attribute_unsupported": unsupported_reads,
                               "other_read_failures": len(metadata_reads) - unsupported_reads}
    failure_summary = snapshot.get("native_metadata_failure_summary", derived_failure_summary)
    if not isinstance(failure_summary, dict) or any(
            type(failure_summary.get(key)) is not int or failure_summary[key] != count
            for key, count in derived_failure_summary.items()):
        raise ValueError("Native metadata failure summary disagrees with the recorded read errors")
    meta = {
        "app": snapshot.get("app", {}), "root_id": root,
        "started_at": snapshot.get("started_at"), "finished_at": snapshot.get("finished_at"),
        "node_count": len(nodes), "leaf_count": statuses["leaf"],
        "branch_count": statuses["branch"], "unknown_leaf_count": statuses["unknown"],
        "hierarchy_failure_count": len(snapshot.get("hierarchy_failures", [])),
        # Retain the combined count in the projected schema for compatibility;
        # the UI presents the two categories separately.
        "metadata_failure_count": len(metadata_reads) + len(serialization_warnings),
        "metadata_read_failure_count": len(metadata_reads),
        "native_metadata_failure_summary": failure_summary,
        "native_metadata_failure_summary_source": "explicit native counters" if
            "native_metadata_failure_summary" in snapshot else "derived from recorded native error codes",
        "serialization_warning_count": len(serialization_warnings),
        "metadata_breakdown": [
            {"label": "Serialization warnings following successful native API reads", "count": api_success_warnings},
            {"label": "Other serialization warnings", "count": len(serialization_warnings) - api_success_warnings},
            {"label": "AXSelectedTextRanges native read failures (included in read failure total)", "count": selected_text_range_failures},
            {"label": "Native unsupported reads (included in read failure total)", "count": unsupported_reads},
            {"label": "Known native absence / noValue (not a failure)", "count": len(snapshot.get("absent_attribute_values", []))}],
        "metadata_classification_source": "explicit arrays" if
            "metadata_read_failures" in snapshot and "serialization_warnings" in snapshot
            else "derived from recorded legacy stages",
        "cutoff_count": len(snapshot.get("cutoffs", [])),
        "canonical_roots": roots, "primary_edge_count": sum(len(v) for v in children.values()),
        "shared_hierarchy_target_count": sum(len(v) > 1 for v in incoming.values()),
        "graph_digest": snapshot.get("graph_digest"), "scope": snapshot.get("scope", {}),
        "exposed_hierarchy_resolved": snapshot.get("exposed_hierarchy_resolved", False),
        "maximum_tree_depth": max(depths.values(), default=0),
        "role_counts": dict(Counter(n["role"] for n in rendered)),
        "capture_recovery": snapshot.get("capture_recovery"),
    }
    for field in ("scalar_recovery_version", "native_read_recovery_attempts", "native_read_recovery_successes",
                  "native_read_recovery_outcome_version", "native_read_recovery_value_successes",
                  "native_read_recovery_absence_successes",
                  "native_scalar_retained_reference_attempts", "native_scalar_retained_reference_withheld",
                  "native_scalar_retained_reference_value_successes",
                  "native_scalar_retained_reference_absence_successes"):
        if field in snapshot:
            meta[field] = snapshot[field]
    return {"schema": "native-ax-tree-view/1", "meta": meta, "nodes": rendered}


def generate(source, output=None):
    path = source / "snapshot.json" if source.is_dir() else source
    with path.open() as handle:
        snapshot = json.load(handle)
    data = project(snapshot)
    output = output or path.parent / "report.html"
    # Keep raw links relative to the destination, so the report can live elsewhere.
    import os
    from urllib.parse import quote
    data["source"] = {name: quote(os.path.relpath(path.parent / filename, output.parent), safe="/")
                      for name, filename in (("snapshot", "snapshot.json"),
                                             ("coverage", "coverage.json"), ("leaves", "leaves.ndjson"))}
    # These native lists and issue patterns repeat thousands of times. Store
    # each distinct value once; the viewer restores the exact per-node arrays.
    parameter_sets, parameter_index = [], {}
    issue_patterns, issue_index = [], {}
    for node in data["nodes"]:
        names = node.pop("parameterized_names")
        key = json.dumps(names, ensure_ascii=False, separators=(",", ":"))
        if key not in parameter_index:
            parameter_index[key] = len(parameter_sets)
            parameter_sets.append(names)
        node["parameterized_names_index"] = parameter_index[key]
        indexes = []
        for issue in node.pop("issues"):
            pattern = {key: value for key, value in issue.items() if key != "node"}
            key = json.dumps(pattern, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            if key not in issue_index:
                issue_index[key] = len(issue_patterns)
                issue_patterns.append(pattern)
            indexes.append(issue_index[key])
        node["issue_pattern_indexes"] = indexes
    data["tables"] = {"parameterized_names": parameter_sets, "issue_patterns": issue_patterns}
    serialized = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    serialized = serialized.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    template = Path(__file__).with_name("tree_viewer.html").read_text()
    if template.count("__TREE_PAYLOAD__") != 1:
        raise ValueError("Viewer template must have exactly one payload placeholder")
    output.write_text(template.replace("__TREE_PAYLOAD__", serialized))
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    result = {"report": str(output.resolve()), "source": str(path.resolve()),
              "source_sha256": digest.hexdigest(), "report_bytes": output.stat().st_size,
              "native_node_count": data["meta"]["node_count"],
              "native_ids_represented": len({n["id"] for n in data["nodes"]}),
              "canonical_roots": data["meta"]["canonical_roots"],
              "primary_edge_count": data["meta"]["primary_edge_count"],
              "offline_export_only": True}
    output.with_name("tree-view-validation.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


def self_test():
    """Offline compatibility fixtures; no native app access or export writes."""
    from copy import deepcopy
    original_error = {"attempts": 1, "code": -25200, "name": "failure"}
    read = {"node": 0, "attribute": "AXSelectedTextRanges", "stage": "attribute_read",
            "status": original_error}
    warning = {"node": 0, "attribute": "AXTextMarker", "stage": "serialization",
               "status": {"attempts": 1, "code": 0, "name": "success"}}
    base = {"root_id": 0, "nodes": [{"id": 0, "attributes": {}, "hierarchy": {},
                                     "leaf_status": "unknown"}],
            "metadata_failures": [read, warning]}
    fixtures = [({}, (1, 1)),
                ({"metadata_read_failures": [], "serialization_warnings": []}, (0, 0)),
                ({"metadata_read_failures": [read], "serialization_warnings": [warning]}, (1, 1)),
                ({"metadata_read_failures": []}, (0, 1))]
    count = 0
    for fields, expected in fixtures:
        fixture = deepcopy(base)
        fixture.update(deepcopy(fields))
        view = project(fixture)
        actual = (view["meta"]["metadata_read_failure_count"],
                  view["meta"]["serialization_warning_count"])
        assert actual == expected, (actual, expected)
        assert len(view["nodes"][0]["issues"]) == sum(expected)
        assert view["meta"]["unknown_leaf_count"] == 1
        count += 1
    for resolved in (False, True):
        fixture = deepcopy(base)
        trace = {"method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues",
                 "initial_status": original_error, "resolved": resolved, "pages": []}
        if resolved:
            success = {"attempts": 1, "code": 0, "name": "success"}
            trace.update(count_before_status=success, count_before=0,
                         count_after_status=success, count_after=0, returned_count=0)
            fixture["metadata_read_failures"] = []
            fixture["nodes"][0]["attributes"]["AXSelectedTextRanges"] = []
        else:
            trace.update(count_before_status=original_error,
                         reason="Native count failed; an empty value is not established.")
        fixture["nodes"][0]["native_read_recoveries"] = {"AXSelectedTextRanges": trace}
        fixture["native_read_recovery_attempts"] = 1
        fixture["native_read_recovery_successes"] = int(resolved)
        fixture["capture_recovery"] = {"attempts": [{"attempt": 1,
            "node_count": 1, "unknown_leaf_count": 1, "invalid_reference_count": 1,
            "exposed_hierarchy_resolved": False}]}
        view = project(fixture)
        assert view["nodes"][0]["native_read_recoveries"] == fixture["nodes"][0]["native_read_recoveries"]
        assert view["meta"]["native_read_recovery_successes"] == int(resolved)
        assert view["meta"]["native_read_recovery_attempts"] == 1
        assert view["meta"]["capture_recovery"] == fixture["capture_recovery"]
        assert ("AXSelectedTextRanges" in view["nodes"][0]["attributes"]) == resolved
        assert view["meta"]["metadata_read_failure_count"] == int(not resolved)
        count += 1
    legacy_view = project(base)
    assert "native_read_recoveries" not in legacy_view["nodes"][0]
    assert "native_read_recovery_attempts" not in legacy_view["meta"]
    count += 1
    success = {"attempts": 1, "code": 0, "name": "success"}
    bulk = {"method": "AXUIElementCopyMultipleAttributeValues",
            "query_attributes": ["AXRecovered"], "options": 0, "query_status": success,
            "has_array": True, "returned_slot_count": 1, "slot_index": 0,
            "slot_attribute": "AXRecovered", "item_kind": "value", "cf_type_id": 7,
            "resolved": True}
    for value in (False, 0, "", []):
        fixture = deepcopy(base)
        trace = {"method": "native_metadata_recovery", "initial_status": original_error,
                 "queries": [deepcopy(bulk)], "resolved": True, "resolution_kind": "value",
                 "selected_method": "AXUIElementCopyMultipleAttributeValues"}
        trace["queries"][0]["resolution_kind"] = "value"
        fixture["nodes"][0]["attributes"]["AXRecovered"] = value
        fixture["nodes"][0]["native_read_recoveries"] = {"AXRecovered": trace}
        fixture["metadata_read_failures"] = []
        fixture.update(native_read_recovery_outcome_version=2, native_read_recovery_attempts=1,
                       native_read_recovery_successes=1, native_read_recovery_value_successes=1,
                       native_read_recovery_absence_successes=0)
        view = project(fixture)
        actual = view["nodes"][0]
        assert actual["attributes"]["AXRecovered"] == value
        assert type(actual["attributes"]["AXRecovered"]) is type(value)
        assert actual["native_read_recoveries"] == fixture["nodes"][0]["native_read_recoveries"]
        assert "returned_count" not in actual["native_read_recoveries"]["AXRecovered"]
        assert view["meta"]["metadata_read_failure_count"] == 0
        assert view["meta"]["native_read_recovery_value_successes"] == 1
        assert view["meta"]["native_read_recovery_absence_successes"] == 0
        count += 1
    for kind in ("null", "ax_error", "malformed"):
        fixture = deepcopy(base)
        query = deepcopy(bulk)
        query.update(item_kind=kind, resolved=False,
                     reason="Native bulk slot did not establish a successful value.")
        if kind == "ax_error":
            query.update(item_status=original_error, item_error_decoded=True)
        trace = {"method": "native_metadata_recovery", "initial_status": original_error,
                 "queries": [query], "resolved": False, "resolution_kind": "unresolved",
                 "selected_method": None}
        fixture["nodes"][0]["native_read_recoveries"] = {"AXRecovered": trace}
        view = project(fixture)
        assert "AXRecovered" not in view["nodes"][0]["attributes"]
        assert view["nodes"][0]["native_read_recoveries"]["AXRecovered"] == trace
        assert view["meta"]["metadata_read_failure_count"] == 1
        count += 1
    for action_names in ([], ["AXPress"], None):
        fixture = deepcopy(base)
        resolved = action_names is not None
        trace = {"method": "native_action_names_recovery", "initial_status": original_error,
                 "query_status": success if resolved else original_error,
                 "has_array": resolved, "resolved": resolved, "names_valid": resolved,
                 "resolution_kind": "value" if resolved else "unresolved",
                 "strings_count": len(action_names) if resolved else None}
        if resolved:
            fixture["nodes"][0]["action_names"] = action_names
            fixture["metadata_read_failures"] = []
        else:
            trace["reason"] = "Native action enumeration failed."
        fixture["nodes"][0]["action_names_status"] = {"native_read_recovery": trace}
        fixture["nodes"][0]["native_read_recoveries"] = {"action_names": trace}
        view = project(fixture)
        actual = view["nodes"][0]
        assert actual["actions"] == (action_names if resolved else [])
        assert actual["action_names_status"]["native_read_recovery"] == trace
        assert actual["native_read_recoveries"]["action_names"] == trace
        assert trace["names_valid"] == resolved
        assert (trace["strings_count"] is not None) == resolved
        assert view["meta"]["metadata_read_failure_count"] == int(not resolved)
        count += 1
    fixture = deepcopy(base)
    malformed_action_trace = {"method": "native_action_names_recovery",
        "initial_status": original_error, "query_status": success, "has_array": True,
        "names_valid": False, "strings_count": None, "resolved": False, "resolution_kind": "unresolved",
        "reason": "Native enumeration returned a malformed action array."}
    fixture["nodes"][0]["native_read_recoveries"] = {"action_names": malformed_action_trace}
    view = project(fixture)
    assert view["nodes"][0]["actions"] == []
    assert view["nodes"][0]["native_read_recoveries"]["action_names"] == malformed_action_trace
    assert view["meta"]["metadata_read_failure_count"] == 1
    count += 1
    fixture = deepcopy(base)
    no_value = {"code": -25212, "name": "noValue", "attempts": 1}
    query = deepcopy(bulk)
    query.update(item_kind="ax_error", item_error_decoded=True, item_status=no_value,
                 resolved=True, resolution_kind="absence")
    trace = {"method": "native_metadata_recovery", "initial_status": original_error,
             "queries": [query], "resolved": True, "resolution_kind": "absence",
             "selected_method": "AXUIElementCopyMultipleAttributeValues"}
    fixture["nodes"][0]["native_read_recoveries"] = {"AXRecovered": trace}
    fixture["metadata_read_failures"] = []
    fixture["serialization_warnings"] = []
    fixture["absent_attribute_values"] = [{"node": 0, "attribute": "AXRecovered",
        "status": {**no_value, "native_read_recovery": trace}}]
    fixture.update(native_read_recovery_outcome_version=2, native_read_recovery_attempts=1,
                   native_read_recovery_successes=1, native_read_recovery_value_successes=0,
                   native_read_recovery_absence_successes=1)
    view = project(fixture)
    actual = view["nodes"][0]
    assert "AXRecovered" not in actual["attributes"]
    assert actual["native_read_recoveries"]["AXRecovered"] == trace
    assert actual["native_read_recoveries"]["AXRecovered"]["initial_status"]["code"] == -25200
    assert actual["native_read_recoveries"]["AXRecovered"]["queries"][0]["item_status"]["code"] == -25212
    assert view["meta"]["native_read_recovery_value_successes"] == 0
    assert view["meta"]["native_read_recovery_absence_successes"] == 1
    assert view["meta"]["native_read_recovery_successes"] == 1
    assert view["meta"]["metadata_read_failure_count"] == 0
    assert view["meta"]["unknown_leaf_count"] == 1  # Attribute absence does not resolve a branch.
    count += 1
    # Fresh scalar reads preserve both the original bulk failure and exact native
    # target/type evidence. Only values actually recorded by the engine appear.
    unsupported = {"attempts": 1, "code": -25205, "name": "attributeUnsupported"}
    outcomes = ("value", "absence", "query_failure", "wrong_type",
                "target_mismatch", "process_changed", "unsupported")
    scalar_cases = [(1, outcome) for outcome in outcomes] + [(2, outcome) for outcome in outcomes]
    for scalar_version, outcome in scalar_cases:
        fixture = deepcopy(base)
        attribute = "AXTopLevelUIElement" if scalar_version == 2 else "AXGrowArea"
        initial = unsupported if scalar_version == 2 or outcome == "unsupported" else original_error
        eligible = scalar_version == 2 or outcome != "unsupported"
        documented = {"attribute": attribute, "expected_value_kind": "AXUIElement",
                      "array_query_skipped": True, "scalar_retry_eligible": eligible}
        bulk_query = deepcopy(bulk)
        bulk_query.update(query_attributes=[attribute], slot_attribute=attribute,
                          item_kind="ax_error", item_status=initial, item_error_decoded=True,
                          resolved=False, resolution_kind="unresolved")
        trace = {"method": "native_metadata_recovery", "initial_status": initial,
                 "queries": [bulk_query], "documented_scalar": documented,
                 "resolved": outcome in ("value", "absence"),
                 "resolution_kind": outcome if outcome in ("value", "absence") else "unresolved",
                 "selected_method": "native_scalar_recovery" if outcome in ("value", "absence") else None}
        if eligible:
            refresh = {"attempted": True, "selector_path": [{"attribute": "AXWindows", "index": 0}],
                       "root_pid": 123, "expected_pid": 123, "process_identity_matches": True,
                       "root_same_element": True, "root_timeout_status": success,
                       "steps": [{"attribute": "AXWindows", "status": success,
                                  "same_element": True, "expected_pid": 123}],
                       "same_element": outcome != "target_mismatch", "pid_status": success,
                       "pid": 123, "resolved": outcome != "target_mismatch"}
            if outcome == "target_mismatch":
                refresh["reason"] = "Native element identity differs from the recorded target."
            validation = {"expected_value_kind": "AXUIElement", "expected_cf_type_id": 101,
                          "has_value": outcome in ("value", "wrong_type", "process_changed"),
                          "cf_type_id": 7 if outcome == "wrong_type" else 101,
                          "ax_value_type": None, "ax_value_decoded": None,
                          "valid": outcome in ("value", "process_changed")}
            scalar = {"method": "native_scalar_recovery", "attribute": attribute,
                      "expected_value_kind": "AXUIElement", "initial_status": initial,
                      "query_method": "AXUIElementCopyAttributeValue", "refresh": refresh,
                      "query_status": None if outcome == "target_mismatch" else
                          no_value if outcome == "absence" else
                          unsupported if outcome == "unsupported" else
                          original_error if outcome == "query_failure" else success,
                      "query_process_identity_matches": None if outcome == "target_mismatch"
                          else outcome != "process_changed",
                      "value_validation": None if outcome == "target_mismatch" else validation,
                      "resolved": trace["resolved"], "resolution_kind": trace["resolution_kind"]}
            trace["queries"].append(scalar)
        fixture["nodes"][0].update(attribute_names=[attribute], attribute_names_status=success,
                                  native_read_recoveries={attribute: trace})
        fixture["metadata_read_failures"] = [] if trace["resolved"] else [
            {"node": 0, "attribute": attribute, "stage": "attribute_read",
             "status": {**initial, "native_read_recovery": trace}}]
        fixture["serialization_warnings"] = []
        if outcome == "value":
            fixture["nodes"][0]["attributes"][attribute] = {"type": "AXUIElement", "id": 1}
        elif outcome == "absence":
            fixture["absent_attribute_values"] = [{"node": 0, "attribute": attribute,
                "status": {**no_value, "native_read_recovery": trace}}]
        fixture.update(scalar_recovery_version=scalar_version, native_read_recovery_outcome_version=2,
                       native_read_recovery_attempts=1, native_read_recovery_successes=int(trace["resolved"]),
                       native_read_recovery_value_successes=int(outcome == "value"),
                       native_read_recovery_absence_successes=int(outcome == "absence"),
                       native_metadata_failure_summary={"attribute_unsupported": int(not trace["resolved"] and initial == unsupported),
                           "other_read_failures": int(not trace["resolved"] and initial != unsupported)})
        view = project(fixture)
        actual = view["nodes"][0]
        assert actual["native_read_recoveries"][attribute] == trace
        assert (attribute in actual["attributes"]) == (outcome == "value")
        assert view["meta"]["scalar_recovery_version"] == scalar_version
        assert view["meta"]["native_metadata_failure_summary"] == fixture["native_metadata_failure_summary"]
        assert view["meta"]["metadata_read_failure_count"] == int(not trace["resolved"])
        if actual["issues"]:
            assert actual["issues"][0]["native_attribute_advertised"] is True
            assert actual["issues"][0]["status"]["native_read_recovery"] == trace
        if outcome == "target_mismatch":
            assert scalar["query_status"] is None and scalar["value_validation"] is None
        count += 1
    # Version 3 preserves a failed fresh refresh alongside a separately checked
    # retained registry owner. Projection never turns that failure into a match.
    for outcome in ("value", "absence", "unsupported", "invalid_element", "wrong_type",
                    "process_changed", "refused_retention"):
        fixture = deepcopy(base)
        queried = outcome != "refused_retention"
        resolved = outcome in ("value", "absence")
        kind = outcome if resolved else "unresolved"
        refresh = {"attempted": True, "selector_path": [{"attribute": "AXMenuBar", "value_path": []}],
                   "root_pid": 123, "expected_pid": 123, "process_identity_matches": True,
                   "root_same_element": True, "root_timeout_status": success,
                   "steps": [{"step": 0, "attribute": "AXMenuBar", "value_path": [], "path_steps": [],
                              "query_status": success, "has_value": True, "selected_is_element": True,
                              "selected_cf_type_id": 101, "pid_status": success, "pid": 123,
                              "expected_pid": 123, "process_identity_matches": True,
                              "same_element": False, "resolved": False}],
                   "same_element": None, "pid_status": None, "pid": None, "resolved": False,
                   "reason": "Fresh native prefix differs from the captured element."}
        retained = {"attempted": True, "source": "capture_registry", "node_id": 0, "root_id": 0,
                    "root_pid": 123, "expected_pid": 123, "owner_role": "AXMenuItem",
                    "owner_role_status": success, "expected_cf_type_id": 101, "owner_cf_type_id": 101,
                    "registry_binding_matches": queried, "root_pid_status": success if queried else None,
                    "root_native_pid": 123 if queried else None, "owner_pid_status": success if queried else None,
                    "owner_native_pid": 123 if queried else None,
                    "root_process_identity_matches": True if queried else None,
                    "owner_process_identity_matches": True if queried else None, "resolved": queried}
        if not queried:
            retained["reason"] = "Retained query target is not the exact original capture-registry owner."
        post = deepcopy(retained) if queried else None
        if outcome == "process_changed":
            post.update(owner_process_identity_matches=False, resolved=False,
                        reason="Captured root or retained owner process/launch identity changed.")
        validation = {"expected_value_kind": "AXUIElement", "expected_cf_type_id": 101,
                      "has_value": outcome in ("value", "wrong_type", "process_changed"),
                      "cf_type_id": 7 if outcome == "wrong_type" else
                          101 if outcome in ("value", "process_changed") else None,
                      "ax_value_type": None, "ax_value_decoded": None,
                      "valid": outcome in ("value", "process_changed")} if queried else None
        query_status = None if not queried else no_value if outcome == "absence" else \
            unsupported if outcome == "unsupported" else \
            {"code": -25202, "name": "invalidUIElement", "attempts": 1} if outcome == "invalid_element" else success
        scalar = {"method": "native_scalar_recovery", "attribute": "AXTopLevelUIElement",
                  "expected_value_kind": "AXUIElement", "initial_status": unsupported,
                  "query_method": "AXUIElementCopyAttributeValue", "refresh": refresh,
                  "query_target": "retained_original_reference" if queried else None,
                  "retained_reference": retained, "query_retained_reference_validation": post,
                  "query_status": query_status, "query_process_identity_matches":
                      outcome != "process_changed" if queried else None,
                  "value_validation": validation, "resolved": resolved, "resolution_kind": kind}
        bulk_query = deepcopy(bulk)
        bulk_query.update(query_attributes=["AXTopLevelUIElement"], slot_attribute="AXTopLevelUIElement",
                          item_kind="ax_error", item_status=unsupported, item_error_decoded=True,
                          resolved=False, resolution_kind="unresolved")
        trace = {"method": "native_metadata_recovery", "initial_status": unsupported,
                 "queries": [bulk_query, scalar], "documented_scalar": {"attribute": "AXTopLevelUIElement",
                     "expected_value_kind": "AXUIElement", "array_query_skipped": True, "scalar_retry_eligible": True},
                 "resolved": resolved, "resolution_kind": kind,
                 "selected_method": "native_scalar_recovery" if resolved else None}
        fixture["nodes"][0].update(attribute_names=["AXTopLevelUIElement"], attribute_names_status=success,
                                  native_read_recoveries={"AXTopLevelUIElement": trace})
        fixture["nodes"][0]["attributes"]["AXRole"] = "AXMenuItem"
        if outcome == "value":
            fixture["nodes"][0]["attributes"]["AXTopLevelUIElement"] = {"type": "AXUIElement", "id": 1}
        elif outcome == "absence":
            fixture["absent_attribute_values"] = [{"node": 0, "attribute": "AXTopLevelUIElement",
                "status": {**no_value, "native_read_recovery": trace}}]
        fixture["metadata_read_failures"] = [] if resolved else [{"node": 0,
            "attribute": "AXTopLevelUIElement", "stage": "attribute_read",
            "status": {**unsupported, "native_read_recovery": trace}}]
        fixture["serialization_warnings"] = []
        fixture.update(scalar_recovery_version=3, native_read_recovery_outcome_version=2,
                       native_read_recovery_attempts=1, native_read_recovery_successes=int(resolved),
                       native_read_recovery_value_successes=int(outcome == "value"),
                       native_read_recovery_absence_successes=int(outcome == "absence"),
                       native_scalar_retained_reference_attempts=int(queried),
                       native_scalar_retained_reference_withheld=int(not queried),
                       native_scalar_retained_reference_value_successes=int(outcome == "value"),
                       native_scalar_retained_reference_absence_successes=int(outcome == "absence"))
        view = project(fixture)
        actual = view["nodes"][0]
        assert actual["native_read_recoveries"]["AXTopLevelUIElement"] == trace
        assert actual["native_read_recoveries"]["AXTopLevelUIElement"]["queries"][1]["refresh"]["resolved"] is False
        assert ("AXTopLevelUIElement" in actual["attributes"]) == (outcome == "value")
        assert view["meta"]["scalar_recovery_version"] == 3
        for field in ("native_scalar_retained_reference_attempts", "native_scalar_retained_reference_withheld",
                      "native_scalar_retained_reference_value_successes", "native_scalar_retained_reference_absence_successes"):
            assert view["meta"][field] == fixture[field]
        assert view["meta"]["metadata_read_failure_count"] == int(not resolved)
        assert view["meta"]["native_metadata_failure_summary"] == {
            "attribute_unsupported": int(not resolved), "other_read_failures": 0}
        if actual["issues"]:
            assert actual["issues"][0]["status"]["native_read_recovery"] == trace
        count += 1
    # Native enumeration errors are unsupported reads too, but they do not
    # establish that any particular attribute was advertised by the app.
    for stage, advertised in (("attribute_read", True), ("attribute_names", None)):
        fixture = deepcopy(base)
        fixture["nodes"][0].update(attribute_names=["AXGrowArea"], attribute_names_status=success)
        fixture["metadata_failures"] = [{"node": 0, "attribute": "AXGrowArea", "stage": stage,
                                         "status": unsupported}]
        view = project(fixture)
        assert view["meta"]["native_metadata_failure_summary"] == {
            "attribute_unsupported": 1, "other_read_failures": 0}
        assert view["nodes"][0]["issues"][0]["native_attribute_advertised"] is advertised
        count += 1
    fixture["native_metadata_failure_summary"] = {"attribute_unsupported": 0, "other_read_failures": 1}
    try:
        project(fixture)
    except ValueError as error:
        assert "summary disagrees" in str(error)
    else:
        raise AssertionError("Inaccurate native failure summary was accepted")
    count += 1
    return count


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, help="Saved snapshot.json or its directory")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true", help="Run offline compatibility fixtures")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps({"offline_fixtures_passed": self_test()}))
    elif args.source is None:
        parser.error("source is required unless --self-test is supplied")
    else:
        generate(args.source, args.output)
