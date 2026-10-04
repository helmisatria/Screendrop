#!/usr/bin/env python3
"""Check release identity and version before using signing credentials."""
import argparse
import base64
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

REPOSITORY = "helmisatria/Screendrop"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def validate_release(tag, settings, info, previous_appcast=None):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Release tag must have the form v1.2.3.")
    if tag != "v" + settings["MARKETING_VERSION"]:
        raise ValueError("Release tag must match MARKETING_VERSION.")
    build = int(settings["CURRENT_PROJECT_VERSION"])
    if build < 1:
        raise ValueError("CURRENT_PROJECT_VERSION must be a positive integer.")
    if settings["PRODUCT_BUNDLE_IDENTIFIER"] != "com.fayazahmed.Screendrop":
        raise ValueError("Release must use the Screendrop bundle ID, without .dev.")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("Sparkle feed must belong to our GitHub releases.")
    try:
        public_key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except ValueError as error:
        raise ValueError("Invalid Sparkle public key.") from error
    if len(public_key) != 32:
        raise ValueError("A 32-byte Sparkle public key is required.")
    if previous_appcast is not None:
        versions = previous_appcast.findall(f".//{{{SPARKLE_NAMESPACE}}}version")
        previous_builds = [int(version.text) for version in versions]
        if previous_builds and build <= max(previous_builds):
            raise ValueError("CURRENT_PROJECT_VERSION must exceed every published build.")
    return build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--previous-appcast", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(repo / "Screendrop.xcodeproj/project.pbxproj")
    ]))
    settings = next(obj["buildSettings"] for obj in project["objects"].values()
                    if obj.get("name") == "Release" and "MARKETING_VERSION" in obj.get("buildSettings", {}))
    info = plistlib.loads((repo / "Screendrop/Info.plist").read_bytes())
    previous = ET.parse(args.previous_appcast).getroot() if args.previous_appcast else None
    try:
        build = validate_release(args.tag, settings, info, previous)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    print(f"Validated {args.tag}, build {build}, for {REPOSITORY}.")


if __name__ == "__main__":
    main()
