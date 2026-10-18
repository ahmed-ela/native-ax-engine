#!/usr/bin/env python3
"""Independently check graph, reference, selector, and leaf export invariants."""
import argparse
from collections import Counter, defaultdict, deque
import json
from pathlib import Path


def native_refs(value):
    if isinstance(value, dict):
        if value.get("type") == "AXUIElement":
            yield value.get("id")
        else:
            for item in value.values():
                yield from native_refs(item)
    elif isinstance(value, list):
        for item in value:
            yield from native_refs(item)


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def valid_status(state, attempts=True):
    return (isinstance(state, dict) and type(state.get("code")) is int and isinstance(state.get("name"), str) and
            (not attempts or integer(state.get("attempts"), 1) and state["attempts"] <= 3))


def check_resolution_kind(trace, expected, outcome_version, require, prefix):
    if outcome_version == 2:
        require(trace.get("resolution_kind") == expected,
                prefix + "resolution kind differs from native evidence")
    else:
        require("resolution_kind" not in trace,
                prefix + "explicit resolution kind requires recovery outcome version two")


DOCUMENTED_SCALARS = {"AXGrowArea": "AXUIElement", "AXTopLevelUIElement": "AXUIElement",
                      "AXFrame": "CGRect", "AXPosition": "CGPoint", "AXSize": "CGSize"}
GEOMETRY_KINDS = {"CGRect": "cgRect", "CGPoint": "cgPoint", "CGSize": "cgSize"}
RETAINED_SCALAR_COUNTERS = ("native_scalar_retained_reference_attempts", "native_scalar_retained_reference_withheld",
                            "native_scalar_retained_reference_value_successes", "native_scalar_retained_reference_absence_successes")


def scalar_retry_codes(version):
    return {-25200, -25204, -25205} if version in (2, 3) else {-25200, -25204}


def retained_refresh_eligible(refresh, snapshot, node, name):
    """Only an isolated CFEqual mismatch can select the retained original owner."""
    if name != "AXTopLevelUIElement" or node.get("attributes", {}).get("AXRole") not in {"AXMenu", "AXMenuItem"} or \
            node.get("attribute_statuses", {}).get("AXRole", {}).get("code") != 0:
        return False
    root_state = refresh.get("root_timeout_status")
    path, steps = node.get("selector_path"), refresh.get("steps")
    if (refresh.get("attempted") is not True or refresh.get("resolved") is not False or
            refresh.get("same_element") is not False or refresh.get("pid_status") is not None or refresh.get("pid") is not None or
            refresh.get("root_same_element") is not True or
            refresh.get("process_identity_matches") is not True or not valid_status(root_state) or
            root_state.get("code") != 0 or root_state.get("attempts") != 1 or
            not isinstance(path, list) or not isinstance(steps, list) or not steps or len(steps) > len(path)):
        return False
    by_id = {item.get("id"): item for item in snapshot.get("nodes", [])}
    cursor = snapshot.get("root_id")
    for index, step in enumerate(steps):
        if not isinstance(step, dict) or not isinstance(path[index], dict):
            return False
        selector, components = path[index], path[index].get("value_path")
        parts, state, pid_state = step.get("path_steps"), step.get("query_status"), step.get("pid_status")
        if (type(step.get("step")) is not int or step["step"] != index or step.get("attribute") != selector.get("attribute") or
                step.get("value_path") != components or not isinstance(components, list) or
                not isinstance(parts, list) or len(parts) != len(components) or
                not valid_status(state) or state.get("code") != 0 or state.get("attempts") != 1 or step.get("has_value") is not True or
                not integer(step.get("selected_cf_type_id"), 1) or step.get("selected_is_element") is not True or
                not valid_status(pid_state) or pid_state.get("code") != 0 or pid_state.get("attempts") != 1 or
                step.get("process_identity_matches") is not True):
            return False
        for component, part in zip(components, parts):
            if (not isinstance(part, dict) or not integer(part.get("container_cf_type_id"), 1) or
                    part.get("selected_has_value") is not True or part.get("resolved") is not True or
                    not (type(component) is int and type(part.get("index")) is int and part.get("index") == component and
                         part.get("component_kind") == "array_index" or isinstance(component, str) and
                         part.get("key") == component and part.get("component_kind") == "dictionary_key")):
                return False
        try:
            value = by_id[cursor]["attributes"][selector["attribute"]]
            for component in components:
                value = value[component]
            cursor = value["id"]
            expected_pid = by_id[cursor]["pid"]
        except (KeyError, TypeError, IndexError):
            return False
        if (not integer(step.get("pid"), 1) or not integer(step.get("expected_pid"), 1) or
                step["pid"] != expected_pid or step["expected_pid"] != expected_pid or
                step.get("same_element") is not (index < len(steps) - 1) or
                step.get("resolved") is not (index < len(steps) - 1)):
            return False
    return True


def check_retained_reference(proof, snapshot, node, require, prefix):
    require(isinstance(proof, dict), prefix + "retained original-reference validation is missing")
    if not isinstance(proof, dict):
        return False
    role, role_state = node.get("attributes", {}).get("AXRole"), node.get("attribute_statuses", {}).get("AXRole")
    require(proof.get("attempted") is True and proof.get("source") == "capture_registry" and
            integer(proof.get("node_id")) and proof.get("node_id") == node.get("id") and
            integer(proof.get("root_id")) and proof.get("root_id") == snapshot.get("root_id") and
            integer(proof.get("root_pid"), 1) and proof.get("root_pid") == snapshot.get("app", {}).get("pid") and
            integer(proof.get("expected_pid"), 1) and proof.get("expected_pid") == node.get("pid"),
            prefix + "retained proof is not bound to its original registry owner/root")
    require(role in {"AXMenu", "AXMenuItem"} and proof.get("owner_role") == role and
            valid_status(role_state) and role_state.get("code") == 0 and proof.get("owner_role_status") == role_state,
            prefix + "retained proof is not bound to the successful recorded menu role")
    require(integer(proof.get("expected_cf_type_id"), 1) and integer(proof.get("owner_cf_type_id"), 1) and
            type(proof.get("registry_binding_matches")) is bool and type(proof.get("resolved")) is bool,
            prefix + "retained registry reference/type outcome is not explicit")
    pid_successes = []
    for label in ("root", "owner"):
        state, actual = proof.get(label + "_pid_status"), proof.get(label + "_native_pid")
        flag = proof.get(label + "_process_identity_matches")
        require(state is None or valid_status(state) and state.get("attempts") == 1,
                prefix + "retained " + label + " PID query is not one native call")
        require(flag is None or type(flag) is bool, prefix + "retained " + label + " launch continuity is not explicit")
        successful_pid = isinstance(state, dict) and state.get("code") == 0
        require(type(actual) is int if successful_pid else actual is None,
                prefix + "retained " + label + " PID presence differs from its native status")
        expected = proof.get("root_pid" if label == "root" else "expected_pid")
        pid_successes.append(successful_pid and actual == expected and flag is True)
    expected_valid = (proof.get("registry_binding_matches") is True and
                      proof.get("owner_cf_type_id") == proof.get("expected_cf_type_id") and all(pid_successes))
    require(proof.get("resolved") is expected_valid, prefix + "retained-reference result differs from native binding/PID/launch evidence")
    require("reason" not in proof if expected_valid else isinstance(proof.get("reason"), str) and bool(proof["reason"]),
            prefix + "retained-reference failure explanation contradicts its outcome")
    root_state, owner_state = proof.get("root_pid_status"), proof.get("owner_pid_status")
    if root_state is None:
        require(owner_state is None, prefix + "retained owner PID read preceded the root PID read")
    elif not isinstance(root_state, dict) or root_state.get("code") != 0 or proof.get("root_native_pid") != proof.get("root_pid"):
        require(owner_state is None, prefix + "retained owner PID read continued after a failed/wrong root PID")
    if proof.get("registry_binding_matches") is not True or proof.get("owner_cf_type_id") != proof.get("expected_cf_type_id"):
        require(root_state is None and owner_state is None, prefix + "retained PID query ran after invalid registry/type binding")
    return expected_valid


