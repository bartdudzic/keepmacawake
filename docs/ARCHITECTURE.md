# Keep Mac Awake architecture

This document describes version 1.0 as the code in this repository implements it. Links point to the source of each concept. The menu bar app, the per-user coordinator and the `keepmacawake` command are closed source; they appear here only at their interface with the core.

## Parts and privileges

| Part | Runs as | Started by | Source |
| --- | --- | --- | --- |
| Controller (`KeepMacAwakeHelper --controller`) | root | LaunchDaemon `com.keepmacawake.Helper` | [main.swift](../Sources/KeepMacAwakeHelper/main.swift), [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift) |
| Watchdog (`KeepMacAwakeHelper --watchdog`) | root | LaunchDaemon `com.keepmacawake.Watchdog` | same executable |
| Recovery (`--recover`) | root | install and uninstall scripts | [main.swift](../Sources/KeepMacAwakeHelper/main.swift) |
| Installation check (`--validate-installation`) | root | install script | [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift) |
| Coordinator `KeepMacAwakeCoordinator` | the console user | LaunchAgent `com.keepmacawake.Coordinator`, on demand | closed source |
| Menu bar app, `keepmacawake` command | the user | the user | closed source |

One executable serves all four root modes. It exits unless it runs as root with exactly one of these fixed arguments. No mode accepts a path, a command or a setting from a client.

The LaunchDaemons ([Helper](../Packaging/LaunchDaemons/com.keepmacawake.Helper.plist), [Watchdog](../Packaging/LaunchDaemons/com.keepmacawake.Watchdog.plist)) set `RunAtLoad`, `KeepAlive`, `ThrottleInterval` 3, `ExitTimeOut` 5, `ProcessType` `Interactive` and `Umask` 63 (files are created without group or other access). Only the controller has a Mach service, `com.keepmacawake.Helper`. The watchdog has no XPC interface.

Requests flow one way: app or command, then coordinator (XPC, per user), then controller (XPC, privileged Mach service). The controller and the watchdog talk only through heartbeat files, a shared lock file and two data-free Darwin notifications.

Modules:

| Module | Role | Files |
| --- | --- | --- |
| `KeepMacAwakeCore` | Read-only power source, battery and lid readings | [SystemProbe.swift](../Sources/KeepMacAwakeCore/SystemProbe.swift), [PowerSnapshot.swift](../Sources/KeepMacAwakeCore/PowerSnapshot.swift) |
| `KeepMacAwakeControlProtocol` | Constants, XPC request and status, trust format | [ControlProtocol.swift](../Sources/KeepMacAwakeControlProtocol/ControlProtocol.swift) |
| `KeepMacAwakeControlCore` | `SleepDisabled` transaction and restoration journal | [SleepTransaction.swift](../Sources/KeepMacAwakeControlCore/SleepTransaction.swift), [RecoveryJournal.swift](../Sources/KeepMacAwakeControlCore/RecoveryJournal.swift), [NativeSleepBackend.swift](../Sources/KeepMacAwakeControlCore/NativeSleepBackend.swift) |
| `KeepMacAwakeServiceSupport` | Session rules, power rules, supervision decisions, file checks | [SessionPolicy.swift](../Sources/KeepMacAwakeServiceSupport/SessionPolicy.swift), [SessionPowerPolicy.swift](../Sources/KeepMacAwakeServiceSupport/SessionPowerPolicy.swift), [PeerSupervision.swift](../Sources/KeepMacAwakeServiceSupport/PeerSupervision.swift), [ServiceFileValidation.swift](../Sources/KeepMacAwakeServiceSupport/ServiceFileValidation.swift) |
| `KeepMacAwakeHelper` | Process modes, XPC, timers, signals, launchd fencing, secure files | [main.swift](../Sources/KeepMacAwakeHelper/main.swift), [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift), [SecureState.swift](../Sources/KeepMacAwakeHelper/SecureState.swift) |

## Trust chain

Every connection is pinned to one exact build.

