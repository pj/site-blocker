#!/usr/bin/env python3
"""Publish the Mac's current SiteBlocker rules to a shared JSON config (a public gist).

The Mac is the source of truth; the apps' Settings → Import fetches this config and applies it.
Reuses `gh`'s stored auth to PATCH the gist — no token handled here.

Usage:
  python3 scripts/publish-config.py --print             # build config.json, print to stdout
  CONFIG_GIST_ID=<id> python3 scripts/publish-config.py  # build + push to the gist

The `--print` form is how the gist is first created:
  python3 scripts/publish-config.py --print > /tmp/c.json
  gh gist create /tmp/c.json --public -d "SiteBlocker synced rules"
"""
import json, os, subprocess, sys, datetime

CONFIG_FILENAME = "siteblocker-config.json"
RULES = os.path.expanduser("~/Library/Application Support/SiteBlocker/rules.json")
WEEKDAY = {1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat"}


def collect(cond, out):
    """Flatten a Condition into {days, window} (ignores anything else)."""
    if "onDaysOfWeek" in cond:
        out["days"] = [WEEKDAY[d] for d in sorted(cond["onDaysOfWeek"]["_0"])]
    elif "duringTimeOfDay" in cond:
        w = cond["duringTimeOfDay"]["_0"]
        out["window"] = {"start": "%02d:%02d" % (w["startMinutes"] // 60, w["startMinutes"] % 60),
                         "end": "%02d:%02d" % (w["endMinutes"] // 60, w["endMinutes"] % 60)}
    elif "allOf" in cond:
        for c in cond["allOf"]["_0"]:
            collect(c, out)


def rule_to_config(r):
    source = r.get("source", {})
    entry = {"name": r.get("name", ""), "enabled": r.get("isEnabled", True),
             "domains": [], "blocklistUrl": None}
    # A remote-sourced rule: sync the URL reference (not the resolved list, which can be huge) —
    # the apps fetch the same list. File/manual rules inline their resolved domains.
    if "remote" in source:
        entry["blocklistUrl"] = source["remote"]["_0"]
    else:
        entry["domains"] = [t["domain"] for t in r.get("targets", [])]

    sched = {}
    collect(r.get("condition", {}), sched)
    entry["days"] = sched.get("days")            # None = every day
    entry["window"] = sched.get("window")        # None = all day
    limit = r.get("dailyLimit")
    entry["dailyLimitMinutes"] = round(limit / 60) if limit else None
    return entry


def build_config(rules_path=RULES):
    rules = json.load(open(rules_path))
    return {
        "version": 1,
        "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rules": [rule_to_config(r) for r in rules],
    }


def main():
    config = build_config()
    text = json.dumps(config, indent=2)

    if "--print" in sys.argv:
        print(text)
        return

    gist_id = os.environ.get("CONFIG_GIST_ID")
    if not gist_id:
        sys.exit("error: set CONFIG_GIST_ID or pass --print")
    body = json.dumps({"files": {CONFIG_FILENAME: {"content": text}}})
    subprocess.run(["gh", "api", "-X", "PATCH", f"gists/{gist_id}", "--input", "-"],
                   input=body.encode(), check=True, stdout=subprocess.DEVNULL)
    print(f"→ published {len(config['rules'])} rules to gist {gist_id}")


if __name__ == "__main__":
    main()
