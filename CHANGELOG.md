# Changelog

## 1.0.6

- Signed with new Developer ID certificates of the same developer, which spell the developer's legal name correctly.
- The first update check after a new installation adds `?first=1`, the same on every Mac, so keepmacawake.com can count new installations per day. Nothing about the Mac is sent; an update, a reinstall that keeps the settings and an installation with the update check off never send it.
- 1.0.4 and 1.0.5 install 1.0.6 by themselves when no session runs.

## 1.0.5

- The price is stated with tax included: 9 USD, tax included, one time, for this Mac, in the menu bar panel and in `keepmacawake` (its text, its JSON `price` and the trial messages). The checkout has charged 9 USD with tax included since 2026-10-27.

## 1.0.4

- Updates install by themselves, with no password and no click, when the daily check finds a newer version and no session runs; the app opens again and the panel says it was updated. Install in the panel does it at once, also with no password. The system service checks the package itself (Developer ID of the Keep Mac Awake developer, Apple's notarization, a newer version, never the uninstaller) before installing it, and refuses Start while it installs. `keepmacawake config set --update-check off` turns it off.

## 1.0.3

- Install in the menu bar panel works. In 1.0.1 and 1.0.2 it stopped after downloading and checking the new version with "Keep Mac Awake is quitting.", because the last check before the administrator dialog always answered that. Users of those versions install 1.0.3 once from keepmacawake.com or with `curl -fsSL https://keepmacawake.com/install.sh | sh`.
- A failed install shows its reason in the update row, with Try Again, instead of a separate warning above it. The password dialog and the row say that Keep Mac Awake restarts by itself after installing.

## 1.0.2

- `keepmacawake status --agent` reports only the app's state: whether a session runs and its time left, the trial, a newer version (installed with Install in the menu bar panel). It no longer prints commands, the price or an install command.
- `keepmacawake capabilities` says updates are installed with Install in the menu bar panel.

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
- macOS lists the helper, the watchdog and the coordinator under Keep Mac Awake, with its icon, in Login Items & Extensions.

## 1.0.0

Withdrawn on its release day, before anyone downloaded it: macOS named its background services after the developer certificate instead of Keep Mac Awake.
