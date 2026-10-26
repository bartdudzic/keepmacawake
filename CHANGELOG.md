# Changelog

## 1.0.0

First public release.

- Menu bar app with sessions of no limit, 1 hour, 8 hours or a custom number of hours up to 168.
- AC power only by default; optional battery use above a chosen threshold, 20% by default, with a thermal cutoff on battery.
- The built-in display turns off when the lid closes during a session.
- The `keepmacawake` command for Terminal and AI agents, with JSON output.
- A helper that changes the sleep setting through a restoration journal, and an independent watchdog that restores it after a failure.
- A 3-day trial from the first session, with sessions up to 8 hours, then a one-time purchase for 9 USD plus tax per Mac: Buy and Restore purchase in the panel, `keepmacawake buy` and `keepmacawake restore`.
- Check for Updates opens the releases page; there are no automatic updates.
- No network connections except Restore purchase when you choose it; no data collection, no logs.
- Install and uninstall packages, signed with Developer ID and notarized.