def check_scalar_value(validation, expected_kind, require, prefix):
    require(isinstance(validation, dict), prefix + "scalar native type validation is missing")
    if not isinstance(validation, dict):
        return False
    require(validation.get("expected_value_kind") == expected_kind, prefix + "scalar validation has the wrong expected type")
    present, valid = validation.get("has_value"), validation.get("valid")
    require(type(present) is bool and type(valid) is bool, prefix + "scalar presence/type outcome is not explicit")
    require(integer(validation.get("cf_type_id"), 1) if present else validation.get("cf_type_id") is None,
            prefix + "scalar CF type evidence disagrees with native presence")
    require(integer(validation.get("expected_cf_type_id"), 1), prefix + "expected scalar CF type is invalid")
    subtype, decoded = validation.get("ax_value_type"), validation.get("ax_value_decoded")
    require(subtype is None or subtype in {"cgPoint", "cgSize", "cgRect", "cfRange", "axError", "illegal", "unknown"},
            prefix + "scalar AXValue subtype is invalid")
    require(decoded is None or type(decoded) is bool, prefix + "scalar decode evidence is invalid")
    expected_valid = (present is True and integer(validation.get("cf_type_id"), 1) and
                      validation.get("cf_type_id") == validation.get("expected_cf_type_id") and
                      (subtype is None and decoded is None if expected_kind == "AXUIElement" else
                       subtype == GEOMETRY_KINDS.get(expected_kind) and decoded is True))
    require(valid is expected_valid, prefix + "scalar validity differs from native type/decode evidence")
    if valid:
        require(present is True, prefix + "scalar type validated without a native value")
        require(subtype is None and decoded is None if expected_kind == "AXUIElement" else
                subtype == GEOMETRY_KINDS.get(expected_kind) and decoded is True,
                prefix + "scalar type/decode evidence does not prove the documented value")
    return valid is True


def check_encoded_scalar(value, expected_kind, require, prefix, snapshot=None, node=None, name=None):
    if expected_kind == "AXUIElement":
        valid = isinstance(value, dict) and value.get("type") == "AXUIElement" and integer(value.get("id"))
        if not valid and isinstance(value, dict) and value.get("type") == "AXUIElement" and "id" in value and value["id"] is None:
            cutoffs = snapshot.get("cutoffs", []) if isinstance(snapshot, dict) else []
            edges = snapshot.get("all_reference_edges", []) if isinstance(snapshot, dict) else []
            matches = [edge for edge in cutoffs if isinstance(edge, dict) and isinstance(node, dict) and
                       edge.get("from") == node.get("id") and edge.get("attribute") == name and edge.get("to") is None and
                       edge.get("value_path") == [] and edge.get("resolution") == value.get("resolution") and edge in edges]
            if len(matches) == 1:
                cutoff = matches[0]
                if value.get("resolution") == "pid_read_failed":
                    state = cutoff.get("status")
                    valid = valid_status(state, attempts=False) and state.get("code") != 0
                elif value.get("resolution") == "outside_selected_process":
                    valid = integer(value.get("external_pid"), 1) and cutoff.get("external_pid") == value["external_pid"]
        require(valid, prefix + "scalar native reference is neither a captured element nor an evidenced unresolved reference")
    else:
        fields = {"CGRect": ("x", "y", "width", "height"), "CGPoint": ("x", "y"), "CGSize": ("width", "height")}[expected_kind]
        require(isinstance(value, dict) and value.get("type") == expected_kind and all(
            type(value.get(field)) in (int, float) or
            isinstance(value.get(field), dict) and value[field].get("type") == "nonfinite_number" and
            value[field].get("value") in {"nan", "inf", "-inf"} for field in fields),
            prefix + "encoded geometry differs from its documented scalar type")


def check_array_recovery(trace, node, name, final, initial, require, prefix, outcome_version=None):
    success = trace.get("resolved") is True
    check_resolution_kind(trace, "value" if success else "unresolved", outcome_version, require, prefix)
    initial_valid = initial.get("code") in {-25200, -25204, -25205}
    require(trace.get("method") == "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues", prefix + "unsupported array method")
    before_state = trace.get("count_before_status", {})
    after_state = trace.get("count_after_status", {})
    for label, state in [("count-before", before_state)] + ([("count-after", after_state)] if "count_after_status" in trace else []):
        require(isinstance(state, dict) and integer(state.get("code"), -25214) and
                integer(state.get("attempts"), 1) and state.get("attempts", 4) <= 3,
                prefix + label + " status/attempts are invalid")
    before_state = before_state if isinstance(before_state, dict) else {}
    after_state = after_state if isinstance(after_state, dict) else {}
    expected = trace.get("count_before")
    pages = trace.get("pages", [])
    require(isinstance(pages, list), prefix + "pages must be an array")
    cursor, all_pages_success = 0, True
    if isinstance(pages, list):
        for index, page in enumerate(pages):
            if not isinstance(page, dict):
                require(False, prefix + "malformed page record")
                all_pages_success = False
                continue
            page_state = page.get("status", {})
            valid = (integer(expected) and page.get("index") == cursor and
                     integer(page.get("requested"), 1) and page.get("requested") == min(256, expected - cursor))
            require(valid, prefix + "page indexes/requests do not describe a bounded contiguous read")
            require(isinstance(page_state, dict) and type(page_state.get("code")) is int and
                    integer(page_state.get("attempts"), 1) and page_state.get("attempts", 4) <= 3,
                    prefix + "page status/attempts are invalid")
            page_success = isinstance(page_state, dict) and page_state.get("code") == 0
            if "has_value" in page or "returned_count" in page:
                require(type(page.get("has_value")) is bool and
                        (integer(page.get("returned_count")) or page.get("returned_count") is None),
                        prefix + "page value/length evidence is malformed")
                if success or index < len(pages) - 1 or trace.get("reason") != "Native array page failed or its length changed during reading.":
                    require(page.get("has_value") is True and page.get("returned_count") == page.get("requested"),
                            prefix + "successful page lacks an actual array of the requested length")
                elif index == len(pages) - 1:
                    require(not page_success or page.get("has_value") is not True or page.get("returned_count") != page.get("requested"),
                            prefix + "failed-page reason contradicts successful complete page evidence")
            require(page_success or index == len(pages) - 1, prefix + "read continued after a failed page")
            all_pages_success &= page_success
            if integer(page.get("requested"), 1):
                cursor += page["requested"]
    if success:
        require(type(final.get("code")) is int and final.get("code") == 0, prefix + "resolved recovery retained an error")
        require(before_state.get("code") == 0 and after_state.get("code") == 0 and integer(expected) and
                type(trace.get("count_after")) is int and trace.get("count_after") == expected,
                prefix + "successful recovery lacks matching successful native counts")
        value = node.get("attributes", {}).get(name)
        require(isinstance(value, list) and integer(trace.get("returned_count")) and
                trace.get("returned_count") == expected and len(value) == expected and
                cursor == expected and all_pages_success, prefix + "returned array/page lengths disagree")
        require("reason" not in trace, prefix + "successful recovery also records a failure reason")
    else:
        require(initial_valid and final.get("code") == initial.get("code"), prefix + "failed recovery replaced its original native error")
        require(name not in node.get("attributes", {}), prefix + "failed recovery fabricated an attribute value")
        require("returned_count" not in trace, prefix + "failed recovery claims a returned array")
        reason = trace.get("reason")
        if reason == "Native array count could not be read.":
            consistent = "count_before" not in trace and not pages and "count_after_status" not in trace
        elif reason == "Native array count was negative.":
            consistent = before_state.get("code") == 0 and type(expected) is int and expected < 0 and not pages and "count_after_status" not in trace
        elif reason == "Native array page failed or its length changed during reading.":
            # Older traces cannot distinguish a nil/short successful native page from a failed page.
            consistent = before_state.get("code") == 0 and integer(expected, 1) and bool(pages) and "count_after_status" not in trace
        elif reason == "Native array count changed or could not be confirmed after reading.":
            consistent = before_state.get("code") == 0 and integer(expected) and cursor == expected and all_pages_success
            # Count failure is explicit; a successful count can still report a different value or nil.
            consistent = consistent and "count_after_status" in trace and (after_state.get("code") != 0 or trace.get("count_after") != expected)
        else:
            consistent = False
        require(consistent, prefix + "failure reason does not match the recorded query sequence")


