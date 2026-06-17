#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Compares nsg_live_bundle.json vs nsg_baseline_bundle.json; writes nsg_diff_issues.json
# Env: COMPARE_DEFAULT_RULES (true|false), IGNORE_RULE_PREFIXES (comma, optional)
# -----------------------------------------------------------------------------

LIVE="${NSG_LIVE_BUNDLE:-nsg_live_bundle.json}"
BASE="${NSG_BASELINE_BUNDLE:-nsg_baseline_bundle.json}"
OUT="nsg_diff_issues.json"
export COMPARE_DEFAULT_RULES="${COMPARE_DEFAULT_RULES:-false}"
export IGNORE_RULE_PREFIXES="${IGNORE_RULE_PREFIXES:-}"
export LIVE
export BASE
export OUT

if [ ! -f "$LIVE" ] || [ ! -f "$BASE" ]; then
  echo '[]' | jq '.' > "$OUT"
  echo "Missing $LIVE or $BASE; wrote empty diff issues"
  exit 0
fi

python3 << 'PY'
import json
import os

live_path = os.environ["LIVE"]
base_path = os.environ["BASE"]
out_path = os.environ["OUT"]
use_def = os.environ.get("COMPARE_DEFAULT_RULES", "false").lower() == "true"
ign = [x.strip() for x in os.environ.get("IGNORE_RULE_PREFIXES", "").split(",") if x.strip()]

def skip(name):
    return any(name.startswith(p) for p in ign)

def collect_rules(nsg):
    rules = list(nsg.get("securityRules") or [])
    if use_def:
        rules.extend(nsg.get("defaultSecurityRules") or [])
    out = {}
    for r in rules:
        name = r.get("name")
        if not name or skip(name):
            continue
        out[name] = r
    return out

with open(live_path, encoding="utf-8") as f:
    live = json.load(f)
with open(base_path, encoding="utf-8") as f:
    base = json.load(f)

issues = []
bmap = {}
for nsg in base.get("nsgs") or []:
    k = (nsg.get("resourceGroup") or "") + "|" + (nsg.get("name") or "")
    bmap[k] = nsg

for nsg in live.get("nsgs") or []:
    k = (nsg.get("resourceGroup") or "") + "|" + (nsg.get("name") or "")
    b = bmap.get(k)
    if not b:
        issues.append({
            "title": "NSG `%s` missing from baseline" % nsg.get("name"),
            "details": "No baseline NSG for key=%s" % k,
            "severity": 4,
            "next_steps": "Add this NSG to the baseline bundle or narrow NSG_NAMES scope.",
        })
        continue
    lr = collect_rules(nsg)
    br = collect_rules(b)
    for name in set(br) - set(lr):
        issues.append({
            "title": "Rule removed vs baseline: `%s` in NSG `%s`" % (name, nsg.get("name")),
            "details": "Baseline contained rule `%s` but live NSG does not." % name,
            "severity": 3,
            "next_steps": "Restore the rule from baseline or update the baseline if it was intentionally removed.",
        })
    for name in set(lr) - set(br):
        issues.append({
            "title": "Extra rule vs baseline: `%s` in NSG `%s`" % (name, nsg.get("name")),
            "details": "Live NSG has rule `%s` not present in baseline." % name,
            "severity": 3,
            "next_steps": "Remove unauthorized rule or add it to your declared baseline.",
        })
    for name in set(lr) & set(br):
        if lr[name] != br[name]:
            issues.append({
                "title": "Changed rule `%s` in NSG `%s`" % (name, nsg.get("name")),
                "details": json.dumps({"live": lr[name], "baseline": br[name]}),
                "severity": 3,
                "next_steps": "Reconcile via Terraform or refresh the baseline export after review.",
            })

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(issues, f, indent=2)
print("Wrote", len(issues), "diff issue(s)")
PY
