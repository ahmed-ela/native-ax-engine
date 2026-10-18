#!/usr/bin/env python3
"""Build an offline, escaped HTML viewer for native AX capture exports."""
import argparse
import html
import json
from pathlib import Path
from urllib.parse import quote


def escape(value):
    return html.escape(str(value), quote=True)


def attr_text(node, name):
    value = node.get("attributes", {}).get(name, "")
    if isinstance(value, dict) and "value" in value:
        value = value["value"]
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def metadata_counts(snapshot):
    legacy = snapshot.get("metadata_failures", [])
    reads = snapshot.get("metadata_read_failures")
    warnings = snapshot.get("serialization_warnings")
    if reads is None:
        reads = [item for item in legacy if item.get("stage") != "serialization"]
    if warnings is None:
        warnings = [item for item in legacy if item.get("stage") == "serialization"]
    if not isinstance(reads, list) or not isinstance(warnings, list):
        raise ValueError("Metadata classifications must be arrays")
    return len(reads), len(warnings)


def metadata_failure_summary(snapshot):
    reads = snapshot.get("metadata_read_failures")
    if reads is None:
        reads = [item for item in snapshot.get("metadata_failures", [])
                 if item.get("stage") != "serialization"]
    unsupported = sum(item.get("status", {}).get("code") == -25205 for item in reads)
    derived = {"attribute_unsupported": unsupported, "other_read_failures": len(reads) - unsupported}
    summary = snapshot.get("native_metadata_failure_summary", derived)
    if not isinstance(summary, dict) or any(type(summary.get(key)) is not int
            or summary[key] != count for key, count in derived.items()):
        raise ValueError("Native metadata failure summary disagrees with the recorded read errors")
    return summary