def check_bulk_query(query, name, require, prefix, outcome_version=None, scalar_kind=None):
    require(query.get("method") == "AXUIElementCopyMultipleAttributeValues", prefix + "unsupported bulk method")
    attributes = query.get("query_attributes")
    valid_names = isinstance(attributes, list) and bool(attributes) and all(isinstance(item, str) for item in attributes)
    require(valid_names and len(set(attributes)) == len(attributes), prefix + "bulk requested names are invalid/ambiguous")
    require(type(query.get("options")) is int and query.get("options") == 0, prefix + "bulk query did not use options zero")
    state = query.get("query_status", {})
    require(valid_status(state) and state.get("attempts") == 1, prefix + "bulk query must record one native call")
    has_array, count, slot = query.get("has_array"), query.get("returned_slot_count"), query.get("slot_index")
    require(type(has_array) is bool and (integer(count) or count is None), prefix + "bulk array/cardinality evidence is malformed")
    require(integer(slot) and valid_names and slot < len(attributes) and attributes[slot] == name and query.get("slot_attribute") == name,
            prefix + "bulk slot is not bound to its requested attribute")
    shape = (isinstance(state, dict) and state.get("code") == 0 and has_array is True and valid_names and
             type(count) is int and count == len(attributes) and integer(slot) and slot < len(attributes))
    require(has_array is True or count is None, prefix + "bulk query reports a count without an array")
    kind, decoded, item_state = query.get("item_kind"), query.get("item_error_decoded"), query.get("item_status")
    require(kind in {"value", "null", "ax_error", "malformed"}, prefix + "bulk slot kind is invalid")
    require(type(decoded) is bool, prefix + "bulk item error decode flag is not explicit")
    if kind == "ax_error":
        require(shape and integer(query.get("cf_type_id"), 1), prefix + "error envelope lacks a valid native slot")
        require(valid_status(item_state, attempts=False) if decoded is True else item_state is None,
                prefix + "bulk item error does not match its decode result")
    else:
        require(decoded is False and item_state is None, prefix + "non-error slot claims a decoded native error")
    if kind in {"value", "null"}:
        require(shape and integer(query.get("cf_type_id"), 1), prefix + "bulk slot lacks a successfully returned native value")
    elif kind == "malformed":
        require(not shape, prefix + "malformed bulk result contradicts its successful array/cardinality evidence")
    resolved = query.get("resolved")
    require(type(resolved) is bool, prefix + "bulk resolution is not a boolean")
    native_absence = (outcome_version == 2 and shape and kind == "ax_error" and decoded is True and
                      isinstance(item_state, dict) and item_state.get("code") == -25212 and item_state.get("name") == "noValue")
    typed_value = check_scalar_value(query.get("value_validation"), scalar_kind, require, prefix) if scalar_kind and kind == "value" else True
    if scalar_kind and kind == "value" and isinstance(query.get("value_validation"), dict):
        require(query["value_validation"].get("has_value") is True and query["value_validation"].get("cf_type_id") == query.get("cf_type_id"),
                prefix + "scalar validation is not bound to the actual bulk slot type")
    expected_kind = "absence" if native_absence else "value" if shape and kind == "value" and typed_value else "unresolved"
    check_resolution_kind(query, expected_kind, outcome_version, require, prefix)
    require(resolved is (expected_kind != "unresolved"),
            prefix + "bulk recovery resolved without an actual value or decoded native absence")
    require("reason" not in query if resolved else isinstance(query.get("reason"), str) and bool(query["reason"]),
            prefix + "bulk failure explanation contradicts its outcome")
    return resolved is True