1. **Build.** Each of the four executables (helper, app, coordinator, command) is signed with its own identifier. The build reads each cdhash and forms a requirement of exactly this shape: `identifier "<identifier>" and cdhash H"<40 hex digits>"`. It writes all four into `trust.json` and puts the helper's requirement alone into the app bundle as `helper-trust.json`, sealed by the app's signature.
2. **Installation.** The package installs `trust.json` in `/Library/PrivilegedHelperTools/com.keepmacawake`. The [postinstall script](../Packaging/InstallScripts/postinstall) refuses symbolic links, sets root:wheel and mode 0644, then runs `--validate-installation`. That mode checks the state directory and verifies the signatures of the installed helper, app, coordinator and command against the four requirements. A mismatch stops the installation before any service loads.
3. **Reading the trust file.** The helper opens it through `SecureDirectory` ([SecureState.swift](../Sources/KeepMacAwakeHelper/SecureState.swift)): every path component must be a root-owned directory that group and others cannot write, opened without following links; the file must be a root-owned regular file with one link, at most 16 KiB. Each requirement must match the exact shape (`InstallationTrust.isExact` in [ControlProtocol.swift](../Sources/KeepMacAwakeControlProtocol/ControlProtocol.swift)) and compile. Broader expressions are refused.
4. **Controller listener.** It requires the coordinator's requirement (`setConnectionCodeSigningRequirement`) and accepts a connection only if its effective user ID is the current console user. Each request checks the console user again.
5. **Coordinator (closed source).** It connects to the controller as a privileged Mach service and requires the helper requirement from `helper-trust.json`. Its own listener requires the app's or the command's requirement from the root-owned `trust.json`, and the caller's user ID must equal its own. The app and the command require the coordinator's requirement from `trust.json` before they send anything.

All parts must therefore come from the same build. A partial update fails the signature checks or the protocol version check below.

The console user comes from `SCDynamicStoreCopyConsoleUser`. Root, `loginwindow` and `_mbsetupuser` count as no console user, so no session can start or continue for them.

## XPC interface

`KeepMacAwakeServiceProtocol` ([ControlProtocol.swift](../Sources/KeepMacAwakeControlProtocol/ControlProtocol.swift)) has one method: `request(_ data: Data, withReply: (Data) -> Void)`. The request is JSON `ControlRequest`, at most 4096 bytes. The reply is JSON `ControlStatus`.

| Kind | Allowed fields | Effect |
| --- | --- | --- |
| `status` | none | Current state. The session ID is shown only to the connection that owns it |
| `start` | `durationSeconds`: 0 (no limit) or whole hours from 1 to 168; optional `minimumBatteryPercent` 1-100 (absent means AC only) | Creates a session with a random ID bound to this connection and user |
| `renew` | `sessionID` | Extends the lease of the owned session |
| `stop` | optional `sessionID` | Ends the owned session and restores the setting |

`ControlStatus` carries `phase` (`unavailable`, `idle`, `starting`, `active`, `waitingForAC`, `restoring`, `failed`), a message, the session ID, remaining seconds, the battery threshold, `isUnlimited`, a `terminationReason` from a closed list (unknown codes decode as `unknown`) and `version`.

**Protocol version.** `ControlConstants.version` is `1.1` and is sent in every status. The client refuses a status with another version, so a helper left from an older build is not trusted.

