"""Application metadata, removed-updater boundary, and fail-closed signing guards."""
from pathlib import Path
import os
import plistlib
import subprocess

root = Path(__file__).resolve().parents[2]
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'wabisabi.ware.gamecubed'
assert info['CFBundleExecutable'] == 'Switch2KitApp'
assert 'Peter Sharma' in info['NSHumanReadableCopyright']
# Automatic installation is removed, not merely disabled by a preference.
app = root / 'Sources/Switch2KitApp'
assert not (app / 'UI/Updater.swift').exists()
for path in app.rglob('*.swift'):
    source = path.read_text()
    for removed in ('Updater', 'AppcastEntry', 'updateFeedURL', 'updateLastCheck'):
        assert removed not in source, f'Stale update dependency {removed}: {path}'
# No signed build or credentials are accessed by these negative controls.
env = dict(os.environ)
for name in ('SIGN_IDENTITY', 'SIGN_ENTITLEMENTS', 'NOTARY_KEYCHAIN_PROFILE', 'PROVISIONING_PROFILE'):
    env.pop(name, None)
def rejected(script, expected):
    result = subprocess.run(['bash', str(root / script)], env=env, capture_output=True, text=True, timeout=3)
    assert result.returncode != 0 and expected in result.stderr, result.stderr
rejected('scripts/notarize.sh', 'Supply your own Developer ID')
env['SIGN_IDENTITY'] = 'test-only-not-a-certificate'
rejected('scripts/notarize.sh', 'Supply your own notarytool')
env['PROVISIONING_PROFILE'] = '/nonexistent-test-profile'
rejected('scripts/build-app.sh', 'Provide an application entitlement plist')
print('PASS application metadata, attribution, and fail-closed signing configuration')
