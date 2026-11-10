# Changelog

## 1.0.9

- The first update check after a new installation now adds `?first=1`, as described since 1.0.6. The coordinator built the battery settings before the update check, and they save `allowsBattery` and `minimumBatteryPercent`, which the check read as traces of an earlier installation, so 1.0.6 to 1.0.8 never sent the flag. The coordinator now reads whether the installation is new before anything writes the preferences. Nothing else changes in what is sent: no identifier, no version, nothing about the Mac.
- 1.0.4 to 1.0.8 install 1.0.9 by themselves when no session runs.

## 1.0.8

- A new menu bar panel. The length is chosen on a crescent dial (drag its end, type any whole number of hours, or Option-arrow by one hour) or with the presets **4h**, **8h**, **24h** and **No limit** (Command-1 to 4); the trial's 8-hour cap puts a lock on 24h and No limit. The panel's sky shows the state: day with no session, a starry night only while the helper's confirmation is fresh, dusk while a session waits for AC power, and dawn after a session ended, with how long it kept the Mac awake, the planned length, time paused without AC power and why it ended. That account lives only in the coordinator's memory and is gone after a restart; nothing about sessions is written to disk.
- The menu bar icon is a moon that shows on, off, waiting for AC power and attention. Right-click or Control-click opens a quick menu with the same presets; Option-click starts a session with the last length, or asks before turning one off.
- **How It Works** under More (…): the live state of the sleep setting, what the helper and the watchdog do, and what leaves the Mac.
- The app carries its uninstaller (`Contents/Resources/KeepMacAwake-Uninstall.pkg`, the same file as on this release): **Uninstall Keep Mac Awake…** under More (…) opens it in Installer, with no download.
- Turning a session off asks once, from the panel, the quick menu, Option-click and Quit alike.
- New installer and uninstaller pages.
- An automatic update waits while a session that ended within the last 12 hours has not been shown in the panel, so its restart does not lose that account. **Install** in the panel never waits.
- 1.0.4 to 1.0.7 install 1.0.8 by themselves when no session runs.

## 1.0.7

- After a first installation the installer opens Keep Mac Awake, and its first launch shows the panel by itself with a short welcome instead of the offer and the agent card. When the menu bar icon is hidden (a full menu bar, the camera housing, or the item hidden in System Settings), the panel opens below the middle of the menu bar; opening the app again does the same. An update of an app that was not running still opens nothing.
- The app adds itself to Open at Login once per user (`SMAppService.mainApp`), at its first launch of this version, and never again after you turn it off. **Open at Login** under More (…) in the panel turns it off or on. Opening the app at login never starts a session.
- 1.0.4 to 1.0.6 install 1.0.7 by themselves when no session runs.

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
