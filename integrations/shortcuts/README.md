# Keep Mac Awake in Apple Shortcuts

Three shortcuts that run the `keepmacawake` command of the [Keep Mac Awake](https://keepmacawake.com) app and show its answer: start a session of 8 hours, show the status, stop. Run them from the Shortcuts menu bar item, Spotlight, a keyboard shortcut or Siri ("Keep Mac Awake start 8 hours"), or as a step in your own shortcuts.

They need the Keep Mac Awake app on this Mac: a menu bar app that keeps a MacBook with Apple silicon awake with the lid closed during a session, on macOS 26 or later. It has a free trial.

## Setup

Shortcuts runs shell scripts only when you allow it: in the Shortcuts app, open **Settings**, then **Advanced**, and turn on **Allow Running Scripts**.

## Make them

Each shortcut has two actions. In the Shortcuts app, create a new shortcut, name it, and add:

1. **Run Shell Script**, with the shell `zsh` and this script (for the status shortcut, replace `start --hours 8` with `status`; for the stop shortcut, with `stop`):

   ```sh
   cli=/usr/local/bin/keepmacawake
   if [ ! -x "$cli" ]; then
     echo "Keep Mac Awake is not installed. Get it at keepmacawake.com (free trial)."
     exit 0
   fi
   "$cli" start --hours 8 --no-input 2>&1
   exit 0
   ```

2. **Show Result**, showing the **Shell Script Result**.

| Name | Command in the script |
| --- | --- |
| Keep Mac Awake - start 8 hours | `start --hours 8` (any whole number of hours from 1 to 168, or `start --unlimited`) |
| Keep Mac Awake - status | `status` |
| Keep Mac Awake - stop | `stop` |

The script always ends with `exit 0`, so the shortcut shows Keep Mac Awake's own message also when it refuses, for example when a session already runs, AC power is needed or the trial limits the session's length. The [command line reference](https://github.com/bartdudzic/keepmacawake/blob/main/docs/COMMAND-LINE.md) lists every command and answer.

## What they run

Only the `keepmacawake` command that the app installs, as the logged-in user. They make no network connection, store nothing and never start a session on their own; a session starts only when you run the start shortcut, and a timed session ends on its own.

## Build

`./build.sh` writes the three shortcuts as `.shortcut` files from the scripts above, without the Shortcuts app, and checks them with `plutil`. macOS opens only signed shortcut files: `./build.sh --sign` also signs them with `shortcuts sign --mode anyone`, which needs an Apple Account signed in on the Mac.

## License

MIT, see [LICENSE](LICENSE).
