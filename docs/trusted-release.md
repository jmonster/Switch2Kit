# Release packaging

Run `scripts/notarize-release.py --help` for the release interface. Supply the application, output directory, signing identity, and notary profile explicitly. The tool verifies bundle identity, code signing, source metadata, and packaged resources, submits the app for notarization, staples the result, and records checksums in `build-info.json`.

The release process does not modify application update settings. Automatic updates are disabled. Development builds from `scripts/build-app.sh` use ad-hoc signing unless an identity is supplied.

Keep signing inputs outside source control. Provisioned CoreHID builds require an entitlement file identifying the application's own team and bundle. The release validators and their negative tests are in `tests/release` and `tests/app-identity`.
