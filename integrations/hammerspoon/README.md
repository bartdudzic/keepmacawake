# Keep Mac Awake for Hammerspoon

`KeepMacAwake.spoon` starts, checks and stops [Keep Mac Awake](https://keepmacawake.com) sessions from [Hammerspoon](https://www.hammerspoon.org), from hotkeys or your own Lua code, and shows the answer of the `keepmacawake` command in an alert.

It needs the Keep Mac Awake app on this Mac: a menu bar app that keeps a MacBook with Apple silicon awake with the lid closed during a session, on macOS 26 or later. It has a free trial.

## Install

Copy the `KeepMacAwake.spoon` folder into `~/.hammerspoon/Spoons/`, then add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("KeepMacAwake")
spoon.KeepMacAwake:bindHotkeys({
  start = { { "cmd", "alt", "ctrl" }, "A" },          -- a session of 8 hours
  startUnlimited = { { "cmd", "alt", "ctrl", "shift" }, "A" },
  stop = { { "cmd", "alt", "ctrl" }, "S" },
  status = { { "cmd", "alt", "ctrl" }, "I" },
})
```

## Use

| Method | What it does |
| --- | --- |
| `spoon.KeepMacAwake:start()` | A session of 8 hours |
| `spoon.KeepMacAwake:start(3)` | A session of 3 hours (any whole number from 1 to 168) |
| `spoon.KeepMacAwake:start("unlimited")` | A session without a time limit |
| `spoon.KeepMacAwake:status()` | Shows whether a session runs and its time left |
| `spoon.KeepMacAwake:stop()` | Ends the session; the Mac sleeps as usual again |

Each method takes an optional callback, called with the command's exit code and its message, for example to start a session before a long job in your own code. The exit codes are in the [command line reference](https://github.com/bartdudzic/keepmacawake/blob/main/docs/COMMAND-LINE.md).

## What it runs

Only the `keepmacawake` command that the app installs (`/usr/local/bin/keepmacawake`, or `spoon.KeepMacAwake.cliPath`), with `start`, `status` or `stop`, when you call a method or press a hotkey. It makes no network connection, stores nothing and never starts a session on its own.

## Check

`lua test.lua` (Lua 5.4) tests the Spoon with a fake `hs` that starts no process. `docs.json` is generated with Hammerspoon's documentation tool: `build_docs.py -j -o Source/KeepMacAwake.spoon/ -n Source/KeepMacAwake.spoon/`, run from a folder that holds the Spoon as `Source/KeepMacAwake.spoon`.

## License

MIT, see [LICENSE](LICENSE).
