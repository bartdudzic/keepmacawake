# `keepmacawake` command-line reference

The `keepmacawake` tool controls the same session as the Keep Mac Awake menu bar panel. It is meant for people in a terminal and for AI agents; use over SSH as the logged-in user has not been verified yet. The installer links it as `/usr/local/bin/keepmacawake`; the binary itself stays inside the signed app.

The session belongs to a per-user background service (the coordinator). The tool sends one request, prints one answer and exits; the session continues after it exits. Quitting the menu bar app, or `keepmacawake app quit`, ends the session.

## Commands

| Command | What it does |
| --- | --- |
| `keepmacawake status` | Shows the session state. |
| `keepmacawake status --agent` | The same in a few plain lines for an AI agent's context, for example from a session-start hook: whether a session runs and its time left, a newer version, and the trial. State only from the release after 1.0.1: no commands, no price and no install steps; the agent's rules are in the keepmacawake skill. The plugin's hook reads `status --json` instead. |
| `keepmacawake start --unlimited` | Starts a session without a time limit. |
| `keepmacawake start --hours N` | Starts a session of N whole hours, 1 to 168. |
| `keepmacawake stop` | Ends the session and restores the sleep setting. |
| `keepmacawake config get` | Shows the settings: battery use for the next session and the daily update check. |
| `keepmacawake config set --battery allowed\|ac-only [--min-battery N]` | Changes the battery settings. The threshold is 1 to 100%. A running session keeps its own settings. On a Mac without a built-in battery, allowing battery use or setting a threshold is refused (exit code 4): sessions there need AC power. |
| `keepmacawake config set --update-check daily\|off` | Turns the daily update check on (the default) or off. The panel has no switch for it. |
| `keepmacawake app launch` | Opens the menu bar app. |
| `keepmacawake app quit` | Ends the session, then quits the menu bar app. |
| `keepmacawake buy` | Opens the purchase page for this Mac in the browser and prints the link. |
| `keepmacawake restore` | Restores a purchase made for this Mac (one request to `keepmacawake.com`). |
| `keepmacawake check-updates` | Asks `keepmacawake.com` for the latest version now, also with the daily check off, and says whether a newer one is available. It installs nothing. |
| `keepmacawake capabilities --json` | Describes this contract: commands, options, phases, access states and exit codes. |

During the 3-day trial, counted from the first session on the Mac, a session lasts at most 8 hours; `start --unlimited` or `--hours` above 8 exits with 4 and `purchase_required` without touching anything, and so does any `start` after the trial. A running session is never ended by the trial. With `purchase_required` the JSON error says why (`reason`), carries a message addressed to the person at the Mac with the price and the steps (`user_message`), and lists the commands that may follow (`next_steps`), so an agent can pass it on without guessing.

`start` returns after the system service has confirmed the session, or refused it. With AC-only settings on battery the session is refused; with AC disconnected later, it waits for AC power (`phase` `waitingForAC`, `confirmed` false).

Options: `--json`, `--agent` (only with `status`, not with `--json`), `--timeout SECONDS` (1-120, default 15), `--no-input` (the tool never prompts), `--help`, `--version`.

## JSON output

With `--json`, stdout carries exactly one JSON object on one line; diagnostics go to stderr. Keys are stable; new keys may be added.

```json
{"access":{"mac_id":"0123456789abcdef0123456789abcdef","max_hours":null,"purchase":null,"state":"purchased","trial_ends_at":null,"trial_seconds_left":null,"trial_started":true},"app_version":"1.0.0","config":{"battery":"ac-only","battery_available":true,"min_battery_percent":20,"update_check":"daily"},"protocol_version":"2","result":"ok","schema_version":1,"session":{"confirmed":true,"hours":8,"last_end_reason":null,"live":true,"message":"Sleep prevention is on.","min_battery_percent":null,"phase":"active","remaining_seconds":28734,"unlimited":false},"update":{"available_version":null,"current_version":"1.0.0","install_command":null}}
```

