# App configuration

The menu-bar application is **Switch2Kit**, its executable target is `Switch2KitApp`, and its bundle identifier is `wabisabi.ware.gamecubed`.

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

Builds without a signing identity are ad-hoc signed. For a Developer ID build, supply `SIGN_IDENTITY`. A provisioned build additionally requires `PROVISIONING_PROFILE` and `SIGN_ENTITLEMENTS`; the build validates that the supplied entitlement identifiers match the bundle and team. CoreHID output requires the corresponding entitlement. These settings belong to the application, not the library.

The app supplies its Bluetooth usage description in `Resources/Info.plist`. Keyboard and mouse output request Accessibility access when enabled. Library consumers and the independent navigation example do not need Accessibility access.

Automatic updates are disabled. Install builds manually. Launch at Login and output preferences are managed in the app. The About window displays the version, source revision, and whether source changes were present at build time.

`bash scripts/package-dev.sh` verifies and packages the built app with its browser resources and SHA-256 checksum. `scripts/notarize.sh` requires explicit signing and notarization configuration.
