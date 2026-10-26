# Keep Mac Awake security

This document describes Keep Mac Awake 1.0: what runs with which privileges, what the app reads, writes and sends, and how to report a problem. It is not an audit or a guarantee. This repository holds the parts that run as root or at install time: the helper, the watchdog, the installer scripts and their tests. The menu bar app, the coordinator and the `keepmacawake` command are not included.

## Reporting a vulnerability

Send reports to **hi@keepmacawake.com**, with "Security" in the subject. Include the macOS version, the Mac model, the Keep Mac Awake version and steps to reproduce. Please do not open a public issue for a vulnerability.

## What runs where

| Part | Runs as | Role |
| --- | --- | --- |
| Menu bar app `Keep Mac Awake` | the logged-in user | Panel, icon and settings. A client of the coordinator |
| `keepmacawake` command | the logged-in user | The same session controls as the panel. A client of the coordinator |
| Coordinator `KeepMacAwakeCoordinator` | the logged-in user (LaunchAgent) | Owns the session, renews its lease every 2 seconds and keeps it going while the panel is closed or a command has ended; turns the display off when the lid closes during a session |
| Helper (controller) `KeepMacAwakeHelper` | root (LaunchDaemon) | Turns the system sleep setting on and off; keeps a session only while its lease is renewed |
| Watchdog `KeepMacAwakeHelper` | root (LaunchDaemon) | Independently checks the session and restores the sleep setting if the controller stops or hangs |

## Boundaries

- The only system setting the services change is `SleepDisabled`. Every change goes through a restoration journal, so the original state is restored after Stop, Quit, a crash or a hung process. The installer and the uninstaller also restore it.
- The helper has a fixed interface: status, start, renew and stop. It does not run commands, read files or accept paths from clients.
- Each connection is checked by code signature. The helper accepts only the coordinator's exact code hash; the coordinator accepts only the app's and the command's exact code hashes, from the same user. The installer writes these requirements into a root-owned trust file, and the app and the command check the coordinator against it before sending anything.
- The helper and the watchdog read the power source, the battery level and the thermal state themselves. A session on AC only pauses without AC; a battery session ends at the chosen threshold, on an unknown reading or at a serious or critical thermal state.
- A session belongs to the console user. A switch to another user ends it, and other users and `root` cannot start one through the command.
- The app needs no network, account, Full Disk Access, Accessibility or screen recording, and does not require turning off SIP, Gatekeeper, FileVault or the screen lock.

## Data

The app, the coordinator and the services make no network connections, except **Restore purchase** when you choose it: one HTTPS request from the coordinator to keepmacawake.com with this Mac's ID. Keep Mac Awake stores the two battery preferences, the position of its menu bar icon, the license after a purchase, the first-session record the trial is counted from, and the state the services need to restore the sleep setting; it keeps no session history and writes no logs. Details: [privacy](docs/PRIVACY.md).

## Known limits

- An administrator can stop or remove the services; automatic recovery does not cover that, or a damaged system.
- The sleep setting is system-wide: while a session runs, choosing Sleep from the Apple menu does not put the Mac to sleep either.
- Public releases are signed with Developer ID and notarized by Apple. Builds from source with an ad hoc signature are for development only.
- If the Mac stays asleep or awake unexpectedly, follow the [support procedure](docs/SUPPORT.md).