def check_scalar_recovery(trace, snapshot, node, name, initial, require, prefix, outcome_version):
    expected_kind = DOCUMENTED_SCALARS[name]
    require(trace.get("method") == "native_scalar_recovery" and trace.get("attribute") == name and
            trace.get("expected_value_kind") == expected_kind and trace.get("query_method") == "AXUIElementCopyAttributeValue",
            prefix + "fresh scalar method/name/type is not bound to its documented attribute")
    require(initial.get("code") in scalar_retry_codes(snapshot.get("scalar_recovery_version")) and trace.get("initial_status") == initial,
            prefix + "fresh scalar retry is not bound to its original retryable status")
    refresh = trace.get("refresh")
    require(isinstance(refresh, dict), prefix + "fresh scalar reference evidence is missing")
    if not isinstance(refresh, dict):
        return
    path = node.get("selector_path")
    valid_path = (isinstance(path, list) and all(isinstance(part, dict) and isinstance(part.get("attribute"), str) and
                  isinstance(part.get("value_path"), list) and all(integer(component) or isinstance(component, str)
                  for component in part["value_path"]) for part in path))
    require(valid_path, prefix + "recorded scalar selector path is malformed")
    if not valid_path:
        return
    by_id = {n.get("id"): n for n in snapshot.get("nodes", [])}
    cursor = snapshot.get("root_id")
    try:
        for selector in path:
            value = by_id[cursor]["attributes"][selector["attribute"]]
            for component in selector["value_path"]:
                value = value[component]
            if not isinstance(value, dict) or value.get("type") != "AXUIElement" or not integer(value.get("id")):
                raise ValueError("Recorded selector is not a native element reference")
            cursor = value["id"]
        require(cursor == node.get("id"), prefix + "recorded scalar selector does not resolve the original owner")
    except (KeyError, TypeError, IndexError, ValueError):
        require(False, prefix + "recorded scalar selector cannot resolve through the captured graph")
    root_identity, owner_identity = snapshot.get("app", {}), node.get("process_identity", {})
    require(isinstance(root_identity, dict) and isinstance(root_identity.get("launch_date"), str) and bool(root_identity["launch_date"]) and
            isinstance(owner_identity, dict) and owner_identity.get("pid") == node.get("pid") and
            isinstance(owner_identity.get("launch_date"), str) and bool(owner_identity["launch_date"]),
            prefix + "fresh scalar root/owner lacks recorded process launch identity")
    require(refresh.get("attempted") is True and refresh.get("selector_path") == path and
            integer(refresh.get("root_pid"), 1) and refresh.get("root_pid") == snapshot.get("app", {}).get("pid") and
            integer(refresh.get("expected_pid"), 1) and refresh.get("expected_pid") == node.get("pid"),
            prefix + "fresh scalar reference is not bound to the saved path/root/owner")
    for flag in ("process_identity_matches", "root_same_element", "same_element", "resolved"):
        require(type(refresh.get(flag)) is bool, prefix + "fresh scalar identity outcome is not explicit")
    root_status = refresh.get("root_timeout_status")
    require(root_status is None or valid_status(root_status) and root_status.get("attempts") == 1,
            prefix + "fresh root timeout is not one native call")
    steps = refresh.get("steps")
    valid_steps = isinstance(steps, list) and len(steps) <= len(path) and all(isinstance(step, dict) for step in steps)
    require(valid_steps, prefix + "fresh scalar path steps are malformed or exceed the saved selector")
    cursor = snapshot.get("root_id")
    all_steps_resolved = True
    for index, step in enumerate(steps if valid_steps else []):
        selector = path[index]
        components = selector.get("value_path", [])
        require(type(step.get("step")) is int and step.get("step") == index and step.get("attribute") == selector.get("attribute") and step.get("value_path") == components,
                prefix + "fresh scalar path step differs from its recorded selector")
        state = step.get("query_status")
        require(valid_status(state) and state.get("attempts") == 1 and type(step.get("has_value")) is bool,
                prefix + "fresh path attribute query is not one explicit native read")
        for flag in ("selected_is_element", "same_element", "resolved"):
            require(type(step.get(flag)) is bool, prefix + "fresh path identity outcome is not explicit")
        require("process_identity_matches" in step and (step.get("process_identity_matches") is None or
                type(step.get("process_identity_matches")) is bool), prefix + "fresh prefix launch identity evidence is not explicit")
        if step.get("process_identity_matches") is False:
            require(refresh.get("process_identity_matches") is False,
                    prefix + "failed prefix launch continuity contradicts the refresh process summary")
        paths = step.get("path_steps")
        valid_paths = isinstance(paths, list) and len(paths) <= len(components) and all(isinstance(item, dict) for item in paths)
        require(valid_paths, prefix + "fresh native value path is malformed")
        all_components_resolved = True
        for pi, part in enumerate(paths if valid_paths else []):
            component = components[pi]
            kind = part.get("component_kind")
            require(kind in {"array_index", "dictionary_key", "unsupported"} and integer(part.get("container_cf_type_id"), 1) and
                    type(part.get("selected_has_value")) is bool and type(part.get("resolved")) is bool,
                    prefix + "fresh value-path component lacks native container/presence evidence")
            if kind == "array_index":
                require(type(component) is int and type(part.get("index")) is int and part.get("index") == component,
                        prefix + "fresh array component selected a different index")
            elif kind == "dictionary_key":
                require(isinstance(component, str) and part.get("key") == component, prefix + "fresh dictionary component selected a different key")
            else:
                require(part.get("resolved") is False and part.get("selected_has_value") is False,
                        prefix + "unsupported value-path component claims success")
            require(part.get("resolved") is (part.get("selected_has_value") is True), prefix + "fresh value-path outcome contradicts native presence")
            require(part.get("resolved") is True or pi == len(paths) - 1, prefix + "fresh value path continued after failure")
            if part.get("resolved") is not True:
                require(isinstance(part.get("reason"), str) and bool(part["reason"]), prefix + "failed value-path component lacks explanation")
            all_components_resolved &= part.get("resolved") is True
        expected_owner = None
        try:
            value = by_id[cursor]["attributes"][selector["attribute"]]
            for component in components:
                value = value[component]
            cursor = value["id"]
            expected_owner = by_id[cursor]
        except (KeyError, TypeError, IndexError):
            require(False, prefix + "saved selector prefix has no native captured owner")
        pid_state = step.get("pid_status")
        require(pid_state is None or valid_status(pid_state) and pid_state.get("attempts") == 1,
                prefix + "fresh prefix PID query is not one native call")
        if step.get("resolved") is True:
            require(isinstance(state, dict) and state.get("code") == 0 and step.get("has_value") is True and
                    valid_paths and len(paths) == len(components) and all_components_resolved and
                    integer(step.get("selected_cf_type_id"), 1) and step.get("selected_is_element") is True and
                    step.get("same_element") is True and isinstance(expected_owner, dict) and
                    step.get("process_identity_matches") is True and
                    integer(step.get("expected_pid"), 1) and integer(step.get("pid"), 1) and
                    step.get("expected_pid") == expected_owner.get("pid") and step.get("pid") == step.get("expected_pid") and
                    isinstance(pid_state, dict) and pid_state.get("code") == 0,
                    prefix + "successful fresh prefix lacks exact native element/PID/path evidence")
        else:
            require(index == len(steps) - 1, prefix + "fresh path continued after an unresolved native prefix")
        all_steps_resolved &= step.get("resolved") is True
    pid_state = refresh.get("pid_status")
    require(pid_state is None or valid_status(pid_state) and pid_state.get("attempts") == 1,
            prefix + "fresh owner PID query is not one native call")
    refreshed = refresh.get("resolved") is True
    if refreshed:
        require(refresh.get("process_identity_matches") is True and refresh.get("root_same_element") is True and
                isinstance(root_status, dict) and root_status.get("code") == 0 and valid_steps and
                len(steps) == len(path) and all_steps_resolved and refresh.get("same_element") is True and
                isinstance(pid_state, dict) and pid_state.get("code") == 0 and integer(refresh.get("pid"), 1) and refresh.get("pid") == node.get("pid"),
                prefix + "fresh scalar owner lacks complete native equality/process/path evidence")
    else:
        require(isinstance(refresh.get("reason"), str) and bool(refresh["reason"]), prefix + "failed fresh owner lacks explanation")
    query_status, validation = trace.get("query_status"), trace.get("value_validation")
    continuity = trace.get("query_process_identity_matches")
    retained_selected, retained_after_valid = False, False
    if snapshot.get("scalar_recovery_version") == 3:
        target = trace.get("query_target")
        require("query_target" in trace and target in {None, "fresh_exact_reference", "retained_original_reference"} and
                "retained_reference" in trace and "query_retained_reference_validation" in trace,
                prefix + "version-three scalar query target/proofs are missing or invalid")
        before, after = trace.get("retained_reference"), trace.get("query_retained_reference_validation")
        eligible = retained_refresh_eligible(refresh, snapshot, node, name)
        if refreshed:
            require(target == "fresh_exact_reference" and before is None and after is None,
                    prefix + "successful fresh refresh improperly substituted a retained owner")
        elif eligible:
            before_valid = check_retained_reference(before, snapshot, node, require, prefix + "Before query: ")
            if isinstance(before, dict):
                require(all(step.get("selected_cf_type_id") == before.get("expected_cf_type_id") for step in refresh["steps"]),
                        prefix + "fresh prefix native types differ from the retained native element type")
            if before_valid:
                retained_selected = True
                require(target == "retained_original_reference", prefix + "query is not bound to the retained original owner")
                retained_after_valid = check_retained_reference(after, snapshot, node, require, prefix + "After query: ")
                if isinstance(after, dict):
                    require(after.get("expected_cf_type_id") == before.get("expected_cf_type_id"),
                            prefix + "retained native expected type changed across the query")
            else:
                require(target is None and after is None, prefix + "retained query ran after failed original-reference validation")
        else:
            require(target is None and before is None and after is None,
                    prefix + "retained retry was attempted outside an isolated menu-prefix equality mismatch")
    else:
        require(not any(key in trace for key in ("query_target", "retained_reference", "query_retained_reference_validation")),
                prefix + "retained query-target evidence requires scalar recovery version three")
    if not refreshed and not retained_selected:
        require(query_status is None and validation is None and continuity is None, prefix + "scalar query ran after failed reference refresh")
        expected_resolution = "unresolved"
    else:
        require(valid_status(query_status) and query_status.get("attempts") == 1, prefix + "fresh scalar query is not one native call")
        require(type(continuity) is bool, prefix + "post-query process identity continuity is not explicit")
        typed = check_scalar_value(validation, expected_kind, require, prefix)
        if retained_selected and isinstance(validation, dict):
            require(validation.get("expected_cf_type_id") == trace["retained_reference"].get("expected_cf_type_id"),
                    prefix + "scalar query type evidence differs from its retained native reference type")
        state = query_status if isinstance(query_status, dict) else {}
        expected_resolution = ("unresolved" if continuity is not True or retained_selected and not retained_after_valid else
                               "absence" if state.get("code") == -25212 and state.get("name") == "noValue" else
                               "value" if state.get("code") == 0 and typed else "unresolved")
    check_resolution_kind(trace, expected_resolution, outcome_version, require, prefix)
    require(trace.get("resolved") is (expected_resolution != "unresolved"), prefix + "fresh scalar outcome contradicts native evidence")
    require("reason" not in trace if expected_resolution != "unresolved" else
            isinstance(trace.get("reason"), str) and bool(trace["reason"]), prefix + "fresh scalar failure reason contradicts its outcome")


