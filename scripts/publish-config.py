#!/usr/bin/env python3
"""Publish the Mac's current SiteBlocker lists to a shared JSON config (a public gist).

The Mac is the source of truth; the apps' Settings → Import fetches this config and applies it.
Reuses `gh`'s stored auth to PATCH the gist — no token handled here. Emits the v2 (site-lists +
ordered Allow/Deny rules) format.

Usage:
  python3 scripts/publish-config.py --print             # build config.json, print to stdout
  CONFIG_GIST_ID=<id> python3 scripts/publish-config.py  # build + push to the gist
"""
import json, os, subprocess, sys, datetime

CONFIG_FILENAME = "siteblocker-config.json"
LISTS = os.path.expanduser("~/Library/Application Support/SiteBlocker/lists.json")
WEEKDAY = {1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat"}


def collect(cond, out):
    """Flatten a Condition into {days, window} (ignores anything else)."""
    if not isinstance(cond, dict):
        return
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
    """An exception window: days + time + optional daily budget (no allow/deny — it's implied)."""
    sched = {}
    collect(r.get("condition", {}), sched)
    limit = r.get("dailyLimit")
    return {
        "days": sched.get("days"),            # None = every day
        "window": sched.get("window"),        # None = all day
        "dailyLimitMinutes": round(limit / 60) if limit else None,
    }


def list_to_config(l):
    source = l.get("source", {})
    entry = {"name": l.get("name", ""), "enabled": l.get("isEnabled", True),
             "blockedByDefault": l.get("isBlockedByDefault", True),
             "domains": [], "blocklistUrl": None,
             "rules": [rule_to_config(r) for r in l.get("rules", [])]}
    # Remote-sourced lists sync the URL reference (not the resolved list); others inline their hosts.
    if "remote" in source:
        entry["blocklistUrl"] = source["remote"]["_0"]
    else:
        entry["domains"] = [t["domain"] for t in l.get("targets", [])]
    return entry


def build_config(lists_path=LISTS):
    lists = json.load(open(lists_path))
    return {
        "version": 2,
        "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lists": [list_to_config(l) for l in lists],
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
    print(f"→ published {len(config['lists'])} lists to gist {gist_id}")


if __name__ == "__main__":
    main()
