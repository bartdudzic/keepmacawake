# Changelog

## 1.0.1

First public release.

- Menu bar app with sessions of no limit, 1 hour, 8 hours or a custom number of hours up to 168.
- AC power only by default; optional battery use above a chosen threshold, 20% by default, with a thermal cutoff on battery.
- The built-in display turns off when the lid closes during a session.
- The `keepmacawake` command for Terminal and AI agents, with JSON output.
- A helper that changes the sleep setting through a restoration journal, and an independent watchdog that restores it after a failure.
- A 3-day trial from the first session, with sessions up to 8 hours, then a one-time purchase for 9 USD plus tax per Mac: Buy and Restore purchase in the panel, `keepmacawake buy` and `keepmacawake restore`.
- Updates from the panel: a daily check shows a newer version with Install, which downloads it, checks its signature and notarization, asks for the administrator password and opens the new app. Check for Updates… checks at once; `keepmacawake config set --update-check off` turns the daily check off.
- On its own the app goes online only for the daily update check, which carries nothing about the Mac; Restore purchase and Install only when you choose them; no data collection, no logs.
- Install and uninstall packages, signed with Developer ID and notarized.
- macOS lists the helper, the watchdog and the coordinator under Keep Mac Awake, with its icon, in Login Items & Extensions and in its background activity notice.

## 1.0.0

Withdrawn on its release day, before anyone downloaded it: macOS named its background services after the developer certificate instead of Keep Mac Awake.
