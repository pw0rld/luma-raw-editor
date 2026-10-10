#!/usr/bin/env python3
"""Work around stale duplicate CLT modules in this build, never edit /Library."""
import json
import pathlib
import subprocess
import sys

build = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build-direct').resolve()
build.mkdir(parents=True, exist_ok=True)
developer = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
include = developer / 'usr/include/swift'
roots = []
if (include / 'bridging.modulemap').exists() and (include / 'module.modulemap').exists():
    if 'module SwiftBridging' in (include / 'bridging.modulemap').read_text() and 'module SwiftBridging' in (include / 'module.modulemap').read_text():
        empty = build / 'empty.modulemap'
        empty.write_text('// Hide stale duplicate SwiftBridging in this build only.\n')
        roots.append({'type': 'file', 'name': str(include / 'bridging.modulemap'), 'external-contents': str(empty)})
manifest = developer / 'usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule'
for private in manifest.glob('*.private.swiftinterface'):
    public = private.with_name(private.name.replace('.private', ''))
    if public.exists():
        roots.append({'type': 'file', 'name': str(private), 'external-contents': str(public)})
overlay = build / 'toolchain-overlay.json'
overlay.write_text(json.dumps({'version': 0, 'roots': roots}, indent=2))
print(overlay)
