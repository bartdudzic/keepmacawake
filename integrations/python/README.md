# Keep Mac Awake for Python

`keepmacawake` keeps your Mac awake, also with the lid closed, while Python code or a notebook runs: a training run, a long data job, a local model working overnight. It uses [Keep Mac Awake](https://keepmacawake.com/?utm_source=pypi&utm_medium=referral&utm_campaign=integrations&utm_content=readme), a menu bar app for any Mac with Apple silicon on macOS 26 or later, through its `keepmacawake` command. The package itself has no dependencies.

```sh
pip install keepmacawake
```

## In a script

```python
import keepmacawake

with keepmacawake.session(hours=8):
    train()
```

The block starts a Keep Mac Awake session of 8 hours, so you can close the lid and let the job run. If a session is already running, the block uses it as it is. The session ends after its hours, with `keepmacawake.stop()` or from the menu bar panel; then normal sleep returns, and a closed Mac that nothing else keeps awake goes to sleep.

```python
with keepmacawake.session(hours=4, stop_on_exit=True):
    run_job()   # the session ends when the block finishes, if this block started it

@keepmacawake.session(hours=8)
def train():
    ...

state = keepmacawake.status()
print(state)            # A Keep Mac Awake session is running, 7 h 58 min left.
state.running, state.remaining_seconds, state.hours, state.access, state.battery_needs_consent

keepmacawake.start(hours=2)   # start a session now, without a block
keepmacawake.stop()           # end the running session, whoever started it
```

`hours` is a whole number from 1 to 168, 8 by default. The package never starts a session without a time limit.

**Free trial.** The first session on a Mac starts the app's free trial, so run your first `session()` when you mean to. During the free trial a session lasts at most 8 hours, so `session(hours=12)` raises `PurchaseRequiredError` before the block runs, with the app's own message about it; `hours=8` works. The package never shortens the session for you.

## In Jupyter or IPython

```python
%load_ext keepmacawake
%keepmacawake 8h      # keep this Mac awake for 8 hours, also with the lid closed
%keepmacawake         # show the state: time left, the free trial
%keepmacawake off     # end the session, whoever started it
```

`%keepmacawake on` is the same as `8h`. When the Mac cannot be kept awake (no app, the trial limit, or battery power while Run on battery is off), the magic raises an error, so a notebook stops before the long cell instead of running into sleep.

## How a session ends

- **By default the session keeps running after the block,** until its hours are up. Pick `hours` close to the job's length so the Mac sleeps soon after it.
- **`stop_on_exit=True` ends the session when the block finishes, also after an exception,** but only when this block started it and the running session still has the same hours and the same end time (within two minutes). Otherwise the block leaves it running and gives a `KeepMacAwakeWarning`.
- **Why not end it always:** the `keepmacawake` command does not tell one session from another (there is no session id), so the block cannot prove that the running session is the one it started. You may have replaced it with your own, or another script, an agent or the [Pi extension](https://github.com/bartdudzic/keepmacawake/tree/main/integrations/pi) may be relying on it. A session the block did not start is never ended by it.

## On battery

On a MacBook running on battery, Keep Mac Awake (1.0.11 or later) turns Run on battery on at 20% unless you have set it yourself, so a session can keep a closed MacBook awake on battery down to that level. When a session that `session()`, `start()` or the magic starts may run on battery that way, the package says so: a `KeepMacAwakeWarning` in code, a line in the notebook. It starts the session you asked for and never changes the setting. To decide, set Run on battery in the menu bar panel, or run `keepmacawake config set --battery ac-only` in Terminal to keep sessions on AC power (`--battery allowed` keeps battery use).

`status().battery_needs_consent` is true while Run on battery is on and you have not set it (`config.battery_chosen` false in the command's answer). **An AI agent that writes or runs code with this package asks you before it starts a session while this is true**, the same rule as the Keep Mac Awake MCP server and the Pi extension. `battery_allowed`, `battery_chosen`, `battery_available` and `min_battery_percent` hold the settings themselves; `battery_chosen` is None with Keep Mac Awake 1.0.10 or earlier, where battery use was always your choice.

A closed Mac that stays awake still makes heat: keep it ventilated, on a hard surface, never in a bag.

## Errors

Every error is a `keepmacawake.KeepMacAwakeError` with `exit_code`, `code` and the command's JSON answer in `reply`:

| Error | When |
| --- | --- |
| `NotInstalledError` | Keep Mac Awake is not installed: the message names the missing command and links the website |
| `PurchaseRequiredError` | The free trial does not allow this session (more than 8 hours) or has ended; `reason`, `max_hours` and `next_steps` come from the app |
| `ActionRequiredError` | The app needs you first, for example AC power while Run on battery is off, or the command ran with `sudo` |
| `AlreadyRunningError` | `start()` while a session runs; `error.status` is that session (`session()` and the magic use it instead) |
| `ServiceUnavailableError` | The app's background service did not answer: open Keep Mac Awake from Applications |
| `NoAnswerError` | No answer in time; after a start or a stop, check `status()` |
| `NotSupportedError` | Not a Mac |

## Why an app for the closed lid

A MacBook goes to sleep when you close its lid, and your Python process stops with it. caffeinate with no flag, `-i`, `-d` or `-m` only prevents idle sleep, so the lid still puts the Mac to sleep; `-s` keeps a closed MacBook running only on AC power, and it sleeps once you unplug it ([caffeinate and the closed lid](https://keepmacawake.com/blog/caffeinate-lid-closed?utm_source=pypi&utm_medium=referral&utm_campaign=integrations&utm_content=readme-caffeinate)). Keep Mac Awake is built for the closed lid: it keeps the Mac awake for a session, on AC power and on battery too (on a MacBook running on battery, Run on battery turns itself on at 20% unless you set it in its panel), and a separate watchdog service puts normal sleep back if Keep Mac Awake's background service or the system service stops or hangs.

## What it needs

The [Keep Mac Awake](https://keepmacawake.com/?utm_source=pypi&utm_medium=referral&utm_campaign=integrations&utm_content=readme-needs) app, installed on this Mac: any Mac with Apple silicon and macOS 26 or later. It has a free trial. Python 3.9 or later. The package installs on any system, but it works only on a Mac: elsewhere every call raises `NotSupportedError`. Without the app it raises `NotInstalledError` with a link to the website; it never installs anything itself.

## What it runs

The package runs only the `keepmacawake` command that the app installs, `/usr/local/bin/keepmacawake` (or the path in the `KEEPMACAWAKE_CLI` environment variable, or the `cli=` argument, each a full path; it never searches `PATH`, and a bare name such as `keepmacawake` is refused), with `status`, `start --hours N` and `stop`, each with `--json --no-input`. `stop` runs only when your code calls `stop()`, uses `%keepmacawake off` or sets `stop_on_exit=True`. It never starts a session without a time limit, never changes battery or other settings, never buys or installs anything, makes no network connection, and reads and writes no files. The source is in [`src/keepmacawake`](https://github.com/bartdudzic/keepmacawake/tree/main/integrations/python/src/keepmacawake). The command's answers and exit codes are in the [command line reference](https://github.com/bartdudzic/keepmacawake/blob/main/docs/COMMAND-LINE.md).

For an AI agent that starts and stops sessions itself, see the [Keep Mac Awake plugin](https://github.com/bartdudzic/keepmacawake/tree/main/plugins/keep-mac-awake) and the [MCP server](https://github.com/bartdudzic/keepmacawake/tree/main/mcp).

## Check

```sh
python -m pip install pytest
python -m pytest     # tests the package with a fake keepmacawake command
python -m build      # the sdist and the wheel, then: twine check dist/*
```

The tests never run the real command: each one passes the fake command's path explicitly, and `KEEPMACAWAKE_CLI` and the default path point to a path that does not exist.

## License

MIT, see [LICENSE](https://github.com/bartdudzic/keepmacawake/blob/main/integrations/python/LICENSE).
