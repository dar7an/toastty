#!/usr/bin/env python3
"""Export padded macOS asset sizes; retain the approved master unchanged."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
master = root / 'docs/branding/toastty-icon.png'
assets = root / 'macos/Assets.xcassets'
catalog = assets / 'Toastty.appiconset'
catalog.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='toastty-icons-') as temporary:
    padded = Path(temporary) / 'icon.png'
    subprocess.run(['swift', str(root / 'scripts/pad-icon.swift'), str(master), str(padded)], check=True)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f'icon_{points}x{points}@{scale}x.png'
            subprocess.run(['sips', '-z', str(points * scale), str(points * scale),
                            str(padded), '--out', str(catalog / name)], check=True, stdout=subprocess.DEVNULL)
            images.append({'size': f'{points}x{points}', 'idiom': 'mac', 'filename': name, 'scale': f'{scale}x'})
    (catalog / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, indent=2) + '\n')
    about = assets / 'AppIconImage.imageset'
    for size, name in ((256, 'macOS-AppIcon-256px-128pt@2x.png'), (512, 'macOS-AppIcon-512px.png'), (1024, 'macOS-AppIcon-1024px.png')):
        subprocess.run(['sips', '-z', str(size), str(size), str(padded), '--out', str(about / name)], check=True, stdout=subprocess.DEVNULL)
print('Exported Toastty app icon and About images.')
