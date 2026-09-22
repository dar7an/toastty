#!/usr/bin/env python3
"""Fail publication if the feed and its immutable archive disagree."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("url")
    args = parser.parse_args()
    items = ET.parse(args.feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one nightly in the new feed")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.attrib["url"] != args.url:
        raise ValueError("Appcast must point at this build's immutable archive URL")
    if int(enclosure.attrib["length"]) != args.archive.stat().st_size:
        raise ValueError("Archive length mismatch")
    with zipfile.ZipFile(args.archive) as archive:
        bundles = [p for p in archive.namelist() if p.count("/") == 2 and p.endswith(".app/Contents/Info.plist")]
        if len(bundles) != 1:
            raise ValueError("Expected one application bundle")
        info = plistlib.loads(archive.read(bundles[0]))
    version = item.findtext(SPARKLE + "version") or enclosure.get(SPARKLE + "version")
    if version != info["CFBundleVersion"]:
        raise ValueError("Appcast version does not match the packaged application")
    subprocess.run(["swift", str(Path(__file__).with_name("verify-update.swift")),
                    info["SUPublicEDKey"], str(args.archive), enclosure.attrib[SPARKLE + "edSignature"]], check=True)
    print(f"Verified nightly {version}")


if __name__ == "__main__":
    main()
