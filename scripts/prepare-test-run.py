#!/usr/bin/env python3
"""Use bundled Sparkle frameworks in the standalone Xcode test runner.

Keep the generated Xcode test plan intact; normalize TESTROOT and put the app's
framework directory first to avoid loading a different top-level build product.
"""
import pathlib
import plistlib

build = pathlib.Path(__file__).resolve().parents[1] / 'macos' / 'build'
output = build / 'Toastty-tests.xctestrun'
candidates = [p for p in build.glob('*.xctestrun') if p != output]
if not candidates:
    raise SystemExit('No xctestrun found; run macos/build.nu --action build-for-testing first.')
source = max(candidates, key=lambda p: p.stat().st_mtime)
frameworks = str(build / 'Debug' / 'Toastty.app' / 'Contents' / 'Frameworks')


def normalize(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(build))
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        result = {key: normalize(item) for key, item in value.items()}
        if 'DYLD_FRAMEWORK_PATH' in result:
            result['DYLD_FRAMEWORK_PATH'] = frameworks + ':' + result['DYLD_FRAMEWORK_PATH']
        return result
    return value


with source.open('rb') as handle:
    data = normalize(plistlib.load(handle))
with output.open('wb') as handle:
    plistlib.dump(data, handle)
print('Prepared', output)
