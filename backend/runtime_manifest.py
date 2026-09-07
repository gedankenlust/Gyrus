"""Record and verify the exact dependencies of a relocatable release runtime.

Create with the runtime's Python after installing requirements-runtime.lock.
Verify needs only Python's standard library and never imports bundled code.
"""
import argparse
import email.parser
import hashlib
import json
import platform
import re
import sys
from pathlib import Path


def normalize(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packages(runtime):
    found = {}
    for metadata in runtime.glob('lib/python*/site-packages/*.dist-info/METADATA'):
        message = email.parser.Parser().parsestr(metadata.read_text())
        name = normalize(message['Name'])
        if name in found:
            raise ValueError(f'Duplicate installed metadata: {name}')
        found[name] = message['Version']
    if not found:
        raise ValueError('Runtime contains no package metadata')
    return dict(sorted(found.items()))


def browsers(runtime):
    roots = list(runtime.glob('lib/python*/site-packages/playwright/driver/package/browsers.json'))
    if len(roots) != 1:
        raise ValueError('Playwright browser manifest missing')
    definitions = json.loads(roots[0].read_text())['browsers']
    entries = {}
    for name, folder in [('chromium-headless-shell', 'chromium_headless_shell'), ('ffmpeg', 'ffmpeg')]:
        definition = next(entry for entry in definitions if entry['name'] == name)
        revision = definition.get('revisionOverrides', {}).get(
            'mac-arm64' if platform.machine() == 'arm64' else 'mac', definition['revision'])
        root = runtime / 'playwright-browsers' / f'{folder}-{revision}'
        if not root.is_dir() or not any(root.rglob('*')):
            raise ValueError(f'Bundled browser component missing: {root.name}')
        entries[name] = revision
    return entries


def create(backend, runtime):
    try:
        from packaging.requirements import Requirement
    except ImportError:
        from pip._vendor.packaging.requirements import Requirement
    expected = {}
    for line in (backend / 'requirements-runtime.lock').read_text().splitlines():
        if not line or line.startswith((' ', '#', '-')):
            continue
        requirement = Requirement(line.rstrip(' \\'))
        if requirement.marker and not requirement.marker.evaluate():
            continue
        pins = list(requirement.specifier)
        if len(pins) != 1 or pins[0].operator != '==':
            raise ValueError(f'Unpinned requirement: {line}')
        expected[normalize(requirement.name)] = pins[0].version
    actual = packages(runtime)
    if actual != expected:
        differences = {name: {'expected': expected.get(name), 'installed': actual.get(name)}
                       for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name)}
        raise ValueError(f'Runtime differs from lock: {differences}')
    result = {
        'schema': 1, 'python': platform.python_version(), 'architecture': platform.machine(),
        'inputs_sha256': sha(backend / 'requirements-runtime.in'),
        'lock_sha256': sha(backend / 'requirements-runtime.lock'),
        'packages': actual, 'browsers': browsers(runtime),
    }
    (runtime / 'gyrus-runtime-manifest.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


def verify(backend, runtime):
    result = json.loads((runtime / 'gyrus-runtime-manifest.json').read_text())
    checks = {
        'schema': 1, 'inputs_sha256': sha(backend / 'requirements-runtime.in'),
        'lock_sha256': sha(backend / 'requirements-runtime.lock'),
        'packages': packages(runtime), 'browsers': browsers(runtime),
    }
    for key, value in checks.items():
        if result.get(key) != value:
            raise ValueError(f'Stale runtime ({key}). Rebuild backend/python-runtime before packaging.')
    print(f"Runtime verified: Python {result['python']}, {len(result['packages'])} locked packages")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['create', 'verify'])
    parser.add_argument('--backend', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    try:
        globals()[args.action](args.backend, args.runtime or args.backend / 'python-runtime')
    except (ValueError, OSError, KeyError) as error:
        print(f'Runtime validation failed: {error}', file=sys.stderr)
        sys.exit(1)
