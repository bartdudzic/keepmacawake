# Changelog

## [1.0.0] - 2026-11-14

- First release: Start (hours, 8 by default), Stop (only a session this IDE started) and Status actions under Tools | Keep Mac Awake, through the `keepmacawake` command of Keep Mac Awake, and an optional setting that keeps the Mac awake while a run configuration runs (a timed session that ends with the last run, only when the plugin started it).
- Reads the battery default of Keep Mac Awake 1.0.11 (`config.battery_chosen`): while Run on battery turned itself on and you have not chosen it, Start asks before a session that may run on battery, and the run hold starts nothing until you said yes once. The plugin never changes the setting.