**Refusals.** A Start that is refused has phase `failed`, no session ID and no termination reason, and nothing was changed. Any failure after a session exists carries a termination reason. Start is refused while a session or a restoration exists, when power conditions do not allow it, when the watchdog is not fresh, and when the watchdog does not answer the Start wake in time (see [Supervision cadence](#supervision-cadence)).

The session rules live in [SessionPolicy.swift](../Sources/KeepMacAwakeServiceSupport/SessionPolicy.swift); the XPC handling in [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift).

## Session lifecycle

| Concept | Behavior | Constant |
| --- | --- | --- |
| Lease | Each Start or Renew sets the lease to now plus 12 s. Expiry is evaluated before a Renew is applied, so a late Renew cannot revive a session. The coordinator renews every 2 s with a 3 s request timeout (client values) | `leaseSeconds` = 12 |
| Timed end | The deadline is fixed at Start plus the duration; renewals do not move it. The controller ends the session on its next tick after the deadline (`durationElapsed`). A no-limit session has no deadline but still needs its lease | `sessionHours` = 1...168 |
| Disconnect | When the owning XPC connection is invalidated or interrupted, the session ends at once (`disconnected`) | none |
| Console user | The session belongs to the console user at Start. Any change ends it (`consoleUserChanged`) | none |
| Watchdog | The watchdog must stay fresh and keep the generation it had at Start (`watchdogUnavailable`, `watchdogRestarted`) | `peerTimeoutSeconds` = 8 |
| Stop, SIGTERM | Stop from the owning connection ends the session (`clientStopped`). SIGTERM makes the controller restore the setting and exit (`serviceStopping`) | `ExitTimeOut` 5 |

During a session the controller ticks every second. Each tick checks, in this order: lease, deadline, console user, watchdog freshness, watchdog generation, power. It then turns the setting on if needed and verifies it.

**Power rules** ([SessionPowerPolicy.swift](../Sources/KeepMacAwakeServiceSupport/SessionPowerPolicy.swift)). The controller and the watchdog each read power themselves ([SystemProbe.swift](../Sources/KeepMacAwakeCore/SystemProbe.swift)). The reading uses exactly one present internal battery; a UPS or accessory battery is ignored, and anything else is unknown. A Mac without a built-in battery (Mac mini, iMac, Mac Studio, Mac Pro) is recognized only when three signals agree: the power source list has no internal battery entry at all, the power manager has no lid state, and the kernel has no `AppleSmartBattery` service. Its source is then the one macOS reports as providing power, which is AC unless a UPS runs on its battery; a UPS on battery counts as battery with no level. A MacBook keeps its battery service even when the other two signals are briefly missing (early in boot), so a failed battery read there stays unknown. The later signals are read only when the earlier ones already point to a desktop.

| Condition | AC-only session | Battery session with threshold N |
| --- | --- | --- |
| On AC | allowed | allowed |
| On battery | pause (`waitingForAC`): the setting is restored, the session stays while renewed and resumes on AC | allowed while the battery is above N |
| Source unknown | pause, like no AC | ends (`powerUnknown`) |
| Battery level unknown or invalid | not read | ends (`batteryUnknown`) |
| Battery at or below N | not read | ends (`batteryThresholdReached`); AC does not resume it |
| Thermal state `serious` or `critical` (or an unknown future state) | not read | ends on battery (`thermalUnsafe`) |

Start on battery requires a level strictly above N. A Start refused for missing or unknown power explains the actual cause. The thermal state comes from `ProcessInfo.thermalState`; `nominal` and `fair` count as safe.

Just before the first write, inside the lock, the controller checks time, power, console user and watchdog again, so a condition that changed during Start prevents the write.

## SleepDisabled transaction and restoration journal

The only setting the core changes is `SleepDisabled` in the `SystemPowerSettings` dictionary of `com.apple.PowerManagement` (any user, current host), written with CFPreferences and announced with the `com.apple.system.powermanagement.prefschange` notification. The kernel value is read from `IOPMrootDomain` ([NativeSleepBackend.swift](../Sources/KeepMacAwakeControlCore/NativeSleepBackend.swift)).

Every operation runs under an exclusive `flock` on `transaction.lock`, which is never awaited without a bound: the controller tries 5 times 20 ms apart (about 100 ms), other callers once ([SecureState.swift](../Sources/KeepMacAwakeHelper/SecureState.swift), [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift)).

**Turning on** (`SleepTransaction.activate` in [SleepTransaction.swift](../Sources/KeepMacAwakeControlCore/SleepTransaction.swift)):

1. Under the lock, the controller first publishes a blocking heartbeat, so the watchdog never takes the new journal for an orphan.
2. Refuse if a journal already exists, if `SleepDisabled` is already true (another tool may hold it; it is never taken over), if the value is not a strict boolean, or if the kernel does not report false.
3. Record the original state (`containerAbsent`, `keyAbsent` or `falseValue`) in a journal with phase `prepared`, written durably.
4. Read again. If the value changed, remove the journal and refuse.
5. Save phase `changing` durably. This precedes any write.
6. Read again and merge: keep every other key, set `SleepDisabled` to true. Check the authorization again.
7. Write, wait up to 1.5 s for the kernel to report true, then verify.

**Verifying.** Every tick checks that the journal is in phase `changing`, the preference is true and the kernel reports true. Anything else ends the session (`backendVerificationFailed`) and restores.

**Restoring** (`SleepTransaction.restore`):

- No journal: nothing to do.
- `prepared`: no setting was changed; remove the journal.
- `changing`: if the preference or the kernel is on, write false and wait up to 1.5 s for the kernel to report false. Save phase `kernelRestored`.
- `kernelRestored` (repeatable): put back the original. `falseValue` keeps false; `keyAbsent` removes the key; `containerAbsent` also removes the dictionary if nothing else was added. Verify, then remove the journal.

A conflict (the setting turned on again after the kernel was restored, or the original key or dictionary removed by someone else) leaves the journal in place. The controller retries every second, and no new Start is accepted until restoration succeeds.

**Journal file** ([RecoveryJournal.swift](../Sources/KeepMacAwakeControlCore/RecoveryJournal.swift)). `sleep-recovery.json` holds exactly three fields: `schemaVersion` (1), `original` and `phase`. It must be a root-owned regular file with mode 0600, one link and 1 byte to 16 KiB, in a root-owned directory that group and others cannot write. It is written to a temporary file, flushed with `fsync` and `F_FULLFSYNC`, renamed atomically, and the directory is flushed. If a removal cannot be flushed, the record is written back. A journal that cannot be read or validated counts as a pending restoration and blocks any new activation.

CFPreferences has no compare-and-swap. A tool that writes the same dictionary at the same moment is outside the guarantee; the repeated reads above narrow that window but cannot close it.

## Watchdog supervision and fencing

**Heartbeats** (`PeerHeartbeat` in [PeerSupervision.swift](../Sources/KeepMacAwakeServiceSupport/PeerSupervision.swift)). Each service replaces its heartbeat file on every tick. The controller's heartbeat carries its generation, time, readiness, session user, session ID, lease and deadline, whether it is blocking (starting, active or restoring), the battery threshold, the no-limit flag, whether a restoration is pending, and the boot session ID. A heartbeat is fresh only if it comes from this boot (`kern.bootsessionuuid`), is ready, and is less than 8 s old and not in the future. Time is `mach_continuous_time`: it counts sleep and ignores wall clock changes.

**What the watchdog does each tick** (`WatchdogAssessment` in [PeerSupervision.swift](../Sources/KeepMacAwakeServiceSupport/PeerSupervision.swift), `superviseOnce` in [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift)):

- No readable controller heartbeat: fence.
- An idle controller (ready, not blocking, nothing to restore, no session fields, this boot) is never fenced for its age.
- Stale heartbeat, invalid session fields, expired lease, a console user other than the session user, or a timed session more than 4 s past its deadline: fence at once.
- Environmental cutoff, judged on the watchdog's own power and thermal reading: the controller gets 2 s to restore by itself, then it is fenced. A battery cutoff the watchdog has seen stays in force for that session even if AC returns or the level rises.
- Controller not blocking: check, under the lock, for a journal without an active session. If one exists, recover.
- An idle controller whose heartbeat stays unchanged for 180 s of awake time (measured on uptime, which pauses during sleep) is restarted.
- After a recovery, the watchdog waits 8 s before fencing a fresh controller again, unless that controller reports a session user. This prevents a kill loop with launchd.

**What the controller does about the watchdog.** While a session or a restoration exists, a watchdog heartbeat that is not fresh makes the controller fence the watchdog and restore (`watchdogUnavailable`). A watchdog with a new generation ends the session (`watchdogRestarted`). At startup the controller is not ready until it has restored any journal; if that keeps failing for 8 s and the watchdog is not fresh, it fences the watchdog.

**Startup and SIGTERM.** A watchdog always fences the controller and runs recovery when it starts, and also on SIGTERM before it exits. A controller always restores before it becomes ready.

**Fencing** (`FencedRecovery` in [PeerSupervision.swift](../Sources/KeepMacAwakeServiceSupport/PeerSupervision.swift), `PeerFencer` in [SecureState.swift](../Sources/KeepMacAwakeHelper/SecureState.swift)). The fence runs `launchctl kill SIGKILL system/<fixed label>`, bounded at 2 s. It counts as done if the kill succeeded, the job is absent, or the job is loaded without a process. Only then does the restore take the lock. A stopped process may hold the lock, so it is always killed before the lock is requested. The fence is not repeated when the restore is retried. While recovering, the service publishes `ready` false under a new generation, and the controller answers requests with phase `restoring`. launchd restarts a killed service (`KeepAlive`, `ThrottleInterval` 3).

## Supervision cadence

Idle supervision and session supervision differ only in rate (`SupervisionCadence` in [PeerSupervision.swift](../Sources/KeepMacAwakeServiceSupport/PeerSupervision.swift)):

| State | Rate | Constant |
| --- | --- | --- |
| Session, pending restoration, recovery or a service that is not ready (for the watchdog: a controller that is not idle) | every 1 s, timer leeway 100 ms | `supervisionSeconds` = 1 |
| After the last such state, or after a wake | 1 s for another 10 s | `supervisionHoldSeconds` = 10 |
| Otherwise | every 60 s, timer leeway 5 s | `idleSupervisionSeconds` = 60 |

Two Darwin notifications coordinate the rates. They carry no data, grant nothing and never take the lock:

- `com.keepmacawake.Watchdog.wake`: the controller posts it on each tick while it needs supervision. The watchdog switches to the fast rate.
- `com.keepmacawake.Watchdog.start`: the controller posts it on Start, then waits up to 0.75 s (`watchdogWakeTimeoutSeconds`) for a watchdog heartbeat published after the wake. Without it, Start is refused before any change. The watchdog answers at most four times a second.

Together with the 1.5 s kernel confirmation, the Start wait stays below the client's 3 s request timeout. If the watchdog cannot register for the notifications, it keeps the 1 s rate. Heartbeat files are written once per tick, so once a minute when idle.

## Files written

| Path | Owner and mode | Written by | When |
| --- | --- | --- | --- |
| `/Library/PrivilegedHelperTools/com.keepmacawake/KeepMacAwakeHelper` | root:wheel 0755 | package | install |
| `/Library/PrivilegedHelperTools/com.keepmacawake/trust.json` | root:wheel 0644 | package | install |
| `/Library/LaunchDaemons/com.keepmacawake.Helper.plist`, `com.keepmacawake.Watchdog.plist` | root:wheel 0644 | package | install |
| `/Library/LaunchAgents/com.keepmacawake.Coordinator.plist` (closed client) | root:wheel 0644 | package | install |
| `/Library/Application Support/KeepMacAwake/` | root:wheel 0700 | [preinstall](../Packaging/InstallScripts/preinstall) | install |
| `.../sleep-recovery.json` | root 0600 | controller, recovery | from turning on until restored |
| `.../controller-heartbeat.json`, `.../watchdog-heartbeat.json` | root 0600 | each service | every tick; atomic replace, not flushed |
| `.../transaction.lock` | root 0600 | any locker | created once, empty |
| `.../first-session.json` ([FirstSessionRecord.swift](../Sources/KeepMacAwakeServiceSupport/FirstSessionRecord.swift)) | root 0600 | controller | the first accepted session, the start and end of later sessions, at most once an hour in between; never again a week after the first session. The uninstaller leaves it, so a reinstall does not restart the trial |
| Temporary `.sleep-recovery-*.tmp`, `.heartbeat-*` | root 0600 | same | only during a write |
| `SleepDisabled` in `com.apple.PowerManagement` `SystemPowerSettings` | system | controller, recovery | turning on and restoring |
| `/usr/local/bin/keepmacawake` (link to the command inside the app) | root | [postinstall](../Packaging/InstallScripts/postinstall) | install, only if the path is free |

The core keeps no session history and the LaunchDaemons define no log file. The coordinator (closed source) stores the two battery preferences, the license after a purchase and a copy of the first-session record in the user's `com.keepmacawake` domain. See [privacy](PRIVACY.md).

**Install and removal.** [preinstall](../Packaging/InstallScripts/preinstall) refuses another volume and unsafe paths, asks the app to quit (SIGTERM, up to 10 s, then SIGKILL), stops the coordinator in every logged-in user session, kills and unloads both daemons, then runs `--recover`, which requires both daemons unloaded and restores from the journal. [postinstall](../Packaging/InstallScripts/postinstall) fixes ownership, validates the installation, loads the watchdog and then the controller, and loads the coordinator for the console user. Loading never starts a session. The [uninstaller](../Packaging/UninstallScripts/postinstall) stops everything the same way and runs `--recover` before it removes any file; if recovery fails it stops and leaves the files for another attempt. To read the state without changing it, use [tools/recovery-readout](../tools/recovery-readout/README.md).

## Display off with the lid closed

This is a client feature, closed source, with no root privileges and no part in the core. During a session macOS does not sleep when the lid closes, and another app's display assertion can keep the built-in display lit. The coordinator listens for the IOKit clamshell message. When the lid is closed during a session and no display other than the built-in one is active, it runs `pmset displaysleepnow`. While the lid stays closed in a session it checks again every 60 s and asks again only if the built-in display does not report sleep, no other display is active and there was no input for 60 s. If macOS does not answer the display query, nothing is requested. The helper and the watchdog are not involved.

## Tests

`swift test` runs [KeepMacAwakeCoreTests](../Tests/KeepMacAwakeCoreTests), [KeepMacAwakeControlCoreTests](../Tests/KeepMacAwakeControlCoreTests) and [KeepMacAwakeHelperTests](../Tests/KeepMacAwakeHelperTests). They cover the decisions: power mapping, the transaction and journal, session rules, power rules, heartbeat and fencing decisions, cadence and file checks. The process glue in [ServiceRuntime.swift](../Sources/KeepMacAwakeHelper/ServiceRuntime.swift) and [SecureState.swift](../Sources/KeepMacAwakeHelper/SecureState.swift) (XPC, launchd, timers, signals, the lock) and the install scripts have no unit tests of their own. Behavior under failures, with test names, is in [FAILURE-MODES.md](FAILURE-MODES.md).
