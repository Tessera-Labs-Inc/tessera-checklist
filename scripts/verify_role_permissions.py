#!/usr/bin/env python3
"""Verify that an IAM role has every Allow action required by a set of
policy documents, using iam:SimulatePrincipalPolicy.

Usage:
    python3 verify_role_permissions.py --role-arn <arn> [--policy-dir policies/aws]
"""
import argparse
import glob
import json
import os
import sys

import boto3

BATCH_SIZE = 50


def extract_context_variants(condition):
    """Return every ContextEntries combination a statement's Condition can match.

    A Condition ANDs its operator/key blocks, but a list of values under one key is an
    OR: the statement matches if the request satisfies any single one of them (e.g.
    iam:PassRole's iam:PassedToService lists 8 services — the role needs to work for
    each of those 8 individually). Testing only the first value would silently pass a
    role that's only allowed for a subset. Returns [[]] for no condition (unconditioned).
    """
    if not condition:
        return [[]]

    per_key_options = []
    for operator, keys in condition.items():
        is_bool = operator.lower().startswith("bool")
        ctype = "boolean" if is_bool else "string"
        for key, value in keys.items():
            values = value if isinstance(value, list) else [value]
            per_key_options.append(
                [
                    {
                        "ContextKeyName": key,
                        "ContextKeyValues": [str(v).lower() if is_bool else str(v)],
                        "ContextKeyType": ctype,
                    }
                    for v in values
                ]
            )

    variants = [[]]
    for options in per_key_options:
        variants = [combo + [option] for combo in variants for option in options]
    return variants


def context_signature(context_entries):
    return tuple(
        sorted((c["ContextKeyName"], tuple(c["ContextKeyValues"])) for c in context_entries)
    )


def format_context(context_entries):
    if not context_entries:
        return ""
    parts = [f"{c['ContextKeyName']}={','.join(c['ContextKeyValues'])}" for c in context_entries]
    return " (" + ", ".join(parts) + ")"


def load_required_actions(policy_dir):
    """Return a dict keyed by (action, context signature) -> entry."""
    paths = sorted(glob.glob(os.path.join(policy_dir, "*.json")))
    if not paths:
        return {}

    required = {}
    for path in paths:
        with open(path) as f:
            doc = json.load(f)
        for stmt in doc.get("Statement", []):
            if stmt.get("Effect") != "Allow":
                continue
            sid = stmt.get("Sid", "")
            actions = stmt.get("Action", [])
            if isinstance(actions, str):
                actions = [actions]
            variants = extract_context_variants(stmt.get("Condition"))
            source = f"{os.path.basename(path)}:{sid}"
            for action in actions:
                for context_entries in variants:
                    sig = context_signature(context_entries)
                    key = (action, sig)
                    if key not in required:
                        required[key] = {
                            "action": action,
                            "context_entries": context_entries,
                            "sources": set(),
                        }
                    required[key]["sources"].add(source)
    return required


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def group_by_context(required):
    groups = {}
    for entry in required.values():
        sig = context_signature(entry["context_entries"])
        groups.setdefault(sig, {"context_entries": entry["context_entries"], "entries": []})
        groups[sig]["entries"].append(entry)
    return groups


def simulate(client, role_arn, entries, context_entries):
    action_names = [e["action"] for e in entries]
    results = {}
    for batch in chunked(action_names, BATCH_SIZE):
        kwargs = {"PolicySourceArn": role_arn, "ActionNames": batch}
        if context_entries:
            kwargs["ContextEntries"] = context_entries
        marker = None
        while True:
            if marker:
                kwargs["Marker"] = marker
            resp = client.simulate_principal_policy(**kwargs)
            for r in resp["EvaluationResults"]:
                results[r["EvalActionName"]] = r["EvalDecision"]
            if resp.get("IsTruncated"):
                marker = resp["Marker"]
            else:
                break
    return results


def write_summary(path, role_arn, policy_dir, checked, missing):
    with open(path, "a") as f:
        f.write("## IAM Role Permission Check\n\n")
        f.write(f"Role: `{role_arn}`\n\n")
        f.write(f"Checked **{checked}** required actions from `{policy_dir}`.\n\n")
        if missing:
            f.write(f"### Missing permissions ({len(missing)})\n\n")
            f.write("| Action | Condition | Decision | Required by |\n|---|---|---|---|\n")
            for m in missing:
                context = m["context"].strip(" ()") or "—"
                f.write(
                    f"| `{m['action']}` | {context} | {m['decision']} | "
                    f"{', '.join(sorted(m['sources']))} |\n"
                )
        else:
            f.write("All required permissions are present.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role-arn", required=True, help="ARN of the IAM role to verify")
    parser.add_argument(
        "--policy-dir",
        default="policies/aws",
        help="Directory of policy JSON files whose Allow actions are required (default: policies/aws)",
    )
    args = parser.parse_args()

    required = load_required_actions(args.policy_dir)
    if not required:
        print(f"No policy files with Allow actions found under {args.policy_dir}", file=sys.stderr)
        sys.exit(1)

    client = boto3.client("iam")
    groups = group_by_context(required)

    missing = []
    checked = 0
    for group in groups.values():
        decisions = simulate(client, args.role_arn, group["entries"], group["context_entries"])
        for entry in group["entries"]:
            checked += 1
            decision = decisions.get(entry["action"], "unknown")
            if decision != "allowed":
                missing.append(
                    {
                        "action": entry["action"],
                        "context": format_context(entry["context_entries"]),
                        "decision": decision,
                        "sources": entry["sources"],
                    }
                )

    missing.sort(key=lambda m: (m["action"], m["context"]))

    print(f"Checked {checked} required actions from {args.policy_dir} against {args.role_arn}\n")
    if missing:
        print(f"Missing or denied permissions ({len(missing)}):\n")
        for m in missing:
            print(
                f"  - {m['action']}{m['context']}  [{m['decision']}]  "
                f"(required by: {', '.join(sorted(m['sources']))})"
            )
    else:
        print("Role has all required permissions.")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        write_summary(summary_path, args.role_arn, args.policy_dir, checked, missing)

    if missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