| Key | Meaning |
| --- | --- |
| `result` | `ok` or `error` |
| `session.phase` | `checking`, `idle`, `starting`, `active`, `waitingForAC`, `stopping`, `unavailable` or `failed` |
| `session.confirmed` | True only while the system service has confirmed the session within the last 6 seconds |
| `session.live` | A session started through Keep Mac Awake is running |
| `session.remaining_seconds`, `session.hours`, `session.unlimited` | Time left and the accepted duration |
| `session.min_battery_percent` | The battery threshold of the running session, or null for AC only |
| `session.last_end_reason` | Why the last session ended, for example `durationElapsed`, `batteryThresholdReached`, `clientStopped` |
| `config.battery`, `config.min_battery_percent` | Settings for the next session |
| `config.battery_available` | False on a Mac without a built-in battery: `config.battery` is then always `ac-only` and the battery settings cannot be changed |
| `config.update_check` | `daily` (the default) or `off` |
| `update.current_version`, `update.available_version` | This version, and a newer one found by the last update check, or null |
| `update.install_command` | With a newer version: `curl -fsSL https://keepmacawake.com/install.sh \| sh`, which installs it after the administrator password and ends a running session; null otherwise. `update` itself is null from a build without a release version |
| `access.state` | `purchased`, `trial` or `trialEnded` |
| `access.trial_seconds_left`, `access.trial_started` | Time left in the trial (its full length before the first session); null when purchased |
| `access.max_hours` | The longest session a `start` may ask for; null without a limit |
| `access.mac_id` | This Mac's ID, used by `buy` and `restore` and for support |
| `access.trial_ends_at` | When a running trial ends, in UTC (for example `2026-10-24T09:00:00Z`); null before the first session and once purchased |
| `access.purchase` | Until this Mac is unlocked: `price` (`9 USD plus tax, one time, for this Mac`), `amount`, `currency`, `url` (the purchase page for this Mac), `buy_command`, `restore_command`; null once purchased |
| `error.code`, `error.message`, `error.retryable` | Present when `result` is `error` |
| `error.reason`, `error.user_message`, `error.next_steps` | With `purchase_required` only. `reason` is `trial_ended` or `trial_session_limit`; `user_message` is addressed to the person at the Mac and states the price; `next_steps` lists `command` and what it `does`: a start within the trial limit (only for `trial_session_limit`), `keepmacawake buy` and `keepmacawake restore` |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | The request failed |
| 2 | Invalid arguments |
| 4 | Action needed from the user, for example AC power, a purchase (`purchase_required`), or running without `sudo` |
| 5 | Conflict: a session already runs, or there is no session to stop |
| 6 | The background service is not available or Keep Mac Awake is not installed |
| 7 | No answer in time. After a `start` or `stop` that timed out, run `status`: the request may still have completed |

## Installing from the command line

`curl -fsSL https://keepmacawake.com/install.sh | sh` installs or updates Keep Mac Awake (the panel's Install does the same checks for a newer version the app found); `sh -s -- --uninstall` removes it, `--dry-run` only downloads and checks the package, `--version X.Y.Z` picks a release. The script checks the package's SHA-256, Developer ID signature and notarization before running macOS Installer, asks for an administrator once (in the terminal, or in a system dialog when no terminal is attached, as for an AI agent) and refuses while a session runs. Its exit codes: 0 done, 1 failed, 2 invalid arguments, 3 this Mac is not supported, 4 action needed from the user, 5 a session is running.

## Rules and limits

- Run it as the logged-in user. `sudo keepmacawake` is refused, and a call from a user who is not at the console cannot start a session.
- Any process of the same user can run the tool. It cannot tell a trusted agent from an untrusted one; it can only do what the panel does, and it never passes commands, paths or addresses to the system service.
- Nothing starts automatically, also not after a restart.