def check_metadata_recovery(trace, node, name, final, initial, require, prefix, outcome_version=None, snapshot=None):
    queries = trace.get("queries")
    valid = isinstance(queries, list) and 1 <= len(queries) <= 2 and all(isinstance(query, dict) for query in queries)
    require(valid, prefix + "metadata recovery requires one or two ordered native queries")
    if not valid:
        return
    require(queries[0].get("method") == "AXUIElementCopyMultipleAttributeValues", prefix + "first alternate query is not the bulk native read")
    scalar = snapshot is not None and snapshot.get("scalar_recovery_version") in (1, 2, 3) and name in DOCUMENTED_SCALARS
    scalar_kind = DOCUMENTED_SCALARS[name] if scalar else None
    retry_eligible = scalar and initial.get("code") in scalar_retry_codes(snapshot.get("scalar_recovery_version"))
    if scalar:
        expected_documented = {"attribute": name, "expected_value_kind": scalar_kind, "array_query_skipped": True,
                               "scalar_retry_eligible": retry_eligible}
        documented = trace.get("documented_scalar")
        require(isinstance(documented, dict) and type(documented.get("array_query_skipped")) is bool and
                type(documented.get("scalar_retry_eligible")) is bool and documented == expected_documented,
                prefix + "documented scalar routing evidence is incorrect")
    else:
        require("documented_scalar" not in trace, prefix + "scalar routing requires its supported version and documented attribute")
    bulk_success = check_bulk_query(queries[0], name, require, prefix, outcome_version, scalar_kind)
    if scalar:
        require(len(queries) == (2 if not bulk_success and retry_eligible else 1),
                prefix + "documented scalar retries do not follow the bounded type/error routing")
    if len(queries) == 2:
        require(not bulk_success, prefix + "alternate query continued after successful bulk recovery")
        array = queries[1]
        require(array.get("initial_status") == initial, prefix + "array query lost the original direct-read status")
        require(type(array.get("resolved")) is bool, prefix + "array query resolution is not explicit")
        if scalar:
            check_scalar_recovery(array, snapshot, node, name, initial, require, prefix, outcome_version)
        else:
            check_array_recovery(array, node, name, final, initial, require, prefix, outcome_version)
    expected_success = queries[-1].get("resolved") is True
    require(trace.get("resolved") is expected_success, prefix + "composite outcome differs from its final native query")
    expected_kind = queries[-1].get("resolution_kind") if outcome_version == 2 else "value" if expected_success else "unresolved"
    check_resolution_kind(trace, expected_kind, outcome_version, require, prefix)
    expected_method = queries[-1].get("method") if expected_success else None
    require("selected_method" in trace and trace.get("selected_method") == expected_method,
            prefix + "composite selected method does not identify the successful final query")
    if scalar and trace.get("resolution_kind") == "value":
        check_encoded_scalar(node.get("attributes", {}).get(name), scalar_kind, require, prefix, snapshot, node, name)


def check_action_recovery(trace, node, require, prefix, outcome_version=None):
    check_resolution_kind(trace, "value" if trace.get("resolved") is True else "unresolved", outcome_version, require, prefix)
    state = trace.get("query_status", {})
    require(valid_status(state) and state.get("attempts") == 1, prefix + "action recovery must record one native retry")
    require(type(trace.get("has_array")) is bool and (integer(trace.get("returned_count")) or trace.get("returned_count") is None),
            prefix + "action array/cardinality evidence is malformed")
    names_valid, strings_count = trace.get("names_valid"), trace.get("strings_count")
    require(type(names_valid) is bool and (integer(strings_count) or strings_count is None),
            prefix + "native action string-array validation is not explicit")
    if trace.get("has_array") is True:
        require(integer(trace.get("returned_count")) and integer(strings_count) and strings_count <= trace.get("returned_count"),
                prefix + "action string-count evidence disagrees with the returned array")
        require(names_valid is (integer(strings_count) and strings_count == trace.get("returned_count")),
                prefix + "action array validity differs from its actual string-slot count")
    else:
        require(trace.get("returned_count") is None and strings_count is None and names_valid is False,
                prefix + "action query reports names/counts without a native array")
    names = node.get("action_names")
    require(isinstance(names, list) and all(isinstance(name, str) for name in names), prefix + "action names are not native strings")
    if trace.get("resolved") is True:
        require(state.get("code") == 0 and trace.get("has_array") is True and names_valid is True and integer(trace.get("returned_count")) and
                isinstance(names, list) and trace["returned_count"] == len(names), prefix + "action recovery lacks actual successful names")
    else:
        require(state.get("code") != 0 or trace.get("has_array") is not True or names_valid is not True or trace.get("returned_count") is None,
                prefix + "unresolved action trace contradicts a successful returned array")
        require(names == [], prefix + "failed action recovery fabricated advertised actions")


