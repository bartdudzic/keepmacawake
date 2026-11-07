# Keep Mac Awake for Pi

`pi-keepmacawake` is a [Pi](https://pi.dev) extension that keeps your Mac awake while Pi works, also with the lid closed. You start a timed session with `/awake start`; if you want, each Pi run can start one by itself. It uses [Keep Mac Awake](https://keepmacawake.com/?utm_source=pi-gallery&utm_medium=referral&utm_campaign=pi-package&utm_content=readme), a menu bar app for any Mac with Apple silicon on macOS 26 or later, through its `keepmacawake` command.

```sh
pi install npm:pi-keepmacawake
```

## What it does

- **`/awake start [hours]`** starts a Keep Mac Awake session now (8 hours if you give no number), so you can close the lid and let Pi work, for example overnight. Pi leaves that session running; it ends after its hours, or with `/awake stop` or the menu bar panel.
- **By default nothing starts by itself.** When a Pi run starts, the extension runs no command; once per Pi process it shows one line about `/awake start` and `/awake auto on`.
- **The first session on a Mac starts the app's free trial,** so that one is always yours to start: `/awake start` or the panel.

### Automatic start (opt-in)

`/awake auto on` makes each Pi run start a timed session; `/awake auto off` turns that off again. The choice is saved, so the next Pi starts the same way. With it on:

- **When a Pi run starts** and no session is running, it starts one of 8 hours at most (`/awake hours N` changes that). A session that is already running, yours or one an earlier run started, is used as it is.
- **When Pi is done, the session keeps running** until its hours are up, and then the Mac sleeps as usual again. `/awake stop` or the menu bar panel ends it sooner; fewer hours (`/awake hours 2`) let the Mac sleep sooner after Pi.
- **Pi never ends a session by itself,** only when you run `/awake stop`. The `keepmacawake` command does not tell one session from another (no session id), so Pi cannot be sure the running session is the one it started: you may have replaced it with your own, or another Pi window may still need it.
- **A run longer than the session** gets a new one when the old one runs out of time. A session you stopped, or one that ended on battery or for heat, is not started again during that run.
- **Several Pi windows** share one session.
- **It never starts the first session** on a Mac, the one that starts the free trial; it asks you to start that one.

A closed Mac that stays awake still makes heat: keep it ventilated, on a hard surface, never in a bag.

## Why an app for the closed lid

A MacBook goes to sleep when you close its lid, and Pi stops with it. caffeinate with no flag, `-i`, `-d` or `-m` only prevents idle sleep, so the lid still puts the Mac to sleep; `-s` keeps a closed MacBook running only on AC power, and it sleeps once you unplug it ([caffeinate and the closed lid](https://keepmacawake.com/blog/caffeinate-lid-closed?utm_source=pi-gallery&utm_medium=referral&utm_campaign=pi-package&utm_content=readme-caffeinate)). Keep Mac Awake is built for the closed lid: it keeps the Mac awake for a session, on AC power by default and on battery too if you allow it in its panel, and a watchdog puts normal sleep back if anything stops.

## Commands

| Command | What it does |
| --- | --- |
| `/awake` | Shows whether a session runs and its time left, the free trial, and whether automatic start is on |
| `/awake start [N]` | Starts a session of N hours now (default 8), also for a closed lid; Pi leaves it running |
| `/awake stop` | Ends the session, whoever started it; the Mac sleeps as usual again |
| `/awake auto on`, `/awake auto off` | Starts a timed session with each Pi run, or not (off by default); saved for the next Pi |
| `/awake hours N` | The longest session Pi starts, 1 to 168 hours (default 8); during the free trial at most 8 |

Settings from the environment, read when Pi starts: `KEEPMACAWAKE_PI_AUTO=1` (or `0`) turns automatic start on (or off) for that launch, over the saved choice, and `KEEPMACAWAKE_PI_HOURS=12` sets the longest session.

## What it needs

The [Keep Mac Awake](https://keepmacawake.com/?utm_source=pi-gallery&utm_medium=referral&utm_campaign=pi-package&utm_content=readme-needs) app, installed on this Mac: any Mac with Apple silicon and macOS 26 or later. It has a free trial. Without the app, Pi shows one line with a link to the website. The extension never installs anything itself. On other systems it says once that it works only on a Mac, then does nothing.

## What it runs

Pi packages run code on your computer, so here is all of it. The extension runs only the `keepmacawake` command that the app installs (`/usr/local/bin/keepmacawake`, or the path in `KEEPMACAWAKE_CLI`), with `status`, `start --hours N` and `stop` (only for `/awake stop`), each with `--json --no-input`. It never starts a session without a time limit, never changes battery or other settings, and never buys or installs anything; those stay with you in the app's panel. It makes no network connection and does not read your prompts, files or Pi sessions. `/awake auto on` and `off` save one setting in `pi-keepmacawake.json` in Pi's agent folder (`~/.pi/agent`, or `PI_CODING_AGENT_DIR`). It writes no other file. The source is one file, [`src/index.js`](https://github.com/bartdudzic/keepmacawake/blob/main/integrations/pi/src/index.js), with no dependencies. The command's answers and exit codes are in the [command line reference](https://github.com/bartdudzic/keepmacawake/blob/main/docs/COMMAND-LINE.md).

For an agent that starts and stops sessions itself, see the [Keep Mac Awake plugin](https://github.com/bartdudzic/keepmacawake/tree/main/plugins/keep-mac-awake) and the [MCP server](https://github.com/bartdudzic/keepmacawake/tree/main/mcp).

## Check

```sh
npm test    # tests the extension with a fake keepmacawake command and a fake Pi
```

The tests never run the real command: each one names the fake command in `KEEPMACAWAKE_CLI`, the only path the extension then tries, and keeps its setting file in a temporary folder.

## License

MIT, see [LICENSE](LICENSE).
