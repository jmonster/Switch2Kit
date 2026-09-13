# Application identity and signing

The dashboard uses the requested bundle identifier **`wabisabi.ware.gamecubed`** and application filename **`Finally the Controller Works (jmonster).app`**. Its executable remains `FinallyTheControllerWorks`. Switch2Kit itself has no application identity; independent hosts use their own bundle IDs and privacy declarations.

## Explicit correction from the inspected GitHub baseline

The extraction baseline `c98a15c5673d6d2f989e166dfc1056f4480d5da1` used `io.github.jmonster.switch2mac` in its plist. Earlier documentation incorrectly described `io.github.switch2mac.gamecubed` and `GameCubed.app`. The Switch2Kit migration explicitly corrects the plist and runtime/release validators to the owner-requested `wabisabi.ware.gamecubed`. This was a deliberate requested change, not a claim that the baseline already matched.

A changed bundle identifier requires macOS privacy approvals, launch-at-login registration and preferences to be established for the new application identity. Settings are not silently migrated. Existing log and settings-archive directory names remain unchanged to avoid rewriting stored files. Bluetooth bonds are not deliberately erased by an application-name or bundle-identifier correction.

## Safeguards retained

Automatic updates, saved feed overrides and download/install entry points remain disabled. Install builds manually. Enabling an updater requires a signing identity, a trusted feed, bundle verification and a rollback policy; the signature verifier remains in place.

`bash scripts/build-app.sh` creates an ad-hoc development bundle by default. Signing with an embedded provisioning profile requires **SIGN_IDENTITY**, **PROVISIONING_PROFILE**, and an explicit **SIGN_ENTITLEMENTS** file. Its application identifier must match the bundle identifier and stated team. The historical upstream entitlement sample is not automatically reused. Local metadata checks do not establish Apple's runtime/profile or restricted-entitlement approval.

Notarization still requires developer-supplied **SIGN_IDENTITY** and **NOTARY_KEYCHAIN_PROFILE**. No certificate, keychain account or update feed is built in. No release was notarized as part of the extraction. See [trusted-release requirements](trusted-release.md) and [redistribution provenance](switch2kit/provenance.md) before distributing.
