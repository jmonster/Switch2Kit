# Release builds

## Sign and notarize

Use your Apple Developer ID Application identity and an existing `notarytool` Keychain profile. Keep credentials out of source and CI logs.

```sh
SIGN_IDENTITY='Developer ID Application: YOUR IDENTITY' bash scripts/build-app.sh
bash tests/run.sh
python3 scripts/notarize-release.py \
  --app 'build/Switch2Kit.app' \
  --output build/notarized-candidate \
  --team-id YOURTEAMID \
  --keychain-profile YOUR_EXISTING_PROFILE
```

The notarization command submits a staged copy to Apple. The output directory must not exist. Team ID is ten uppercase letters or digits. A virtual-HID build additionally needs matching entitlements and provisioning inputs supplied to `build-app.sh`.

The packager verifies the Developer ID signature, team, secure timestamp, hardened runtime, clean source metadata, and Mach-O architectures. It submits the ZIP, waits for acceptance, staples and validates the app, checks Gatekeeper assessment, and creates the final ZIP. Failed checks leave the input app unchanged and prevent output publication.

## Outputs

The output directory contains the stapled app ZIP, SHA-256 checksum, `build-info.json`, and Apple's receipt and log. The packager does not publish a release or enable the updater. Build identity and signing inputs are described in [application configuration](app-identity.md).

Verify installation, first-run Bluetooth permission, controller input, output mapping, reconnect, and upgrades on the target macOS versions before publishing a release.

## Tests

`bash tests/release/run.sh` covers successful and rejected command responses, staging cleanup, exact metadata, and signing validation. On macOS it also verifies that an ad-hoc signed app is rejected before submission.

[Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
