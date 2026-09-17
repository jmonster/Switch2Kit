import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('notices', ROOT / 'scripts/verify-distribution-notices.py')
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class NoticesTests(unittest.TestCase):
    def fixture(self, base, emulator):
        app = base / 'Host with spaces.app'
        for name in notices.NOTICES:
            target = app / 'Contents/Resources/Switch2KitNotices' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / name).read_bytes())
        info = {'CFBundleIdentifier': 'org.dolphin-emu.dolphin' if emulator == 'dolphin' else 'info.cemu.Cemu',
                'NSHumanReadableCopyright': 'Licensed under GPL version 2 or later (GPLv2+)' if emulator == 'dolphin'
                else 'Copyright © 2026 Cemu Project'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app, info

    def test_both_upstream_notices_and_all_source_texts_are_retained(self):
        for emulator in ('dolphin', 'cemu'):
            with tempfile.TemporaryDirectory() as temporary:
                app, info = self.fixture(Path(temporary), emulator)
                result = notices.verify(app, emulator)
                self.assertEqual(result['copyright_notice'], info['NSHumanReadableCopyright'])
                self.assertEqual(set(result['notices']), set(notices.NOTICES))
                self.assertFalse(result['redistribution_permission_verified'])

    def test_missing_empty_or_reassigned_copyright_fails(self):
        for emulator in ('dolphin', 'cemu'):
            for value in (None, '', '   ', 42, '© Switch2Kit'):
                with self.subTest(emulator=emulator, value=value), tempfile.TemporaryDirectory() as temporary:
                    app, info = self.fixture(Path(temporary), emulator)
                    if value is None:
                        del info['NSHumanReadableCopyright']
                    else:
                        info['NSHumanReadableCopyright'] = value
                    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                    with self.assertRaises(ValueError):
                        notices.verify(app, emulator)

    def test_missing_altered_or_symlinked_notice_fails(self):
        for name in notices.NOTICES:
            for defect in ('missing', 'changed', 'symlink'):
                with self.subTest(name=name, defect=defect), tempfile.TemporaryDirectory() as temporary:
                    app, _ = self.fixture(Path(temporary), 'dolphin')
                    target = app / 'Contents/Resources/Switch2KitNotices' / name
                    target.unlink()
                    if defect == 'changed':
                        target.write_text('Not the retained notice')
                    elif defect == 'symlink':
                        target.symlink_to(ROOT / name)
                    with self.assertRaises(ValueError):
                        notices.verify(app, 'dolphin')

    def test_emulator_identity_cannot_be_reassigned(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _ = self.fixture(Path(temporary), 'dolphin')
            with self.assertRaises(ValueError):
                notices.verify(app, 'cemu')

    def test_packagers_copy_notices_before_signing_or_archiving(self):
        app = (ROOT / 'scripts/build-app.sh').read_text()
        self.assertLess(app.index('cp -R LICENSES'), app.index('codesign --force'))
        native = (ROOT / 'scripts/build-switch2kit-c.sh').read_text()
        self.assertLess(native.index('cp -R "$ROOT/LICENSES"'), native.index('ditto -c -k'))
        bundle = (ROOT / 'Integrations/CMake/Bundle.cmake').read_text()
        self.assertIn('LINK_DEPENDS "${_notice_root}/CREDITS.md"', bundle)
        self.assertIn('copy_directory "${_notice_root}/LICENSES"', bundle)
        self.assertNotIn('COMMAND codesign', bundle)
        self.assertIn('verify-distribution-notices.py', (ROOT / 'scripts/build-switch2kit-emulator.sh').read_text())

    def test_scope_does_not_relicense_inherited_code(self):
        text = (ROOT / 'LICENSES/README.md').read_text()
        self.assertIn('No project-wide license grant was found', text)
        self.assertIn('not Switch2Kit as a whole', text)
        self.assertIn('Permission is hereby granted', (ROOT / 'LICENSES/MIT-trevlars.txt').read_text())
        self.assertIn('This notice may not be removed', (ROOT / 'LICENSES/SDL-zlib.txt').read_text())


if __name__ == '__main__':
    unittest.main()