def recovery_checks(snapshot, nodes, by_id, require):
    """Check recorded recovery evidence, without making native queries."""
    version = snapshot.get("metadata_classification_version")
    outcome_version = snapshot.get("native_read_recovery_outcome_version")
    scalar_version = snapshot.get("scalar_recovery_version")
    if scalar_version is not None:
        require(type(scalar_version) is int and scalar_version in (1, 2, 3), "Unsupported scalar recovery version")
    if scalar_version in (1, 2, 3):
        require(outcome_version == 2, "Scalar recovery requires explicit recovery outcome v2")
        records = snapshot.get("metadata_read_failures")
        require(isinstance(records, list) and all(isinstance(item, dict) for item in records), "Scalar recovery lacks native metadata failures")
        if isinstance(records, list) and all(isinstance(item, dict) for item in records):
            unsupported = sum(isinstance(item.get("status"), dict) and item["status"].get("code") == -25205 for item in records)
            summary = snapshot.get("native_metadata_failure_summary")
            expected_summary = {"attribute_unsupported": unsupported, "other_read_failures": len(records) - unsupported}
            require(isinstance(summary, dict) and set(summary) == set(expected_summary) and
                    all(type(summary.get(key)) is int for key in expected_summary) and summary == expected_summary,
                    "Native unsupported/other metadata summary differs from exact retained failure records")
    elif "native_metadata_failure_summary" in snapshot:
        require(False, "Native scalar metadata summary requires a supported scalar recovery version")
    if scalar_version != 3:
        require(not any(key in snapshot for key in RETAINED_SCALAR_COUNTERS), "Retained scalar counters require scalar recovery version three")
    if outcome_version is not None:
        require(type(outcome_version) is int and outcome_version == 2, "Unsupported native recovery outcome version")
    if outcome_version == 2:
        require(version == 2, "Native recovery outcome v2 requires metadata classification v2")
    elif any(key in snapshot for key in ("native_read_recovery_value_successes", "native_read_recovery_absence_successes")):
        require(False, "Split recovery success counters require recovery outcome version two")
    if version is not None:
        require(type(version) is int and version == 2, "Unsupported metadata classification version")
    if version == 2:
        combined = snapshot.get("metadata_failures")
        reads = snapshot.get("metadata_read_failures")
        warnings = snapshot.get("serialization_warnings")
        require(all(isinstance(items, list) for items in (combined, reads, warnings)),
                "Metadata v2 requires combined, read-failure and serialization-warning arrays")
        if isinstance(combined, list) and all(isinstance(item, dict) for item in combined):
            require(reads == [item for item in combined if item.get("stage") != "serialization"],
                    "Metadata read failures are not the ordered legacy-array partition")
            require(warnings == [item for item in combined if item.get("stage") == "serialization"],
                    "Serialization warnings are not the ordered legacy-array partition")
            for item in combined:
                owner = by_id.get(item.get("node"), {})
                name = item.get("attribute")
                state = item.get("status", {})
                if item.get("stage") == "serialization":
                    require(isinstance(state, dict) and state.get("code") == 0 and
                            owner.get("attribute_statuses", {}).get(name, {}).get("code") == 0 and
                            name in owner.get("attributes", {}) and isinstance(item.get("reason"), str) and bool(item["reason"]),
                            f"Serialization warning is not a successfully read value on #{item.get('node')} {name}")
                else:
                    recorded = (owner.get("attribute_statuses", {}).get(name) if item.get("stage") == "attribute_read"
                                else owner.get(name + "_status") if isinstance(name, str) and item.get("stage") == "enumeration" else None)
                    require(recorded is not None and state == recorded,
                            f"Metadata read failure has no matching native status on #{item.get('node')} {name}")
                    require(isinstance(state, dict) and (state.get("code") != 0 or
                            (isinstance(item.get("reason"), str) and bool(item["reason"]))),
                            f"Successful metadata read lacks a malformed-return explanation on #{item.get('node')} {name}")
        else:
            require(False, "Metadata failure records are malformed")

    attempts, successes, value_successes, absence_successes = 0, 0, 0, 0
    retained_counts = dict.fromkeys(RETAINED_SCALAR_COUNTERS, 0)
    has_recovery_schema = version == 2 or any(key in snapshot for key in
                                             ("native_read_recovery_attempts", "native_read_recovery_successes"))
    hierarchy_names = set(snapshot.get("scope", {}).get("hierarchy_attributes", []))
    for node in nodes:
        identifier = node.get("id")
        recorded = node.get("native_read_recoveries", {})
        statuses = node.get("attribute_statuses", {})
        status_traces = {name: state["native_read_recovery"] for name, state in statuses.items()
                         if isinstance(state, dict) and "native_read_recovery" in state}
        action_status = node.get("action_names_status", {})
        if isinstance(action_status, dict) and "native_read_recovery" in action_status:
            status_traces["action_names"] = action_status["native_read_recovery"]
        if has_recovery_schema or recorded or status_traces:
            require(isinstance(recorded, dict) and recorded == status_traces,
                    f"Native recovery map and attribute/action status traces differ on #{identifier}")
        if not isinstance(recorded, dict):
            continue
        for name, trace in recorded.items():
            attempts += 1
            prefix = f"Native read recovery on #{identifier} {name}: "
            if not isinstance(trace, dict):
                require(False, prefix + "trace is not an object")
                continue
            success = trace.get("resolved") is True
            successes += int(success)
            absence = outcome_version == 2 and trace.get("resolution_kind") == "absence"
            value_successes += int(success and not absence)
            absence_successes += int(success and absence)
            require(type(trace.get("resolved")) is bool, prefix + "resolved must be a boolean")
            initial = trace.get("initial_status", {})
            final = action_status if name == "action_names" else statuses.get(name, {})
            if not isinstance(initial, dict) or not isinstance(final, dict):
                require(False, prefix + "initial/final status is not an object")
                continue
            initial_valid = valid_status(initial) and initial.get("code") in {-25200, -25204, -25205}
            require(initial_valid and set(initial) == {"code", "name", "attempts"}, prefix + "bare original failure/attempts are invalid")
            require(valid_status(final) and final.get("attempts") == initial.get("attempts"), prefix + "original attempt count changed")
            if success and absence:
                require(name != "action_names" and final.get("code") == -25212 and final.get("name") == "noValue",
                        prefix + "confirmed absence did not retain the native noValue status")
                require(name not in node.get("attributes", {}), prefix + "confirmed absence fabricated an attribute value")
            elif success:
                require(final.get("code") == 0, prefix + "resolved recovery retained an error")
                if name != "action_names":
                    require(name in node.get("attributes", {}) and node["attributes"][name] is not None,
                            prefix + "resolved recovery has no actual attribute value")
            else:
                require({key: value for key, value in final.items() if key != "native_read_recovery"} == initial,
                        prefix + "unsuccessful recovery changed the original native failure status")
                if name != "action_names":
                    require(name not in node.get("attributes", {}), prefix + "failed recovery fabricated an attribute value")
            method = trace.get("method")
            if scalar_version == 3 and method == "native_metadata_recovery":
                for query in trace.get("queries", []) if isinstance(trace.get("queries"), list) else []:
                    if not isinstance(query, dict) or query.get("method") != "native_scalar_recovery":
                        continue
                    if query.get("query_target") == "retained_original_reference":
                        retained_counts[RETAINED_SCALAR_COUNTERS[0]] += 1
                        retained_counts[RETAINED_SCALAR_COUNTERS[2]] += int(query.get("resolved") is True and query.get("resolution_kind") == "value")
                        retained_counts[RETAINED_SCALAR_COUNTERS[3]] += int(query.get("resolved") is True and query.get("resolution_kind") == "absence")
                    elif query.get("retained_reference") is not None and query.get("query_target") is None:
                        retained_counts[RETAINED_SCALAR_COUNTERS[1]] += 1
            if method == "native_action_names_recovery":
                require(name == "action_names", prefix + "action-name recovery is attached to an attribute")
                require(initial.get("code") == -25200, prefix + "action-name retry was not triggered by native failure")
                check_action_recovery(trace, node, require, prefix, outcome_version)
            else:
                require(name != "action_names" and name in node.get("attribute_names", []) and name not in hierarchy_names,
                        prefix + "metadata recovery is not bound to an advertised non-hierarchy attribute")
                if method == "native_metadata_recovery":
                    check_metadata_recovery(trace, node, name, final, initial, require, prefix, outcome_version, snapshot)
                elif method == "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues":
                    require(scalar_version not in (1, 2, 3) or name not in DOCUMENTED_SCALARS,
                            prefix + "documented scalar incorrectly uses array-count recovery")
                    check_array_recovery(trace, node, name, final, initial, require, prefix, outcome_version)
                else:
                    require(False, prefix + "unsupported recovery method")
            if version == 2:
                stage = "enumeration" if name == "action_names" else "attribute_read"
                records = snapshot.get("metadata_read_failures", [])
                failures = [item for item in records if isinstance(item, dict) and item.get("node") == identifier and
                            item.get("attribute") == name and item.get("stage") == stage] if isinstance(records, list) else []
                require(not failures if success else len(failures) == 1 and failures[0].get("status") == final,
                        prefix + "final metadata failure disagrees with recovery outcome")
    if scalar_version == 3:
        for key, count in retained_counts.items():
            require(integer(snapshot.get(key)) and snapshot.get(key) == count,
                    "Retained scalar summary differs from canonical query evidence: " + key)
    if has_recovery_schema:
        require(type(snapshot.get("native_read_recovery_attempts")) is int and snapshot.get("native_read_recovery_attempts") == attempts,
                "Native read recovery attempt summary differs from per-node traces")
        require(type(snapshot.get("native_read_recovery_successes")) is int and snapshot.get("native_read_recovery_successes") == successes,
                "Native read recovery success summary differs from per-node traces")
    if outcome_version == 2:
        require(integer(snapshot.get("native_read_recovery_value_successes")) and
                snapshot.get("native_read_recovery_value_successes") == value_successes,
                "Native value recovery success summary differs from per-node traces")
        require(integer(snapshot.get("native_read_recovery_absence_successes")) and
                snapshot.get("native_read_recovery_absence_successes") == absence_successes,
                "Native absence recovery success summary differs from per-node traces")
        require(value_successes + absence_successes == snapshot.get("native_read_recovery_successes"),
                "Native value/absence recovery counts do not sum to total successes")
        absent = snapshot.get("absent_attribute_values")
        require(isinstance(absent, list), "Recovery outcome v2 requires native absent-attribute records")
        expected_absent = {(node.get("id"), name): state for node in nodes
                           for name, state in node.get("attribute_statuses", {}).items()
                           if isinstance(state, dict) and state.get("code") == -25212}
        seen_absent = set()
        for item in absent if isinstance(absent, list) else []:
            if not isinstance(item, dict) or not integer(item.get("node")) or not isinstance(item.get("attribute"), str):
                require(False, "Native absent-attribute record is malformed")
                continue
            key = (item["node"], item["attribute"])
            require(key not in seen_absent, "Native absent-attribute record is duplicated")
            seen_absent.add(key)
            owner = by_id.get(item["node"], {})
            state = item.get("status")
            require(key in expected_absent and state == expected_absent.get(key) and
                    isinstance(state, dict) and state.get("name") == "noValue" and valid_status(state) and
                    item["attribute"] not in owner.get("attributes", {}),
                    f"Native absent-attribute record lacks matching noValue evidence on #{item['node']} {item['attribute']}")
        require(seen_absent == set(expected_absent), "Native absent-attribute records omit or invent a noValue status")

    if "capture_recovery" not in snapshot:
        return
    recovery = snapshot["capture_recovery"]
    if not isinstance(recovery, dict):
        require(False, "Capture recovery is not an object")
        return
    records = recovery.get("attempts")
    if not isinstance(records, list) or not records or not all(isinstance(record, dict) for record in records):
        require(False, "Capture recovery attempts must be a nonempty array of records")
        return
    count, budget = len(records), recovery.get("max_attempts")
    require(integer(budget, 1) and budget <= 3 and count <= budget, "Capture recovery exceeded its bounded attempt budget")
    require(all(type(record.get("attempt")) is int for record in records) and
            [record.get("attempt") for record in records] == list(range(1, count + 1)), "Capture attempt numbers are not consecutive")
    require(all(type(recovery.get(key)) is int and recovery[key] == count for key in
                ("attempt_count", "completed_capture_count", "archived_capture_count")),
            "Published capture recovery counts disagree with completed/archived records")
    require(recovery.get("succeeded") is True and type(recovery.get("selected_attempt")) is int and recovery.get("selected_attempt") == count,
            "Published snapshot is not the latest successful capture attempt")
    for index, record in enumerate(records):
        require(record.get("status") == "captured" and record.get("identity_continuity") is True and record.get("archived") is True,
                "Published snapshot contains an unsuccessful/unarchived capture attempt")
        for key in ("node_count", "leaf_count", "unknown_leaf_count", "invalid_reference_count", "invalid_hierarchy_failure_count",
                    "hierarchy_failure_count", "metadata_read_failure_count", "serialization_warning_count"):
            require(integer(record.get(key)), f"Capture attempt {index + 1} has invalid {key}")
        require(integer(record.get("node_count"), 1) and type(record.get("exposed_hierarchy_resolved")) is bool,
                f"Capture attempt {index + 1} has invalid node/resolution summary")
        for key in ("graph_digest", "semantic_graph_digest"):
            digest = record.get(key)
            require(isinstance(digest, str) and len(digest) == 64 and all(character in "0123456789abcdef" for character in digest),
                    f"Capture attempt {index + 1} has invalid {key}")
        if all(integer(record.get(key)) for key in ("node_count", "leaf_count", "unknown_leaf_count")):
            require(record["leaf_count"] + record["unknown_leaf_count"] <= record["node_count"],
                    f"Capture attempt {index + 1} has impossible leaf counts")
        if all(integer(record.get(key)) for key in ("invalid_reference_count", "invalid_hierarchy_failure_count", "hierarchy_failure_count")):
            require(record["invalid_reference_count"] <= record["invalid_hierarchy_failure_count"] <= record["hierarchy_failure_count"],
                    f"Capture attempt {index + 1} has impossible invalid-reference counts")
        if index < count - 1:
            require(integer(record.get("invalid_hierarchy_failure_count"), 1), "Fresh capture retried without an invalid-hierarchy trigger")
    last = records[-1]
    invalid = [item for item in snapshot.get("hierarchy_failures", []) if item.get("status", {}).get("code") == -25202]
    invalid_nodes = {item["node"] for item in invalid if type(item.get("node")) is int}
    invalid_refs = len(invalid_nodes) + sum(type(item.get("node")) is not int for item in invalid)
    selected = {key: snapshot.get(key) for key in ("graph_digest", "semantic_graph_digest", "node_count", "leaf_count", "unknown_leaf_count", "exposed_hierarchy_resolved")}
    selected.update(invalid_reference_count=invalid_refs, invalid_hierarchy_failure_count=len(invalid),
                    hierarchy_failure_count=len(snapshot.get("hierarchy_failures", [])),
                    metadata_read_failure_count=len(snapshot.get("metadata_read_failures", [])),
                    serialization_warning_count=len(snapshot.get("serialization_warnings", [])))
    require(all(last.get(key) == value for key, value in selected.items()), "Selected capture attempt digest/counts differ from the published latest snapshot")
    if invalid:
        require(count == budget and recovery.get("budget_exhausted") is True and
                recovery.get("stop_reason") == "capture_attempt_budget_exhausted", "Invalid-reference capture did not exhaust its stated retry budget")
    else:
        require(recovery.get("budget_exhausted") is False and recovery.get("stop_reason") == "no_retryable_invalid_hierarchy_references",
                "Capture recovery stop reason contradicts the latest hierarchy failures")


