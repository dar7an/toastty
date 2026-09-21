#!/usr/bin/env python3
"""Package a ReleaseLocal build as the isolated, ad-hoc signed nightly app."""
import argparse
import base64
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
FEED = "https://github.com/dar7an/toastty/releases/download/nightly/appcast.xml"
PUBLIC_KEY = "Hn2NPlSfqqePsspryg4brTyHpwO7FFaV0yZd/7WbNw4="


def metadata(info, build, commit, test_feed=None, public_key=PUBLIC_KEY):
    if not re.fullmatch(r"[1-9][0-9]*\.[1-9][0-9]*", build):
        raise ValueError("Build must be a positive run-number.attempt, for example 18.1")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Commit must be a full Git SHA")
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("Expected a 32-byte public Ed25519 key")
    if info["CFBundleIdentifier"] != "com.dar7an.toastty.local":
        raise ValueError("Package a ReleaseLocal build, never the pinned release")
    if test_feed:
        url = urlparse(test_feed)
        if url.scheme != "http" or url.hostname != "127.0.0.1":
            raise ValueError("Test feeds must be served on http://127.0.0.1")
    elif public_key != PUBLIC_KEY:
        raise ValueError("Production nightlies must use the checked-in public key")
    result = dict(info)
    name = "Toastty Nightly Test" if test_feed else "Toastty Nightly"
    result.update({
        "CFBundleIdentifier": "com.dar7an.toastty.nightly" + (".test" if test_feed else ""),
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleVersion": build,
        "CFBundleShortVersionString": build,
        "GhosttyCommit": commit,
        "GhosttyBuild": "nightly",
        "SUFeedURL": test_feed or FEED,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": True,
        "SUScheduledCheckInterval": 21600,
        "SUEnableSystemProfiling": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
    })
    if test_feed:
        result["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--test-feed", help="Loopback feed; always uses a separate test app identity")
    parser.add_argument("--public-key", default=PUBLIC_KEY, help="Override only for the isolated test app")
    args = parser.parse_args()
    source = ROOT / "macos/build/ReleaseLocal/Toastty.app"
    info = metadata(plistlib.loads((source / "Contents/Info.plist").read_bytes()),
                    args.build, args.commit, args.test_feed, args.public_key)
    output = ROOT / "macos/build" / ("NightlyTest" if args.test_feed else "Nightly")
    output.mkdir(parents=True, exist_ok=True)
    app = output / (info["CFBundleName"] + ".app")
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if str(app) + "/Contents/" in processes:
        raise RuntimeError("Quit the packaged nightly before replacing its build output")
    archive = output / f"Toastty-Nightly-{args.build}.zip"
    if archive.exists():
        raise FileExistsError(f"Refusing to replace an immutable archive: {archive}")
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        staged = Path(temporary) / app.name
        subprocess.run(["ditto", str(source), str(staged)], check=True)
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for name in ("LICENSE", "NOTICE.md"):
            shutil.copy2(ROOT / name, staged / "Contents/Resources" / name)
        # Keep Sparkle's own signed helpers intact. Only the host bundle changes.
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                        "--entitlements", str(ROOT / "macos/GhosttyReleaseLocal.entitlements"),
                        str(staged)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
        if app.exists():
            shutil.rmtree(app)
        staged.rename(app)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    print(app)
    print(archive)


if __name__ == "__main__":
    main()