def render(directory, output):
    captures = []
    archived = list(directory.rglob("states/*/snapshot.json"))
    for path in sorted(archived or directory.rglob("snapshot.json")):
        data = json.loads(path.read_text())
        if isinstance(data, dict) and isinstance(data.get("nodes"), list):
            for node in data["nodes"]:
                if type(node.get("id")) is not int or node["id"] < 0:
                    raise ValueError("Snapshot node IDs must be nonnegative integers")
                for targets in node.get("hierarchy", {}).values():
                    if not isinstance(targets, list) or any(type(t) is not int or t < 0 for t in targets):
                        raise ValueError("Hierarchy targets must be nonnegative integer IDs")
            captures.append((path, data))
    if not captures:
        raise ValueError("No native AX snapshots found in this directory")
    parts = ["""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Native AX capture report</title><style>
:root{color-scheme:light dark;font:15px/1.5 system-ui,sans-serif}
body{max-width:1180px;margin:40px auto;padding:0 24px;background:#10151d;color:#e8edf5}
h1{font-size:32px;letter-spacing:-.03em}h2{margin-top:40px}
a{color:#86c5ff}code,pre{font:12px/1.5 ui-monospace,monospace}
pre{overflow:auto;max-height:520px;background:#111d2b;padding:16px;border-radius:8px}
table{border-collapse:collapse;width:100%;margin:16px 0}td,th{padding:9px;text-align:left;border-bottom:1px solid #2b3747}
.note{color:#afbdd0;max-width:900px}.card{border:1px solid #2b3747;border-radius:12px;padding:18px;margin:16px 0}
details{border-top:1px solid #2b3747;padding:8px 0}summary{cursor:pointer;overflow-wrap:anywhere}
input{box-sizing:border-box;width:100%;padding:12px;border-radius:8px;border:1px solid #455367;background:#111d2b;color:inherit;font:inherit}
.leaf{color:#88dfb5}.unknown{color:#f2c778}.branch{color:#afbdd0}.links{word-break:break-all}
</style><h1>Native AX capture report</h1>
<p class="note">Every node comes from the selected app's native accessibility API.
These captures describe observed states. They do not establish that every future app state or parameterized query has been exhausted.
No screenshots, OCR, or synthesized nodes are used.</p>
<div class="card"><strong>Export scope</strong><p class="note">Element IDs belong to one snapshot.
Read failures, uncertain leaves, and state fingerprints remain in the raw JSON.
Capture reads are sequential rather than atomic; verification compares repeated observations.</p>
<p class="note">Native metadata read failures and serialization warnings are counted separately.
Serialization warnings can follow successful native API reads; they do not mean the API read failed.
Known native absence (noValue) is not counted as a failure. For legacy exports, the split uses the recorded stage.</p></div>
<h2>Captured states</h2><table><tr><th>Snapshot</th><th>Nodes</th><th>Leaves</th><th>Unknown</th><th>Hierarchy issues</th><th>Unresolved refs</th><th>Metadata read failures</th><th>Serialization warnings</th></tr>"""]
    for i, (path, data) in enumerate(captures):
        nodes = data["nodes"]
        counts = {status: sum(n.get("leaf_status") == status for n in nodes)
                  for status in ("leaf", "branch", "unknown")}
        read_count, warning_count = metadata_counts(data)
        parts.append(f'<tr><td><a href="#snapshot-{i}">{escape(path.relative_to(directory))}</a></td>'
                     f'<td>{len(nodes)}</td><td>{counts["leaf"]}</td><td>{counts["unknown"]}</td>'
                     f'<td>{len(data.get("hierarchy_failures", []))}</td>'
                     f'<td>{len(data.get("cutoffs", []))}</td>'
                     f'<td>{read_count}</td><td>{warning_count}</td></tr>')
    parts.append('</table><h2>Inspect nodes</h2><input id="filter" placeholder="Filter by role, title, identifier, action, or leaf status" aria-label="Filter nodes">')
    for i, (path, data) in enumerate(captures):
        relative = path.relative_to(directory)
        parts.append(f'<section id="snapshot-{i}"><h2>{escape(relative)}</h2>'
                     f'<p><a href="./{escape(quote(str(relative), safe="/"))}">Raw snapshot JSON</a></p>')
        failures = metadata_failure_summary(data)
        parts.append('<p class="note">Metadata read diagnostics: '
                     + escape(failures["attribute_unsupported"]) + ' native unsupported reads; '
                     + escape(failures["other_read_failures"]) + ' other read failures. '
                     + 'Every original read-error record remains in the raw snapshot. Unsupported does not establish recovered content or confirmed absence.</p>')
        if data.get("capture_recovery") is not None:
            parts.append('<details><summary>Capture recovery evidence</summary><pre>'
                         + escape(json.dumps(data["capture_recovery"], indent=2, ensure_ascii=False))
                         + '</pre></details>')
        if "native_read_recovery_attempts" in data:
            if data.get("native_read_recovery_outcome_version", 0) >= 2 \
                    and "native_read_recovery_value_successes" in data \
                    and "native_read_recovery_absence_successes" in data:
                summary = (str(data["native_read_recovery_value_successes"])
                           + " recovered native values or enumerations + "
                           + str(data["native_read_recovery_absence_successes"])
                           + " confirmed native absences ("
                           + str(data.get("native_read_recovery_successes", 0))
                           + " resolved outcomes)")
            else:
                summary = str(data.get("native_read_recovery_successes", 0)) \
                    + " recorded native recovery successes; no separate value/absence counters in this legacy export"
            parts.append('<p class="note">Native recovery: ' + escape(summary)
                         + ' / ' + escape(data["native_read_recovery_attempts"])
                         + ' attempts. Confirmed native absence means the attribute has no value, rather than a returned empty array. Each attempt may contain multiple queries. Original direct-read errors and every native query result remain in the affected node JSON.</p>')
        if "native_scalar_retained_reference_attempts" in data:
            parts.append('<p class="note">Retained original reference queries: '
                         + escape(data["native_scalar_retained_reference_attempts"]) + ' issued; '
                         + escape(data.get("native_scalar_retained_reference_withheld", 0)) + ' withheld after failed validation; '
                         + escape(data.get("native_scalar_retained_reference_value_successes", 0)) + ' typed native values; '
                         + escape(data.get("native_scalar_retained_reference_absence_successes", 0))
                         + ' confirmed native absences. These outcomes are included in native recovery totals. Failed fresh refreshes stay recorded; querying an original reference does not establish current tree membership.</p>')
        parts.append(f'<details data-snapshot="{i}" data-metadata="true"><summary>Snapshot metadata and coverage</summary><pre></pre></details>')
        for node in data["nodes"]:
            identifier = node.get("id")
            role = attr_text(node, "AXRole") or "unknown role"
            title = attr_text(node, "AXTitle") or attr_text(node, "AXDescription") or attr_text(node, "AXIdentifier")
            status = node.get("leaf_status", "unknown")
            search = " ".join([str(identifier), role, title, status,
                               attr_text(node, "AXIdentifier"),
                               " ".join(node.get("action_names", []))]).lower()
            parts.append(f'<details class="node" id="node-{i}-{identifier}" data-snapshot="{i}" data-node="{identifier}" data-search="{escape(search)}">'
                         f'<summary><code>#{identifier}</code> {escape(role)} · {escape(title)} '
                         f'<span class="{escape(status)}">[{escape(status)}]</span></summary>')
            hierarchy = node.get("hierarchy", {})
            if hierarchy:
                links = []
                for name, targets in hierarchy.items():
                    if isinstance(targets, list):
                        links.append(escape(name) + ': ' + ', '.join(
                            f'<a href="#node-{i}-{target}">#{target}</a>' for target in targets))
                parts.append('<p class="links">' + '<br>'.join(links) + '</p>')
            for attribute, trace in node.get("native_read_recoveries", {}).items():
                if trace.get("resolved") is True and trace.get("resolution_kind") == "absence":
                    outcome = "confirmed native absence (noValue); no content or empty array was recovered"
                elif trace.get("resolved") is not True \
                        or trace.get("resolution_kind") not in (None, "value"):
                    outcome = "native recovery remains unresolved; no empty value is inferred"
                elif trace.get("method") == "native_action_names_recovery":
                    outcome = "resolved native action enumeration"
                    if type(trace.get("strings_count")) is int:
                        outcome += "; " + str(trace["strings_count"]) + " action strings"
                elif trace.get("method") == "native_metadata_recovery":
                    outcome = "resolved native attribute value"
                    if trace.get("selected_method"):
                        outcome += " using " + str(trace["selected_method"])
                elif type(trace.get("returned_count")) is int \
                        and type(trace.get("count_before")) is int \
                        and trace["returned_count"] == trace["count_before"] == trace.get("count_after"):
                    outcome = "resolved native array value; " + str(trace["returned_count"]) \
                        + " values with matching recorded before/after counts"
                else:
                    outcome = "resolved native attribute value"
                documented = trace.get("documented_scalar", {})
                if documented.get("array_query_skipped") is True:
                    outcome += "; array query skipped for known scalar " \
                        + str(documented.get("expected_value_kind", "scalar")) + " value kind"
                    scalar = next((query for query in trace.get("queries", [])
                                   if query.get("method") == "native_scalar_recovery"), None)
                    if scalar is not None:
                        if scalar.get("query_status"):
                            target = "retained original reference" if scalar.get("query_target") \
                                == "retained_original_reference" else "fresh exact-target"
                            outcome += "; one bounded " + target + " query"
                            if scalar.get("query_target") == "retained_original_reference":
                                outcome += "; failed fresh refresh remains recorded; current tree membership is not established"
                        elif scalar.get("retained_reference"):
                            outcome += "; scalar query withheld because neither fresh target nor retained original reference passed validation"
                        else:
                            outcome += "; scalar query withheld because exact target was not verified"
                    elif documented.get("scalar_retry_eligible") is False:
                        outcome += "; fresh scalar retry not eligible; native unsupported response retained"
                if trace.get("resolved") is True and trace.get("initial_status", {}).get("code") == -25205:
                    outcome += "; original attributeUnsupported response remains recorded"
                parts.append('<p class="note">' + escape(attribute) + ': ' + escape(outcome)
                             + '. Original status and full native recovery query evidence are included in this node JSON.</p>')
            parts.append('<pre></pre></details>')
        parts.append('</section>')
    for name in ("verification.json", "stategraph.json", "audit.json"):
        for path in sorted(directory.rglob(name)):
            relative = path.relative_to(directory)
            parts.append(f'<h2>{escape(relative)}</h2><details><summary>Inspect {escape(name)}</summary><pre>'
                         + escape(json.dumps(json.loads(path.read_text()), indent=2, ensure_ascii=False))
                         + '</pre></details>')
    payload = json.dumps([data for _, data in captures], ensure_ascii=False, separators=(",", ":"))
    payload = payload.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    parts.append('<script type="application/json" id="native-captures">' + payload + '</script>')
    parts.append('''<script>
let captureData;
document.addEventListener('toggle', event => {
  const details = event.target;
  if (!details.open || !details.matches('details[data-snapshot]') || details.dataset.loaded) return;
  captureData ??= JSON.parse(document.getElementById('native-captures').textContent);
  const snapshot = captureData[Number(details.dataset.snapshot)];
  const value = details.dataset.metadata
    ? Object.fromEntries(Object.entries(snapshot).filter(([key]) => key !== 'nodes'))
    : snapshot.nodes.find(node => node.id === Number(details.dataset.node));
  details.querySelector('pre').textContent = JSON.stringify(value, null, 2);
  details.dataset.loaded = 'true';
}, true);
document.getElementById('filter').addEventListener('input', event => {
  const query = event.target.value.toLowerCase().trim();
  document.querySelectorAll('details.node').forEach(node => {
    node.hidden = !node.dataset.search.includes(query);
  });
});
document.addEventListener('click', event => {
  const link = event.target.closest('a[href^="#node-"]');
  if (link) { const node = document.getElementById(link.hash.slice(1)); if (node) { node.hidden=false; node.open=true; } }
});
</script></html>''')
    output.write_text("\n".join(parts))
    print(json.dumps({"report": str(output.resolve()), "snapshots": len(captures)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    render(args.directory, args.output or args.directory / "report.html")
