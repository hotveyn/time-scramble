# Focus Time Scrambler

Migrated from spec-kit `specs/001-focus-time-scrambler/spec.md` (created 2026-06-21, status: Draft) on 2026-11-08. All source IDs are kept: US-x, FR-xxx, SC-xxx (here), R-xxx and Txxx (in `projects/time-scramble/`).

## Summary

A macOS menu-bar app that sets the system clock to a random time within the current calendar day every X minutes (1–120). The user cannot track elapsed time, so they stay absorbed in study or work without clock-watching anxiety. Stopping restores the real time.

Original input: "Build an application that help me to automatic change current time on pc. It should change time to random value every X minutes. It should help user to locked in on their business and be not worried about how much time passed"

## Goals

- Make clock-watching impossible during a focus session (US-1).
- Let the user pick how often the clock changes (US-2).
- Always return the machine to the real time, including after a crash (US-3).
- Stay out of the way: run from the menu bar, no visible window (US-4).

## Non-goals

- Windows and Linux: macOS only in v1.
- Mac App Store distribution: clock modification is disallowed by App Store Review Guidelines §2.5.2.
- Fixing side effects on OS alarms, reminders and scheduled tasks: acknowledged by the user, not solved in v1.
- Changing the hardware clock or network time: only the displayed system time changes, and the real time is always restorable.
- Multi-user or shared machines: personal workstation only.

## Actors

- **User**: one person on their own Mac, with admin rights (needed to grant the clock-change permission).
- **macOS**: shows the authorization dialog and runs `timed`, the NTP daemon that corrects the clock.

## Main scenarios

### US-1. Activate time scrambling (P1)

The user sets the interval and starts scrambling; from then on the system clock shows a random time. Test: 2-minute interval, start, watch the clock change at each interval.

1. Start → clock changes to a random time immediately, then every X minutes.
2. Each interval → new random time, different from the previous one.
3. First start → macOS asks for authorization; scrambling begins only after it is granted.
4. While active → displayed time bears no consistent relationship to real elapsed time.

### US-2. Configure scrambling interval (P1)

The user sets X before or during a session: shorter for more disorientation, longer for a subtler effect.

1. Interval accepts whole minutes from 1 to 120.
2. The last-used interval is pre-filled after the app is reopened.
3. Zero, negative or non-numeric input → human-readable error, scrambling does not start.

### US-3. Stop scrambling and restore real time (P1)

When the session ends, the clock returns to the real time. Test: start, stop, clock is within 5 s of real time.

1. Stop → scrambling halts, clock restored to real time within 5 s.
2. Crash or force-quit → on next launch the app detects the unrestored state and offers to restore real time.
3. After stop → no visible clock discrepancy remains.

### US-4. Run quietly in background (P2)

After start, the app lives in the menu bar; a visible window would remind the user of the tool managing their time.

1. Main window closed or minimized → app keeps running with a menu-bar indicator.
2. Click the icon → menu with Pause, Stop and Open.
3. Icon distinguishes Active from Paused.

### US-5. Pause and resume without losing settings (P3)

Pause for a meeting or a time-sensitive task, then resume with the same settings. Stop + restart gives the same result with more friction.

1. Pause → no further time changes; the clock displays the last scrambled value. (Conflicts with the plan, see Open questions.)
2. Resume → scrambling restarts at the same interval; the clock changes again within X minutes.

## Functional requirements

### Scrambling

- **FR-001**: Change the system clock to a random time at every configured interval while scrambling is active.
- **FR-011**: The random time is within the same calendar day (00:00–23:59), to avoid date-related side effects.
- **FR-007**: Request elevated permissions before modifying the clock; fail with a clear message if denied.

### Interval

- **FR-002**: Interval in whole minutes, 1 to 120.
- **FR-004**: Persist the last-used interval between sessions.
- **FR-010**: Reject zero, negative and non-numeric input with a human-readable message.

### Restore and recovery

- **FR-003**: Restore the real time when the user stops scrambling.
- **FR-008**: Detect a clock left scrambled by a previous session and offer restoration on next launch.

### Background and control

- **FR-005**: Run in the menu bar after start; the main window need not stay open.
- **FR-006**: Show the state (active / paused / stopped) in the menu bar.
- **FR-009**: Pause and resume without restarting the app.

## Edge cases

- **Permission denied**: human-readable error, no clock change, no crash (FR-007).
- **Crash mid-session**: the clock stays scrambled until the next launch offers recovery (FR-008, SC-005).
- **1-minute interval vs NTP**: resolved by stopping `timed` for the session (R-002).
- **Sleep or hibernate while active**: unresolved, see Open questions.
- **User changes the timezone while active**: unresolved, see Open questions.

## Constraints (NFR)

### Success criteria: timing

- **SC-001**: Setup and activation take under 30 s from opening the app.
- **SC-002**: The clock changes within 5 s of each interval elapsing, with zero missed intervals in a 1-hour session.
- **SC-003**: Real time is restored within 5 s of stop.

### Success criteria: reliability and resources

- **SC-004**: No noticeable resource use (no fan spin-up, no sluggishness) during a workday session.
- **SC-005**: 100% of unexpected exits lead to detection and a recovery offer on next launch.
- **SC-006**: Zero cases of the clock staying scrambled after an explicit stop.

### Technical

- macOS 13 Ventura or later; native frameworks only, zero third-party dependencies.
- Not sandboxed (incompatible with `SMJobBless` and `settimeofday()`); signed with Hardened Runtime.
- Privileged operations go only through a helper with minimal surface (R-001).
- Performance: clock change ≤ 500 ms after a tick, app < 10 MB, helper < 5 MB, idle CPU < 0.5%.

### Quality (from spec-kit constitution v1.0.0, ratified 2026-06-21)

- Line coverage ≥ 80% for new code; ≥ 95% for critical paths (`ScramblingService`, `StateRepository`).
- Test names describe behaviour; tests in tiers: unit, integration, end-to-end.
- Every control keyboard-navigable and VoiceOver-compatible; interactions acknowledge within 100 ms.
- Error messages human-readable; no internal codes or stack traces shown to the user.
- Performance targets defined before implementation; a regression > 10% blocks the change.

## Future considerations (out of scope)

- `state.json` reserves a `schemaVersion` field for a future v2 migration; v1 does not write it.
- Cross-platform support (Windows, Linux).
- Handling OS alarms, reminders and scheduled tasks during a session.

## Open questions

1. **Time or timezone?** The user's earlier utility changed the timezone, not the clock. Timezone mode needs no root helper, XPC or NTP suppression and cannot leave the clock wrong, but minutes stay real (except +5:30 / +5:45 style zones). Decide before implementation.
2. **Pause behaviour.** US-5 says the clock shows the last scrambled value while paused; the plan (data model, T013, XPC sequence) restores real time on pause. Pick one.
3. **Signing and permission UX** (T001, T002): Developer ID identity, `SMJobBless` entitlements, CI; dialog wording for error codes 1001–1004.
4. **Sleep / hibernate** while active: re-scramble on wake, or pause?
5. **Timezone changed by the user** while active: ignore, or recompute the day bounds?
