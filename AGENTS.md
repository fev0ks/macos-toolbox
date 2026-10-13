# Working on macOS Toolbox

These instructions apply to the whole repository. Keep application-specific implementation and documentation inside its folder. SpaceHop is currently in `space_hop/`.

## Build and scope

- Read the application README and build script before editing. Use the repository copy as the source of truth, not old app bundles or scratch copies elsewhere on the machine.
- SpaceHop uses AppKit, ApplicationServices, ScreenCaptureKit and ServiceManagement. Build with `cd space_hop && ./build.sh`; its Swift 5 language mode and arm64 macOS 13 deployment target are intentional. There are no external packages.
- The build script creates and ad-hoc signs `space_hop/SpaceHop.app`, then runs `--self-test`. It does not install the app, stop the running copy, or change permissions.
- For source/documentation publication, leave the installed application and its permissions alone. Install only when the task includes updating the installed application.
- Keep changes reviewable. Run checks appropriate to the change and report separately what passed automatically and what the user tested manually.

## Permissions: macOS TCC and the execution environment

- Accessibility is needed for the event tap and window actions. Screen Recording is needed for window snapshots. Users grant these through System Settings; never toggle privacy permissions on their behalf.
- macOS privacy permissions, execution-environment filesystem permissions, file ownership and Unix mode bits are separate mechanisms. Determine which one denied access instead of adding unrelated permissions.
- Screen previews do not require Documents access or Full Disk Access. SpaceHop keeps images only in RAM; do not add disk persistence, telemetry or network transfers without an explicit feature request.
- CLI diagnostics may inherit the terminal/host application's privacy context. `AXIsProcessTrusted()` from a command-line helper does not prove that the Finder-launched `.app` is trusted. Check the running GUI app's status and its own preflight results.
- An enabled System Settings switch can still refer to an old code signature. A rebuild signed ad hoc can invalidate trust even if the bundle identifier is unchanged. Batch edits and checks before replacing an installed app so users do not have to grant permissions repeatedly.
- Keep bundle identifiers stable. SpaceHop currently uses `local.spacehop.app`; changing this requires an intentional migration, including permissions and login registration. Do not invent a signing identity or claim an ad-hoc build is notarized.
- If renewed manual grants and restarting fail, the app's own stale TCC records can be reset with `tccutil reset Accessibility local.spacehop.app` and `tccutil reset ScreenCapture local.spacehop.app`. This revokes trust and requires a new user grant: use it only for an authorized installation/permission repair, explain why, and target only the affected bundle.
- Never reset all apps' permissions, edit the TCC database, disable SIP/Gatekeeper, or request broad access as a workaround. Prefer a configured stable Developer ID identity for distributable builds when available, while checking that the running app is actually trusted.
- Complete the authorized build, checks and installation before asking for the manual grant as the final step. Existing task authorization remains valid; do not add confirmation prompts for routine reversible edits.

## Paths and local diagnostics

- During development, writing diagnostic markers under Documents failed because of macOS privacy restrictions. Use a unique directory under `FileManager.default.temporaryDirectory` or `${TMPDIR:-/tmp}` for temporary fixtures/reports. Do not hard-code a developer's home directory.
- A temporary directory is not a bypass for Accessibility or Screen Recording. Still respect those permissions and distinguish path failures from window-capture failures.
- Reports can contain window titles, project paths, process/window IDs and display identifiers. Keep them local by default. Publish only deliberately reviewed, sanitized summaries.
- Tests that change preferences must use an isolated UserDefaults suite and remove only that suite afterward. Integration checks that use real preferences must restore both values and automatic/manual modes.

## Native windows, Spaces and tests

- Use disposable fixture apps for close, quit, minimize, unsaved-document and drag tests. Never close or terminate the user's real applications to prove a fix.
- SpaceHop's `--verify-*` modes can move Spaces, focus windows or operate on fixtures; inspect the particular mode before running it. `--self-test` is the default non-interactive check.
- Do not run competing copies of a global input interceptor. For an authorized native test, stop only the identified app/test process and restore the intended running copy afterward.
- Keep event-tap callbacks short; queue slow actions onto the main thread. Preserve unrelated key combinations and ordinary two-finger scrolling. Handle key-down, repeats and key-up as a coherent sequence.
- Ctrl + Left/Right started while the left mouse button is held must pass to macOS for native window dragging, including repeats and key-up after the mouse is released. Do not schedule an instant gesture or its failure/pause check for that sequence.
- Tag synthetic Dock events and exclude them from the app's own gesture interception. Keep one transition per horizontal swipe, cancellation, native fallback and edge behavior intact.
- A failed confirmation of an instant transition currently pauses SpaceHop after approximately 0.6 seconds. Do not treat native drag handling or another deliberately passed-through input as a failed instant transition.
- Match exact windows, not just process IDs or similarly named windows. Preserve alphabetical order, active-window highlighting, single pointer/keyboard selection and original-window restoration.
- Use logical NSScreen points and the visible frame for layout. Account for menu bar/Dock margins, offset display origins, per-display UUID preferences, centered incomplete rows and spatial arrow navigation.
- Minimized/off-Space windows may lack capturable content or AXWindows entries. Use existing RAM snapshots or an icon placeholder; do not restore/move a user's window merely to capture it. Keep confirmed Space membership and accessory-window filtering.

## Private APIs, distribution and publication

- SpaceHop loads SkyLight symbols dynamically and also uses `_AXUIElementGetWindow` and undocumented Dock event fields. These are not stable public contracts; record the minimum deployment version and the versions actually tested.
- The minimum deployment version is macOS 13; native behavior was tested on macOS 15.7.4. At the maintainer's request, newer macOS versions are allowed without an upper runtime version gate. Describe them as untested, not confirmed compatible. Do not add an upper version restriction unless explicitly requested. Preserve permission checks, unavailable-symbol/native-input fallback and transition failure handling. Intel remains untested and is not built by the current script.
- Do not claim Mac App Store eligibility for this implementation. Developer ID signing/notarization and App Store review are different processes; neither a license nor a successful local build guarantees distribution approval.
- Preserve root LICENSE and both upstream MIT notices. If importing new material, record source, revision, license and adaptations. Do not redistribute Apple frameworks or private keys.
- Before publishing, inspect the staged diff and file list for personal paths, emails, credentials, screenshots, live-window reports and build artifacts. `.gitignore` is a guardrail, not a substitute for review.
- Git commits use concise imperative English subjects unless a future established repository convention differs. Keep related source and explanatory docs together; split unrelated applications/features.
