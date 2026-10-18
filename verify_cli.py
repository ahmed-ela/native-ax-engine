#!/usr/bin/env python3
"""Verify CLI refusal and output-integrity cases using allowed live app exports.

No test asks the engine to perform a valid native action. Selected actions are
used only behind deliberately incompatible output or stale snapshot guards.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main(calculator, textedit, result_path):
    engine = Path(__file__).resolve().parent / "ax-engine"
    calc = json.loads(calculator.read_text())
    other = json.loads(textedit.read_text())
    target = next(node for node in calc["nodes"]
                  if node.get("attributes", {}).get("AXTitle") == "Scientific"
                  and "AXPress" in node.get("action_names", []))
    results = []

    def invoke(*args):
        return subprocess.run([str(engine), *map(str, args)], capture_output=True, text=True)

    def record(name, condition, execution):
        results.append({"test": name, "passed": bool(condition), "exit_code": execution.returncode})

    def digests(directory):
        return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in directory.rglob("*") if p.is_file()}

    with tempfile.TemporaryDirectory(prefix="native-ax-cli-") as temporary:
        root = Path(temporary)
        mixed = root / "mixed"
        mixed.mkdir()
        (mixed / "snapshot.json").write_text(json.dumps(other))
        before = digests(mixed)
        run = invoke("--app", "com.apple.calculator", "--output", mixed)
        record("foreign output preserved before snapshot write",
               run.returncode == 2 and digests(mixed) == before and "incompatible" in run.stderr, run)

        action_output = root / "mixed-action"
        (action_output / "after").mkdir(parents=True)
        (action_output / "after" / "snapshot.json").write_text(json.dumps(other))
        before = digests(action_output)
        run = invoke("transition", "--app", "com.apple.calculator", "--output", action_output,
                     "--transition-from", calculator, "--node", target["id"], "--action", "AXPress", "--expect-title", "Scientific")
        record("foreign after directory refused before native action",
               run.returncode == 2 and digests(action_output) == before and "incompatible" in run.stderr, run)

        stale = root / "stale.json"
        stale_data = dict(calc)
        stale_data["graph_digest"] = "0" * 64
        stale_data["semantic_graph_digest"] = "0" * 64
        stale.write_text(json.dumps(stale_data))
        stale_output = root / "stale-output"
        run = invoke("transition", "--app", "com.apple.calculator", "--output", stale_output,
                     "--transition-from", stale, "--node", target["id"], "--action", "AXPress", "--expect-title", "Scientific")
        record("stale semantic graph refused without action journal",
               run.returncode == 2 and not (stale_output / "transition.json").exists()
               and "no action was performed" in run.stderr, run)

        mismatch = root / "mismatched-title"
        run = invoke("transition", "--app", "com.apple.calculator", "--output", mismatch,
                     "--transition-from", calculator, "--node", target["id"], "--action", "AXPress", "--expect-title", "Basic")
        record("expected label rejects an incorrect node number",
               run.returncode == 2 and not (mismatch / "transition.json").exists(), run)

        single = root / "single"
        single.mkdir()
        (single / "snapshot.json").write_text(json.dumps(calc))
        (single / "verification.json").write_text('{"graph_stable":true,"obsolete":true}')
        run = invoke("snapshot", "--app", "com.apple.calculator", "--output", single)
        record("single capture invalidates old verification",
               run.returncode == 0 and not (single / "verification.json").exists(), run)
    result = {"passed": all(item["passed"] for item in results), "checks": results}
    result_path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--calculator", required=True, type=Path)
    parser.add_argument("--textedit", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    raise SystemExit(main(args.calculator.resolve(), args.textedit.resolve(), args.result.resolve()))
