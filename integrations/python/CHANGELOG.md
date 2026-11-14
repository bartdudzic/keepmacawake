# Changelog

## [1.0.0] - Unreleased

- First release: keeps a Mac awake, also with the lid closed, while Python code runs, through the `keepmacawake` command of Keep Mac Awake. `keepmacawake.session(hours=8)` (a context manager and a decorator), `status()`, `start()`, `stop()` and the IPython and Jupyter magic `%keepmacawake 8h`, `%keepmacawake off`. A session is never ended by the package unless the code asks for it (`stop_on_exit=True`, only for a session that block started, or `stop()`). `Status` reads the battery settings of Keep Mac Awake 1.0.11 (`battery_chosen`, `battery_needs_consent`), and a `KeepMacAwakeWarning` says when a session may run on battery because Run on battery turned itself on. No dependencies.
