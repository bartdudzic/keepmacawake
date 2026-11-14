# Changelog

## [1.0.1] - unreleased

- With automatic start on, Pi no longer starts a session by itself when Keep Mac Awake 1.0.11 or later says Run on battery turned itself on and you have not chosen it (`config.battery_chosen` false): such a session may run on battery. Pi says so once and leaves it to you: `/awake start` starts one anyway, after which Pi starts them by itself until it quits; `keepmacawake config set --battery allowed` lets Pi start them every time, and Run on battery off in the panel keeps sessions on AC power. With an older app, or Run on battery you set yourself, nothing changes.
- `/awake start` says when the session may run on battery, and down to which level.

## [1.0.0] - 2026-11-07

- First release: keeps the Mac awake while Pi works, also with the lid closed, through the `keepmacawake` command of Keep Mac Awake. `/awake start [hours]` starts a timed session; `/awake auto on` (off by default, saved) starts one with each Pi run when none is running. Pi never ends a session by itself, only on `/awake stop`: a session ends after its hours.
