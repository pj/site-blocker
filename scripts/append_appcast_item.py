#!/usr/bin/env python3
# Appends one <item> to appcast.xml for a new release. Invoked by `just release` — see
# RELEASE.md "Auto-update". Newest item is inserted first (Sparkle doesn't require ordering,
# but keeping newest-first makes the file readable).
import argparse
import sys
from datetime import datetime, timezone
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True, help="CFBundleVersion (build number)")
    p.add_argument("--short-version", required=True, help="CFBundleShortVersionString (marketing version)")
    p.add_argument("--url", required=True, help="GitHub release asset download URL")
    p.add_argument("--length", required=True, help="zip byte size")
    p.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    p.add_argument("--min-system-version", default="15.0")
    args = p.parse_args()

    tree = ET.parse(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit(f"{args.appcast}: no <channel> element found")

    for item in channel.findall("item"):
        v = item.find(f"{{{SPARKLE_NS}}}version")
        if v is not None and v.text == args.version:
            sys.exit(f"appcast.xml already has an item for build {args.version}")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.short_version}"
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.short_version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_system_version
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", args.length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", args.signature)

    # Insert as the first <item> (after title/link/description/language) so the newest release
    # reads first.
    items = channel.findall("item")
    if items:
        channel.insert(list(channel).index(items[0]), item)
    else:
        channel.append(item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    with open(args.appcast, "a") as f:
        f.write("\n")


if __name__ == "__main__":
    main()
