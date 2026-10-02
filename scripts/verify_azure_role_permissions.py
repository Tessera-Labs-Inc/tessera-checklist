#!/usr/bin/env python3
"""Verify that an Azure principal (the deployment service principal) holds every
Action and DataAction required by the Tessera custom role definitions.

Azure has no equivalent of iam:SimulatePrincipalPolicy, so this computes the
effective permissions the same way ARM authorizes a request:

  1. List the principal's role assignments at or above the scope
     (atScope() and assignedTo(), which includes group-inherited assignments).
  2. Expand each assigned role definition: (Actions - NotActions) and
     (DataActions - NotDataActions), wildcard-matched, case-insensitive.
  3. Subtract anything a deny assignment at that scope blocks for the principal.

Required permissions come from policies/azure/*.json, checked at the scope each role
is meant to be assigned at: files with "hub" in the name at --hub-subscription-id
(or --hub-resource-group), files ending "-rg.json" at the Tessera core resource group
(--resource-group), everything else at the Tessera subscription. Files with
"optional" in the name are only checked with --include-optional. Uses the Azure CLI's login for a token, so
run `az login` (or azure/login in CI) first; no extra Python packages are needed.

Usage:
    python3 verify_azure_role_permissions.py --principal-id <object-id> \\
        --subscription-id <tessera-sub> [--hub-subscription-id <hub-sub>] \\
        [--resource-group <core-rg>] [--hub-resource-group <hub-rg>] \\
        [--policy-dir policies/azure] [--include-optional]
"""
import argparse
import fnmatch
import glob
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ARM = "https://management.azure.com"
API_VERSION = "2022-04-01"
EVERYONE = "00000000-0000-0000-0000-000000000000"

# Built-in roles these custom roles are meant to replace. Holding one of them on
# top of the Tessera roles means the least-privilege setup isn't actually in effect.
BROAD_ROLES = {
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635": "Owner",
    "b24988ac-6180-42a0-ab88-20f7382dd24c": "Contributor",
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9": "User Access Administrator",
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168": "Role Based Access Control Administrator",
}