def check(snapshot):
    errors = []

    def require(condition, message):
        if not condition:
            errors.append(message)

    nodes = snapshot.get("nodes", [])
    ids = [node.get("id") for node in nodes]
    require(ids == list(range(len(nodes))), "IDs are not unique contiguous snapshot-local integers")
    by_id = {node.get("id"): node for node in nodes if type(node.get("id")) is int}
    if "process_identities" in snapshot:
        owners = snapshot["process_identities"]
        owner_by_pid = {owner.get("pid"): owner for owner in owners}
        require(len(owner_by_pid) == len(owners), "Process identities contain duplicate PIDs")
        primary = snapshot.get("app", {})
        helper = snapshot.get("scope", {}).get("allowlisted_helper_executable")
        require(owner_by_pid.get(primary.get("pid")) == primary, "Primary process registry identity differs from the selected app")
        require(by_id.get(snapshot.get("root_id"), {}).get("pid") == primary.get("pid"), "Root belongs to a different owning process")
        native_policy = snapshot.get("scope", {}).get("process_traversal_policy") == "native_references_with_launch_identity"
        if native_policy:
            require(set(owner_by_pid) == {node.get("pid") for node in nodes}, "Process registry contains unused/missing owning identities")
            for owner in owners:
                require(type(owner.get("pid")) is int and owner.get("pid") > 0 and isinstance(owner.get("launch_date"), str) and bool(owner["launch_date"]),
                        "Native-reference process identity lacks PID/launch identity")
        else:
            for owner in owners:
                if owner.get("pid") != primary.get("pid"):
                    require(owner.get("executable_path") == helper, "Captured a non-allowlisted external process")
        for node in nodes:
            require(node.get("pid") in owner_by_pid and node.get("process_identity") == owner_by_pid.get(node.get("pid")),
                    f"Node #{node.get('id')} has an inconsistent owning process identity")
    root = snapshot.get("root_id")
    require(root in by_id, "Root does not exist")
    require(snapshot.get("node_count") == len(nodes), "Node count does not match records")
    hierarchy_names = set(snapshot.get("scope", {}).get("hierarchy_attributes", []))
    scalar_hierarchy = {"AXMenuBar", "AXExtrasMenuBar"}
    failures = defaultdict(list)
    for failure in snapshot.get("hierarchy_failures", []):
        failures[failure.get("node")].append(failure)
    outgoing = defaultdict(list)
    edge_refs = defaultdict(Counter)
    unresolved_edges = []
    for edge in snapshot.get("all_reference_edges", []):
        source, target = edge.get("from"), edge.get("to")
        require(source in by_id, f"Reference has nonexistent source #{source}")
        edge_refs[(source, edge.get("attribute"))][target] += 1
        if target is not None:
            require(type(target) is int and target in by_id, f"Reference has nonexistent target #{target}")
            outgoing[source].append(target)
        else:
            unresolved_edges.append(edge)
        require(edge.get("relationship") == ("hierarchy" if edge.get("attribute") in hierarchy_names else "reference"),
                f"Reference relationship misclassified on #{source}")
    seen = set()
    queue = deque([root])
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        queue.extend(outgoing[current])
    require(seen == set(ids), "Some nodes are unreachable under the declared reference traversal policy")
    if "process_identities" in snapshot and native_policy:
        incoming_processes = {by_id[edge["to"]].get("pid") for edge in snapshot.get("all_reference_edges", [])
                              if edge.get("from") in by_id and edge.get("to") in by_id and
                              by_id[edge["from"]].get("pid") != by_id[edge["to"]].get("pid")}
        require(set(owner_by_pid) - {primary.get("pid")} <= incoming_processes,
                "External owning process lacks an actual cross-process native reference")
    require(Counter(json.dumps(e, sort_keys=True) for e in unresolved_edges) ==
            Counter(json.dumps(e, sort_keys=True) for e in snapshot.get("cutoffs", [])),
            "Unresolved references and cutoff records disagree")
    independently_unresolved = False
    for node in nodes:
        identifier = node["id"]
        attrs = node.get("attributes", {})
        statuses = node.get("attribute_statuses", {})
        advertised = set(node.get("attribute_names", []))
        require(set(statuses) == advertised | {"AXChildren"}, f"Not every advertised attribute was attempted on #{identifier}")
        unresolved = node.get("attribute_names_status", {}).get("code") != 0
        if unresolved:
            require(any(f.get("attribute") == "attribute_names" for f in failures[identifier]),
                    f"Missing attribute discovery failure record on #{identifier}")
        targets = set()
        for name, status in statuses.items():
            require(1 <= status.get("attempts", 0) <= 3, f"Invalid read attempt count on #{identifier} {name}")
            encoded_refs = Counter(native_refs(attrs.get(name)))
            require(encoded_refs == edge_refs[(identifier, name)], f"Serialized references and edges differ on #{identifier} {name}")
            if name not in hierarchy_names:
                continue
            code = status.get("code")
            known_absence = code == -25212 or (code == -25205 and name == "AXChildren" and name not in advertised)
            value = attrs.get(name)
            if code == 0:
                if name in scalar_hierarchy:
                    valid = isinstance(value, dict) and value.get("type") == "AXUIElement" and type(value.get("id")) is int
                else:
                    valid = isinstance(value, list) and all(isinstance(v, dict) and v.get("type") == "AXUIElement" and type(v.get("id")) is int for v in value)
                unresolved |= not valid
                if not valid:
                    require(any(f.get("attribute") == name for f in failures[identifier]),
                            f"Missing malformed/nil hierarchy failure record on #{identifier} {name}")
            elif not known_absence:
                unresolved = True
                require(any(f.get("attribute") == name for f in failures[identifier]),
                        f"Missing hierarchy read failure record on #{identifier} {name}")
            declared = node.get("hierarchy", {}).get(name, [])
            require(set(declared) == {target for target in encoded_refs if target is not None}, f"Containment edge list differs from values on #{identifier} {name}")
            targets.update(declared)
        unresolved |= bool(failures[identifier])
        independently_unresolved |= unresolved
        expected = "unknown" if unresolved else ("branch" if targets else "leaf")
        require(node.get("leaf_status") == expected, f"Leaf classification is unsupported on #{identifier}: expected {expected}")
        require(node.get("hierarchy_child_count") == len(targets), f"Hierarchy child count mismatch on #{identifier}")
        require(node.get("hierarchy_leaf") == (None if unresolved else not targets), f"Legacy leaf marker disagrees on #{identifier}")
        cursor = root
        try:
            for step in node.get("selector_path", []):
                value = by_id[cursor]["attributes"][step["attribute"]]
                for component in step["value_path"]:
                    value = value[component]
                if not isinstance(value, dict) or value.get("type") != "AXUIElement":
                    raise ValueError("Selector does not end at an element")
                cursor = value["id"]
            require(cursor == identifier, f"Selector does not re-resolve its recorded node #{identifier}")
        except (KeyError, IndexError, TypeError, ValueError):
            require(False, f"Selector path is invalid on #{identifier}")
        require(node.get("first_depth") == len(node.get("selector_path", [])), f"First depth mismatch on #{identifier}")
    counts = Counter(node.get("leaf_status") for node in nodes)
    leaf_ids = [node["id"] for node in nodes if node.get("leaf_status") == "leaf"]
    unknown_ids = [node["id"] for node in nodes if node.get("leaf_status") == "unknown"]
    require(snapshot.get("leaf_ids") == leaf_ids and snapshot.get("leaf_count") == len(leaf_ids), "Leaf summary differs from node records")
    require(snapshot.get("unknown_leaf_ids") == unknown_ids and snapshot.get("unknown_leaf_count") == len(unknown_ids), "Unknown-leaf summary differs from node records")
    require(set(counts) <= {"leaf", "branch", "unknown"}, "Unrecognized leaf status")
    roles = Counter(node.get("attributes", {}).get("AXRole", "unknown") for node in nodes)
    require(snapshot.get("role_counts") == dict(roles), "Role counts differ from node records")
    require(snapshot.get("maximum_depth") == max((len(n.get("selector_path", [])) for n in nodes), default=0), "Maximum depth differs from selector records")
    expected_resolved = not independently_unresolved and not snapshot.get("hierarchy_failures") and not snapshot.get("cutoffs")
    require(snapshot.get("exposed_hierarchy_resolved") == expected_resolved, "Hierarchy resolution summary differs from errors/cutoffs")
    recovery_checks(snapshot, nodes, by_id, require)
    combined_metadata = snapshot.get("metadata_failures", [])
    combined_metadata = combined_metadata if isinstance(combined_metadata, list) else []
    metadata_reads = snapshot.get("metadata_read_failures", [item for item in combined_metadata if isinstance(item, dict) and item.get("stage") != "serialization"])
    serialization_warnings = snapshot.get("serialization_warnings", [item for item in combined_metadata if isinstance(item, dict) and item.get("stage") == "serialization"])
    return {"passed": not errors, "errors": errors, "nodes": len(nodes), "leaves": counts["leaf"],
            "branches": counts["branch"], "unknown": counts["unknown"],
            "reference_edge_occurrences": len(snapshot.get("all_reference_edges", [])),
            "reachable_nodes": len(seen), "hierarchy_failures": len(snapshot.get("hierarchy_failures", [])),
            "metadata_failures": len(combined_metadata), "metadata_read_failures": len(metadata_reads) if isinstance(metadata_reads, list) else None,
            "serialization_warnings": len(serialization_warnings) if isinstance(serialization_warnings, list) else None,
            "native_read_recovery_attempts": snapshot.get("native_read_recovery_attempts"),
            "native_read_recovery_successes": snapshot.get("native_read_recovery_successes"),
            "native_read_recovery_value_successes": snapshot.get("native_read_recovery_value_successes"),
            "native_read_recovery_absence_successes": snapshot.get("native_read_recovery_absence_successes"),
            "native_metadata_failure_summary": snapshot.get("native_metadata_failure_summary"),
            **({key: snapshot.get(key) for key in RETAINED_SCALAR_COUNTERS} if snapshot.get("scalar_recovery_version") == 3 else {}),
            "cutoffs": len(snapshot.get("cutoffs", []))}


