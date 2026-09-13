# Application configuration

The dashboard builds as `build/Switch2Kit.app`, with executable `Switch2KitApp` and bundle identifier `wabisabi.ware.gamecubed`. The source library has no application identity; each host supplies its own bundle configuration.

## Build and install

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

Development builds are ad-hoc signed. The app has no automatic updater; install new builds manually.

The app supplies its Bluetooth usage description in `Resources/Info.plist`. Enable Accessibility only for keyboard or mouse output. Library input, the dashboard visualizer, and the standalone example do not require it.

## Signing

`SIGN_IDENTITY` selects a signing identity. A build containing a provisioning profile also requires `PROVISIONING_PROFILE` and `SIGN_ENTITLEMENTS`; the script verifies that the entitlement application identifier matches the team and bundle identifier.

`NOTARY_KEYCHAIN_PROFILE` selects the notarytool profile for notarization. Certificates, profiles, and account credentials are supplied by the developer, not stored in this repository. See [release tooling](trusted-release.md).
