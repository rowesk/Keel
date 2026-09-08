#!/usr/bin/env python3
"""Identify the compiled source and bundled assets without recording local paths."""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2])
inputs = [root / 'Package.swift']
inputs += sorted((root / 'Sources').rglob('*'))
inputs += [root / 'Supporting' / name for name in ('Info.plist', 'Keel.entitlements', 'Keel.icns')]
digest = hashlib.sha256()
for path in inputs:
    if path.is_file():
        name = path.relative_to(root).as_posix().encode()
        content = path.read_bytes()
        digest.update(len(name).to_bytes(8, 'big'))
        digest.update(name)
        digest.update(len(content).to_bytes(8, 'big'))
        digest.update(content)

def git(*args):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None

record = {
    'schemaVersion': 1,
    'revision': git('rev-parse', 'HEAD'),
    'sourceSHA256': digest.hexdigest(),
    'hasLocalChanges': bool(git('status', '--porcelain', '--', 'Package.swift', 'Sources', 'Supporting')),
    'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
destination.write_text(json.dumps(record, indent=2) + '\n')
