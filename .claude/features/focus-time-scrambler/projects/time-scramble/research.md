# Research: focus-time-scrambler / time-scramble

Migrated from spec-kit `specs/001-focus-time-scrambler/research.md` (Phase 0, 2026-06-21). Decision IDs R-001…R-006 are kept.

| ID | Topic | Decision |
|---|---|---|
| R-001 | Changing the clock | `SMJobBless`-installed XPC helper calls `settimeofday()` |
| R-002 | NTP | Stop `timed` for the session via `launchctl` |
| R-003 | OS target | macOS 13 Ventura |
| R-004 | Sandbox | Off; Hardened Runtime on |
| R-005 | Storage | Pretty-printed JSON in Application Support, atomic writes |

R-006 (testing) is below the table.

## R-001: Privileged time-change mechanism

**Decision**: a signed XPC helper, bundled in the app and installed via `SMJobBless` + Authorization Services, calls `settimeofday()` as root.

**Why**: `settimeofday()` requires root. A small helper under launchd that talks only to the main app over XPC, and validates the caller's code signature, is the narrowest-privilege pattern for a GUI app. `SMJobBless` is marked deprecated in the macOS 13 SDK; `SMAppService` targets persistent daemons/agents, not install-on-demand helpers, and `SMJobBless` behaves the same on macOS 13 and 14.

**Rejected**:
- `NSTask` + `sudo date -s`: shell sudo prompt, no GUI authorization flow, violates FR-007.
- `clock_settime(CLOCK_REALTIME)`: not a settable clock ID on macOS.
- `SMAppService` persistent daemon: always-on lifecycle, not install-on-demand.
- Mac App Store: §2.5.2 forbids clock modification; store requires the sandbox.

## R-002: NTP suppression during scrambling

**Decision**: the helper runs `launchctl bootout system/com.apple.timed` at start, and `launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.timed.plist` on stop or pause.

**Why**: since macOS 10.12 `timed` replaced `ntpd` and corrects a manual change within about 30–90 s, which would undo each scramble before the next tick (SC-002). NTP is never suppressed longer than one active session.

**Rejected**:
- Accept NTP correction: breaks SC-002.
- Scramble faster than NTP (< 30 s): constant clock thrashing; minimum interval is 1 minute (FR-002).
- `systemsetup -setusingnetworktime off/on`: not rejected, but it wraps the same `launchctl` mechanism and spawns an extra process.
- Block NTP port 123 with `pfctl`: disproportionate and hard to reverse cleanly.

## R-003: macOS version

**Decision**: `MACOSX_DEPLOYMENT_TARGET = 13.0`.

**Why**: Ventura was the oldest macOS with security updates at feature date. Every required API exists from macOS 12, but 13 gives cleaner SDK headers and current tooling.

**Rejected**:
- macOS 12: near end of life, no extra users.
- macOS 14: narrows the user base, no API needs it.

## R-004: Sandboxing

**Decision**: no App Sandbox entitlement; code-signed with Hardened Runtime.

**Why**: the sandbox blocks the Authorization calls `SMJobBless` needs and access to launchd system services. The app is not on the App Store (R-001) and has no untrusted network input. Security comes from code signing, XPC caller validation and the minimal helper surface.

**Rejected**:
- Sandbox + App Group container: incompatible with `SMJobBless`.
- Sandbox + temporary entitlements: Apple grants no exception for `settimeofday`.

## R-005: Storage location and format

**Decision**: `~/Library/Application Support/FocusTimeScrambler/state.json`, `JSONEncoder` with `.prettyPrinted`, `JSONDecoder` to read. Atomic writes: encode to a temp file in the same directory, then `FileManager.moveItem(at:to:)` (`rename(2)`).

**Why**: Application Support is the macOS location for app data. Pretty-printed JSON lets a user read `realTimeSnapshot.unixTimestamp` by hand after a crash. Atomic writes prevent the most dangerous failure: a corrupt file that makes recovery impossible. File size < 1 KB.

**Rejected**:
- `UserDefaults`: opaque plist, poor for manual recovery.
- `~/.config/`: Linux (XDG) convention.
- CoreData: overkill for one small document.
- Compact JSON: negligible size gain, worse debuggability.

## R-006: XCTest strategy for a menu-bar app

**Decision**: unit-test all business logic (state machine, JSON encode/decode, time calculation, validation) in an XCTest target. No XCUITest for the menu; UI flows are covered by the manual validation scenarios in `plan.md`.

**Why**: XCUITest cannot reliably query `NSStatusItem` menus in a menu-bar-only app. The logic lives in `ScramblingService`, `StateRepository` and `AppState`, which have no UI dependency. `StatusItemController` is thin glue, checked manually.

**Rejected**:
- Full XCUITest coverage: status-item menus are not reachable.
- Manual-only testing: violates the 80% coverage gate.
