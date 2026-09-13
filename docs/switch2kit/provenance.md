# Provenance and redistribution blocker

**No application-wide redistribution grant has been established. Do not represent Switch2Kit or its XCFramework as MIT-licensed, otherwise relicensed, or cleared for external redistribution.** The extraction retains existing notices and produces local-development integration/build tooling, not a new license. Permission to distribute source and binaries must be resolved with the relevant rights holders before an external release.

## Inspected evidence

The implementation baseline is `jmonster/Switch2Kit` (formerly `jmonster/switch2mac`) at `c98a15c5673d6d2f989e166dfc1056f4480d5da1`. Its [CREDITS.md](../../CREDITS.md) explicitly says an application-wide license was not supplied and acknowledgments do not grant a license. The source archive and source-level dependency inventory were inspected before extraction; see [extraction audit](extraction-audit.md). No application-wide license file was added by this work.

GitHub's repository metadata identifies the parent/source as **Peterksharma/switch2mac**. Its recursive tree at `ea6719f0a1d6b6986c00aca9ed4169a85c8cc9ae` was inspected on September 12, 2026. The inspected tree does not provide an application-wide license file, and GitHub's license metadata for both repositories was null. Metadata detection alone is not a legal determination; combined with the explicit fork credits and absent grant, it is insufficient to assert redistribution rights. No private agreements or permissions were supplied or inferred.

Primary source records: [upstream tree](https://github.com/Peterksharma/switch2mac/tree/ea6719f0a1d6b6986c00aca9ed4169a85c8cc9ae), [fork baseline](https://github.com/jmonster/Switch2Kit/tree/c98a15c5673d6d2f989e166dfc1056f4480d5da1), and the retained source/header notices.

## Component provenance

| Component | Evidence retained | What this does not establish |
| --- | --- | --- |
| Swift dashboard and controller implementation | Peter Sharma and contributors; upstream source ancestry and original source comments | A package-wide source/binary redistribution license |
| Controller protocol research | Existing references to ndeadly, Nadeflore/Switch2Connect, coffincolors, trevlars, darthcloud/BlueRetro and the research community | Permission to relicense the separate Swift implementation merely because one research project has a permissive license |
| Browser integration | Andrei-Kondrykau contribution link in CREDITS | A new license grant from moving unrelated transport files |
| RetroArch integration | vialoh contribution link in CREDITS | Relicensing of contributed application/output code |
| SDL bridge | Existing pinned-source, patches and license/provenance section in [sdl/README.md](../../sdl/README.md#license-and-provenance) | Licensing of the dashboard or extracted library under SDL's license |
| New extraction/adapters/docs | Changes on the requested PR, with pre-existing notices preserved | An invented license covering all underlying work |

The protocol file's attribution to MIT-licensed research remains an attribution, not a claim that every source line in this repository is MIT. The new framework includes only the stable Swift target, not SDL/browser assets, but narrowing the binary's content does not resolve the underlying controller implementation's missing grant.

## Maintainer release gate

Establish an applicable grant for the application/controller implementation and relevant contributions, retain required notices, and document precisely which source/binary components it covers. Review third-party conditions independently. Do not silently add a license file or substitute acknowledgments for permission. Host signing, notarization and Apple's restricted-entitlement approvals are separate questions and cannot cure an unresolved licensing grant.

Builds, tests and development artifacts can be used to review the engineering work without representing redistribution as cleared. There is no claim here that physical controllers were tested, that Apple notarized a release, or that any external maintainer approved a license. The unresolved permission requirement must remain visible in the package README and distribution guide until actually resolved.
