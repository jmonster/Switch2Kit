# Full emulator launch qualification

The `launch` jobs in the emulator integration workflow download the complete application artifacts into fresh macOS runners. They do not rebuild the emulator or install its dependencies. The small AppKit observer is compiled separately with the selected Xcode; it is not linked into either application.

Each job copies the application outside the checkout, creates private, empty host-owned user settings, and runs its actual GUI executable twice. A pass requires matching process/executable registration, a layer-zero window at least 100×100 observed throughout a five-second interval, and an ordinary quit request followed by exit zero. A process that exits successfully without opening a window, crashes, loses its window, refuses to quit, or requires forced cleanup fails. The window observer does not establish gameplay or completion of interactive setup.

## Configured startup, not unattended first-use interaction

Pristine Dolphin and Cemu startup opens first-use modal dialogs that need a person to answer them. Native negative-control runs opened windows but failed ordinary shutdown while those dialogs were pending. They are not counted as successful launches. The automated test instead explicitly seeds minimal offline host settings in the newly created directory:

- Dolphin: `Config/Dolphin.ini` sets `Analytics/Enabled = False` and `Analytics/PermissionAsked = True`, the pinned upstream settings for declining telemetry without showing its question again.
- Cemu: `settings.xml` contains an otherwise empty `content` element with `check_update` and `use_discord_presence` set to `false`. The pinned upstream starts its normal application path when this settings file exists; it initializes an empty MLC under the disposable portable directory.

These are CI fixtures, not motion profiles, personal settings, macOS privacy grants, or evidence that a person completed first-use setup. Existing or symlinked user directories are rejected. Files are exclusively created with mode 0600. `launch.json` records the fixture hash and `pristine_first_run_tested: false`; the phases are `configured-launch` and `repeat-launch`. No emulator source or installed application is modified to skip dialogs. The ordinary-exit assertion remains mandatory, including for timeout and crash regressions.

The application process cannot read `/Applications`, `/Library/Developer`, `/opt/homebrew`, `/usr/local`, or the CI source checkout. Existing blocked roots have explicit denial checks before launch. Its environment omits build settings, tokens, DYLD overrides and Qt plugin paths. No OS privacy permission is granted or reset, no signature or entitlement is modified, no quarantine attribute is removed, and no synthetic input, Accessibility or screenshot permission is requested. Network access is denied for this startup check. The CI-only child has a 1 MiB per-file size limit, bounding startup logs as well as generated files; excessive writes fail rather than becoming a pass. Only the owned child can be terminated.

The test uses macOS's `sandbox-exec` as a CI-only dependency restriction, not as a product dependency or security boundary for hostile code. It fails rather than silently dropping isolation if that facility is unavailable. These fresh CI images still have preinstalled developer software. A pass is **restricted configured full-GUI CI startup and normal shutdown**, not a stock clean-Mac, pristine first-use, Gatekeeper/notarization, Bluetooth, measured-profile, or physical-controller pass. Those acceptance results require a dedicated test Mac and real controllers.

Portable failure-path tests: `bash tests/emulator-launch/run.sh`. This suite is also discovered by `bash tests/run.sh`.