def get_token():
    out = subprocess.run(
        ["az", "account", "get-access-token", "--resource", ARM + "/", "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["accessToken"]


class ArmError(Exception):
    pass


def urlopen_json(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        try:
            err = json.load(e).get("error", {})
            detail = f"{err.get('code', e.code)}: {err.get('message', e.reason)}"
        except Exception:
            detail = f"HTTP {e.code} {e.reason}"
        raise ArmError(detail) from None


def arm_get_all(token, path, params):
    """GET an ARM list endpoint, following nextLink."""
    query = urllib.parse.urlencode({"api-version": API_VERSION, **params}, quote_via=urllib.parse.quote)
    url = f"{ARM}{path}?{query}"
    items = []
    while url:
        body = urlopen_json(url, token)
        items.extend(body.get("value", []))
        url = body.get("nextLink")
    return items


def arm_get(token, path):
    return urlopen_json(f"{ARM}{path}?api-version={API_VERSION}", token)


def matches(pattern, action):
    return fnmatch.fnmatchcase(action.lower(), pattern.lower())


def load_required(policy_dir, include_optional):
    """Return {"tessera": {...}, "tessera_rg": {...}, "hub": {...}}, each (kind, action) -> set of source files."""
    required = {"tessera": {}, "tessera_rg": {}, "hub": {}}
    for path in sorted(glob.glob(os.path.join(policy_dir, "*.json"))):
        name = os.path.basename(path)
        if "optional" in name and not include_optional:
            continue
        if "hub" in name:
            target = "hub"
        elif name.endswith("-rg.json"):
            target = "tessera_rg"
        else:
            target = "tessera"
        with open(path) as f:
            role = json.load(f)
        for kind, key in (("action", "Actions"), ("dataAction", "DataActions")):
            for action in role.get(key, []):
                required[target].setdefault((kind, action), set()).add(name)
    return required


def effective_grants(token, scope, principal_id):
    """Return (grants, deny_assignments, warnings) for the principal at scope.

    grants: list of dicts {role, condition, permissions:[{actions,notActions,dataActions,notDataActions}]}
    """
    assignments = arm_get_all(
        token,
        f"{scope}/providers/Microsoft.Authorization/roleAssignments",
        {"$filter": f"atScope() and assignedTo('{principal_id}')"},
    )
    grants = []
    warnings = []
    role_cache = {}
    for a in assignments:
        props = a["properties"]
        role_def_id = props["roleDefinitionId"]
        if role_def_id not in role_cache:
            role_cache[role_def_id] = arm_get(token, role_def_id)["properties"]
        role = role_cache[role_def_id]
        guid = role_def_id.rsplit("/", 1)[-1]
        if guid in BROAD_ROLES:
            warnings.append(
                f"principal still holds built-in '{BROAD_ROLES[guid]}' at {props['scope']} — "
                "the Tessera custom roles are meant to replace it"
            )
        grants.append(
            {
                "role": role["roleName"],
                "scope": props["scope"],
                "condition": props.get("condition"),
                "permissions": role.get("permissions", []),
            }
        )

    denies = []
    for d in arm_get_all(token, f"{scope}/providers/Microsoft.Authorization/denyAssignments", {"$filter": "atScope()"}):
        props = d["properties"]
        principals = {p["id"] for p in props.get("principals", [])}
        excluded = {p["id"] for p in props.get("excludePrincipals", [])}
        if (principal_id in principals or EVERYONE in principals) and principal_id not in excluded:
            denies.append({"name": props.get("denyAssignmentName", d["name"]), "permissions": props.get("permissions", [])})
    return grants, denies, warnings


def permission_allows(perm, kind, action):
    allow_key, deny_key = ("actions", "notActions") if kind == "action" else ("dataActions", "notDataActions")
    return any(matches(p, action) for p in perm.get(allow_key, [])) and not any(
        matches(p, action) for p in perm.get(deny_key, [])
    )


def evaluate(required, grants, denies):
    """Return list of missing entries and the role-assignment-write grant (for the ABAC check)."""
    missing = []
    for (kind, action), sources in sorted(required.items(), key=lambda kv: kv[0][1].lower()):
        granted_by = [g for g in grants if any(permission_allows(p, kind, action) for p in g["permissions"])]
        denied_by = [d["name"] for d in denies if any(permission_allows(p, kind, action) for p in d["permissions"])]
        if denied_by:
            missing.append({"kind": kind, "action": action, "decision": f"denied ({', '.join(denied_by)})", "sources": sources})
        elif not granted_by:
            missing.append({"kind": kind, "action": action, "decision": "not granted", "sources": sources})
    return missing


def role_assignment_write_unconditioned(grants):
    return [
        g["role"]
        for g in grants
        if not g["condition"]
        and any(permission_allows(p, "action", "Microsoft.Authorization/roleAssignments/write") for p in g["permissions"])
    ]


def write_summary(path, principal_id, results, warnings):
    with open(path, "a") as f:
        f.write("## Azure Role Permission Check\n\n")
        f.write(f"Principal: `{principal_id}`\n\n")
        for label, scope, checked, missing in results:
            f.write(f"### {label} — `{scope}`\n\nChecked **{checked}** required permissions.\n\n")
            if missing:
                f.write(f"Missing permissions ({len(missing)}):\n\n")
                f.write("| Permission | Type | Decision | Required by |\n|---|---|---|---|\n")
                for m in missing:
                    f.write(f"| `{m['action']}` | {m['kind']} | {m['decision']} | {', '.join(sorted(m['sources']))} |\n")
                f.write("\n")
            else:
                f.write("All required permissions are present.\n\n")
        if warnings:
            f.write("### Warnings\n\n")
            for w in warnings:
                f.write(f"- {w}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--principal-id", required=True, help="Object ID of the deployment service principal")
    parser.add_argument("--subscription-id", required=True, help="Tessera subscription ID")
    parser.add_argument(
        "--resource-group",
        help="Tessera core resource group (where the *-rg.json roles are assigned)",
    )
    parser.add_argument("--hub-subscription-id", help="Hub subscription ID (checks the hub DNS/peering role)")
    parser.add_argument(
        "--hub-resource-group",
        help="Check the hub role at this hub resource group instead of the whole hub subscription",
    )
    parser.add_argument("--policy-dir", default="policies/azure", help="Directory of role definition JSON files")
    parser.add_argument(
        "--include-optional",
        action="store_true",
        help="Also require the optional greenfield-network role (create_vnet / firewall / bastion)",
    )
    args = parser.parse_args()

    required = load_required(args.policy_dir, args.include_optional)
    if not required["tessera"]:
        print(f"No role definition files found under {args.policy_dir}", file=sys.stderr)
        sys.exit(1)

    token = get_token()
    sub_scope = f"/subscriptions/{args.subscription_id}"
    targets = [("Tessera subscription", sub_scope, required["tessera"])]
    if args.resource_group:
        targets.append(("Tessera core resource group", f"{sub_scope}/resourceGroups/{args.resource_group}", required["tessera_rg"]))
    elif required["tessera_rg"]:
        print("Note: --resource-group not given; skipping the core-resource-group roles (*-rg.json).\n")
    if args.hub_subscription_id:
        hub_scope = f"/subscriptions/{args.hub_subscription_id}"
        if args.hub_resource_group:
            hub_scope += f"/resourceGroups/{args.hub_resource_group}"
        targets.append(("Hub subscription", hub_scope, required["hub"]))
    elif required["hub"]:
        print("Note: --hub-subscription-id not given; skipping the hub DNS/peering role check.\n")

    results = []
    warnings = []
    for label, scope, req in targets:
        try:
            grants, denies, scope_warnings = effective_grants(token, scope, args.principal_id)
        except ArmError as e:
            print(
                f"ERROR: could not read role assignments at {scope}: {e}\n"
                "The identity running this check needs Reader (roleAssignments/read, roleDefinitions/read, "
                "denyAssignments/read) on every scope it checks.",
                file=sys.stderr,
            )
            sys.exit(2)
        warnings.extend(scope_warnings)
        if label == "Tessera subscription":
            for role in role_assignment_write_unconditioned(grants):
                warnings.append(
                    f"'{role}' grants Microsoft.Authorization/roleAssignments/write without an ABAC condition — "
                    "assign role 03 with policies/azure/role-assignment-condition.txt"
                )
        missing = evaluate(req, grants, denies)
        results.append((label, scope, len(req), missing))

    any_missing = False
    for label, scope, checked, missing in results:
        print(f"{label} ({scope}): checked {checked} required permissions for {args.principal_id}")
        if missing:
            any_missing = True
            print(f"  Missing or denied ({len(missing)}):")
            for m in missing:
                print(f"    - {m['action']} [{m['kind']}, {m['decision']}] (required by: {', '.join(sorted(m['sources']))})")
        else:
            print("  All required permissions are present.")
        print()
    for w in sorted(set(warnings)):
        print(f"WARNING: {w}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        write_summary(summary_path, args.principal_id, results, sorted(set(warnings)))

    if any_missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
