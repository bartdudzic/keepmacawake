# Keep Mac Awake for JetBrains IDEs

A plugin for IntelliJ IDEA, PyCharm, WebStorm, GoLand and the other JetBrains IDEs (2025.3 or later) that keeps your Mac awake from the IDE, also with the MacBook lid closed, so a long build, a test suite or an AI agent such as Junie keeps running. It controls the [Keep Mac Awake](https://keepmacawake.com/) menu bar app through its `keepmacawake` command.

**The Keep Mac Awake app is required.** It has a free trial and runs on any Mac with Apple silicon and macOS 26 or later. Without the app, the plugin shows a notification that names what is missing, with a link to the website; it never installs anything itself. On Windows and Linux the plugin loads, and its actions explain that it is for Macs.

## What it does

Everything is under **Tools | Keep Mac Awake**, and in Find Action.

- **Start Keep Mac Awake...** asks for the hours (8 by default) and starts a session now, also for a closed lid. During the free trial a session lasts at most 8 hours: above 8 the dialog says so, and if the app refuses, the notification offers an 8-hour session instead. The session ends by itself after its hours, or with Stop, and normal sleep returns. When Run on battery turned itself on and you have not chosen it (see [On battery](#on-battery)), Start asks first.
- **Stop Keep Mac Awake** ends the session only when this IDE started it. A session started from the menu bar, a terminal, an agent or another IDE is left running, and the plugin tells you to stop it from the Keep Mac Awake menu bar panel.
- **Keep Mac Awake Status** shows whether a session runs, its time left, whether this IDE started it, the free trial, and whether Start would ask about battery use.
- **Keep this Mac awake while a run configuration runs** (optional, off by default; Settings | Tools | Keep Mac Awake). When a run or debug configuration starts and no session is running, the plugin starts a timed session of 8 hours at most (you can change the cap, 1 to 168 hours). When the last run ends, it ends that session. A session that was already running is used as it is and never ended by a run. A run longer than the cap keeps the Mac awake only until the cap; normal sleep then returns. The first session on a Mac, which starts the free trial, is always yours to start: the run hold tells you once and starts nothing. The same holds while Run on battery turned itself on and you have not said yes to it. If you quit the IDE during a run, the session the run hold started ends too.

A closed Mac that stays awake still makes heat: keep it ventilated, on a hard surface, never in a bag.

## On battery

On a MacBook running on battery, Keep Mac Awake (1.0.11 or later) turns Run on battery on at 20% unless you have set it yourself, so a session can keep a closed MacBook awake on battery down to that level. The plugin never changes this setting, and it never starts a session that may run on battery that way without your yes:

- **Start** shows a notification instead: the session would run on battery down to 20% when the Mac is unplugged, with a button to start it anyway. Plug in first, or press the button.
- **The run hold** starts nothing and tells you once. After you said yes in Start, runs start sessions again until the IDE quits.

To decide for good, set it yourself: `keepmacawake config set --battery allowed` in Terminal keeps battery use, and turning Run on battery off in the Keep Mac Awake menu bar panel keeps sessions on AC power. The plugin reads this from `config.battery_chosen` in the command's answer; with Keep Mac Awake 1.0.10 or earlier, which has no battery default, it asks nothing.

## Which sessions it ends

The `keepmacawake` command has no session id, so the plugin cannot ask whose session is running. It remembers the session it started in this IDE (its hours and the time it ends) and treats a running session as its own only while both still match, the end time within a minute. If the session was stopped, ended, or replaced by another one, the plugin forgets it and never ends the new one. Restarting the IDE forgets it too. The only case it cannot tell apart is a session of the same hours that replaced its own within about a minute.

## What it runs

The plugin runs only the `keepmacawake` command that the app installs, at `/usr/local/bin/keepmacawake` (or the path in the `KEEPMACAWAKE_CLI` environment variable of the IDE); it never searches `PATH`. It runs `status`, `start --hours N` and `stop`, each with `--json --no-input`, on a background thread; Start reads `status` before it starts a session. It never starts a session without a time limit, never changes battery or other settings, and never buys or installs anything; those stay with you in the app's panel. It makes no network connection and reads no project files. Its settings (the run hold, its cap and the hours last used in Start) are saved in `keepmacawake.xml` in the IDE's options folder. The command's answers and exit codes are in the [command line reference](../../docs/COMMAND-LINE.md).

## Why an app for the closed lid

A MacBook goes to sleep when you close its lid, and the IDE, its builds and its agents stop with it. caffeinate with no flag, `-i`, `-d` or `-m` only prevents idle sleep, so the lid still puts the Mac to sleep; `-s` keeps a closed MacBook running only on AC power, and it sleeps once you unplug it ([caffeinate and the closed lid](https://keepmacawake.com/blog/caffeinate-lid-closed)). Keep Mac Awake is built for the closed lid: it keeps the Mac awake for a session, on AC power and on battery too (on a MacBook running on battery, Run on battery turns itself on at 20% unless you set it in its panel), and a separate watchdog service puts normal sleep back if Keep Mac Awake's background service or the system service stops or hangs.

## Build and check

You need JDK 21. The Gradle wrapper downloads Gradle and the IntelliJ Platform.

```sh
./gradlew test          # tests with a fake keepmacawake command
./gradlew buildPlugin   # build/distributions/keepmacawake-jetbrains-<version>.zip
./gradlew verifyPlugin  # Plugin Verifier against IntelliJ IDEA 2025.3 and 2026.3
```

The tests never run the real command: each one writes a small fake `keepmacawake` script into a temporary folder and passes its path to the plugin explicitly. The plugin is built against IntelliJ Platform 2025.3 (build 253), the oldest version it supports, and has no upper limit.

To try it, install the zip with Settings | Plugins | Install Plugin from Disk, or run `./gradlew runIde` for a separate test IDE.

## Publishing on JetBrains Marketplace

1. Sign in to [JetBrains Marketplace](https://plugins.jetbrains.com/) with the publisher's JetBrains Account and accept the developer agreement.
2. Upload `build/distributions/keepmacawake-jetbrains-<version>.zip` with Upload plugin: license MIT, category Tools Integration, the source URL of this folder, and the website `https://keepmacawake.com/?utm_source=jetbrains-marketplace&utm_medium=referral&utm_campaign=integrations&utm_content=home`. The first version goes through JetBrains' review before it is listed.
3. Later versions: raise `pluginVersion` in `gradle.properties`, add a line to [CHANGELOG.md](CHANGELOG.md), build and verify, then upload the zip on the plugin's page, or run `./gradlew publishPlugin` with a Marketplace token in `JETBRAINS_MARKETPLACE_TOKEN`.

## License

MIT, see [LICENSE](LICENSE).
