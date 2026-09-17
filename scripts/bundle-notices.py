#!/usr/bin/env python3
"""Combine the reviewed, checked-in notices without network or cache dependencies."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
records = json.loads((root / 'licenses/manifest.json').read_text())
parts = ['Toastty — Open Source Notices\n\n', (root / 'NOTICE.md').read_text(), '\n\n']
for record in records:
    path = root / record['file']
    parts += ['=' * 72 + '\n', record['component'] + ': ' + record['file'] + '\n']
    if record.get('source'):
        parts += [record['source'] + '\n']
    parts += ['\n', path.read_text(errors='replace'), '\n\n']
(root / 'macos/Sources/ThirdPartyNotices.txt').write_text(''.join(parts))
