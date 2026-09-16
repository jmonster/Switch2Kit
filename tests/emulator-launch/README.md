# Full emulator launch qualification

The `launch` jobs in the emulator integration workflow download the complete application artifacts into fresh macOS runners. They do not rebuild the emulator or install its dependencies. The small AppKit observer is compiled separately with the selected Xcode; it is not linked into either application.

Each job copies the application outside the checkout, gives it a new host-owned user directory, and runs its actual GUI executable twice. A pass requires matching process/executable registration, a layer-zero window at least 100×100, five seconds of continued GUI life, and an ordinary quit request followed by exit zero. A process that exits successfully without opening a window, crashes, hangs, refuses to quit, or requires forced cleanup fails. Observing a first-run dialog does not certify completion of the first-run setup or gameplay.

The application process cannot read `/Applications`, `/Library/Developer`, `/opt/homebrew`, `/usr/local`, or the CI source checkout. Existing blocked roots have explicit denial checks before launch. Its environment omits build settings, tokens, DYLD overrides and Qt plugin paths. No privacy permission is granted or reset, no signature or entitlement is modified, no quarantine attribute is removed, and no synthetic input, Accessibility or screenshot permission is requested. Network access is denied for this startup check. Startup logs are capped at 1 MiB per launch. Only the owned child can be terminated.

The test uses macOS's `sandbox-exec` as a CI-only dependency restriction, not as a product dependency or security boundary for hostile code. It fails rather than silently dropping isolation if that facility is unavailable. These fresh CI images still have preinstalled developer software. A pass is **restricted full-GUI CI startup**, not a stock clean-Mac, Gatekeeper/notarization, Bluetooth, measured-profile, or physical-controller pass. Those acceptance results require a dedicated test Mac and real controllers.

Portable failure-path tests: `bash tests/emulator-launch/run.sh`.
