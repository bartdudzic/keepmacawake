# Changelog

## [1.0.0] - 2026-11-07

- First release: keeps the Mac awake while Pi works, also with the lid closed, through the `keepmacawake` command of Keep Mac Awake. `/awake start [hours]` starts a timed session; `/awake auto on` (off by default, saved) starts one with each Pi run when none is running. Pi never ends a session by itself, only on `/awake stop`: a session ends after its hours.