def apply_recovery_sidecar(snapshot, result, sidecar):
    """A valid retained tree is historical evidence when the latest capture failed."""
    result = {**result, "errors": list(result["errors"])}
    result["historically_valid_graph"] = result["passed"]

    def require(condition, message):
        if not condition:
            result["errors"].append(message)
            result["passed"] = False

    if not isinstance(sidecar, dict):
        require(False, "Capture recovery sidecar is not an object")
        result["latest_capture_available"] = False
        return result
    require(sidecar.get("app_identity") == snapshot.get("app"), "Capture recovery sidecar has a different application identity")
    published = sidecar.get("latest_snapshot_published")
    require(type(published) is bool, "Capture recovery sidecar lacks an explicit publication result")
    result["latest_capture_available"] = published is True
    result["latest_capture_failed"] = published is False
    observations = sidecar.get("capture_recovery_observations")
    valid = isinstance(observations, list) and bool(observations) and all(isinstance(item, dict) for item in observations)
    require(valid, "Capture recovery sidecar observations are malformed")
    if valid:
        require(all(type(item.get("observation")) is int for item in observations) and
                [item.get("observation") for item in observations] == list(range(1, len(observations) + 1)),
                "Capture recovery sidecar observation numbers are not consecutive")
    if published is False:
        require(False, "Latest native capture failed; the retained snapshot is historical evidence, not the latest result")
        if valid:
            require(sidecar.get("failed_observation") == len(observations) and observations[-1].get("succeeded") is False and
                    observations[-1].get("selected_attempt") is None,
                    "Failed capture recovery sidecar claims a selected/latest snapshot")
    elif published is True and valid:
        final = {key: value for key, value in observations[-1].items() if key != "observation"}
        require(final == snapshot.get("capture_recovery"), "Capture recovery sidecar does not describe the published latest snapshot")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    results = []
    for path in sorted(args.directory.rglob("snapshot.json")):
        snapshot = json.loads(path.read_text())
        result = check(snapshot)
        leaves_path = path.parent / "leaves.ndjson"
        if leaves_path.exists():
            exported = [json.loads(line) for line in leaves_path.read_text().splitlines() if line.strip()]
            expected = [n for n in snapshot["nodes"] if n.get("leaf_status") == "leaf"]
            if exported != expected:
                result["errors"].append("Leaf file differs from snapshot records")
                result["passed"] = False
        coverage_path = path.parent / "coverage.json"
        if coverage_path.exists():
            expected = {k: v for k, v in snapshot.items() if k not in {"nodes", "all_reference_edges"}}
            if json.loads(coverage_path.read_text()) != expected:
                result["errors"].append("Coverage file differs from snapshot metadata")
                result["passed"] = False
        recovery_path = path.parent / "capture-recovery.json"
        if recovery_path.exists():
            result = apply_recovery_sidecar(snapshot, result, json.loads(recovery_path.read_text()))
        result["snapshot"] = str(path.relative_to(args.directory))
        results.append(result)
    if not results:
        parser.error("No snapshot.json exports found")
    output = {"passed": all(result["passed"] for result in results), "snapshots": results}
    if any("latest_capture_available" in result for result in results):
        output["latest_capture_available"] = all(result.get("latest_capture_available", True) for result in results)
    (args.directory / "audit.json").write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output))
    raise SystemExit(0 if output["passed"] else 1)
