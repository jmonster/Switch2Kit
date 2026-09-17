#!/usr/bin/env python3
"""Check bundled source notices and upstream Finder metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
NOTICES = ('CREDITS.md', 'LICENSES/README.md', 'LICENSES/MIT-trevlars.txt', 'LICENSES/SDL-zlib.txt')


def verify(app, emulator, root=ROOT):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected_id = {'dolphin': 'org.dolphin-emu.dolphin', 'cemu': 'info.cemu.Cemu'}[emulator]
    if info.get('CFBundleIdentifier') != expected_id:
        raise ValueError('Unexpected host bundle identifier')
    notice = info.get('NSHumanReadableCopyright')
    if not isinstance(notice, str) or not notice.strip() or not (
            'GPL' in notice if emulator == 'dolphin' else 'Cemu' in notice):
        raise ValueError('Missing or replaced upstream Finder copyright/license notice')
    digests = {}
    for name in NOTICES:
        source = root / name
        bundled = app / 'Contents/Resources/Switch2KitNotices' / name
        if not bundled.is_file() or bundled.is_symlink() or bundled.read_bytes() != source.read_bytes():
            raise ValueError('Missing or altered bundled notice: ' + name)
        digests[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    return {'version': 1, 'emulator': emulator, 'copyright_notice': notice,
            'notices': digests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('emulator', choices=('dolphin', 'cemu'))
    parser.add_argument('source', type=Path)
    parser.add_argument('build', type=Path)
    options = parser.parse_args()
    report = options.build / 'integration-notices.json'
    report.unlink(missing_ok=True)
    directory = options.build / 'Binaries' if options.emulator == 'dolphin' else options.source / 'bin'
    apps = [app for app in directory.glob('*.app')
            if (app / 'Contents/Frameworks/libSwitch2KitC.dylib').is_file()]
    if len(apps) != 1:
        raise ValueError('Expected exactly one integrated application')
    result = verify(apps[0], options.emulator)
    report.write_text(json.dumps(result, indent=2) + '\n')
    print('PASS bundled notices and upstream Finder metadata')


if __name__ == '__main__':
    main()
