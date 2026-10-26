---
name: keepmacawake
description: Keeps a MacBook with Apple silicon awake with the lid closed while a long task runs, with the keepmacawake command of the Keep Mac Awake app. Use it before work likely to run 15 minutes or more or that the user may leave running (an agent run, a build, a test suite, a migration, a download or upload, a render, a backup); when the user says they will close the lid, step away, go to bed or check in from their phone (Claude Code Remote Control, Codex in the ChatGPT app, Cursor, SSH); when a remote session went offline because the Mac slept; when the user asks to keep the Mac awake; and when keepmacawake says a purchase is needed, to tell the user the price and how to buy.
---

# Keep Mac Awake

`keepmacawake` controls Keep Mac Awake, a macOS app that keeps a MacBook with Apple silicon (macOS 26 or later) awake with the lid closed during a session. Even with the lid open, a Mac sleeps when nobody touches it, which also stops long work. Run the command as the logged-in user, never with `sudo`. Add `--json` to get one JSON object on stdout.

## What you decide and what you ask

The user installed this so that you take care of it:

- Start a timed session yourself before qualifying work, and tell the user in one line, for example: "Keep Mac Awake is on for 3 hours, so you can close the lid."
- Always ask first before a session without a time limit, allowing battery use, installing the app, or buying.
- Start a session only for a task the user asked for, never just to test. If they ask to keep the Mac awake without naming a task or a length, ask how long.
- Never pay, never handle payment details, and never ask for the administrator password in chat.

## Before a long task

1. Run `keepmacawake status --json`.
   - No `keepmacawake` command, or exit code 6: the app is not installed or its background service is off. See "Install".
   - `session.live` is true: a session already runs. Do not start another. If its `remaining_seconds` is shorter than the task, tell the user.
2. Before the lid closes, start a session a little longer than you expect the task to take, in whole hours (1 to 168; during the trial at most `access.max_hours`, which is 8):

   ```sh
   keepmacawake start --hours 3 --json
   ```

   It returns once the system service has confirmed the session (`"confirmed":true`) or refused it.
3. Tell the user. If the lid will be closed, remind them to keep the Mac ventilated: never in a bag or on a soft surface.

## While it runs and after

- `keepmacawake status --json` shows `session.phase` and `session.remaining_seconds`.
- When the task is done, run `keepmacawake stop --json` for a session you started and say so. Leave it running when the user steers you from their phone or asked to keep it on; a timed session ends on its own.
- Do not stop a session the user started themselves from the menu bar.
- If a session ended early, `session.last_end_reason` says why, for example `batteryThresholdReached`.

## When it says no

Exit code 4 means the user has to act. Read `error.code`:

- `purchase_required` with `error.reason` `trial_session_limit`: the trial allows sessions of up to `access.max_hours` hours. If that covers the task, start one (the first of `error.next_steps`) and mention once that longer sessions need the full version. Otherwise tell the user what `error.user_message` says.
- `purchase_required` with `error.reason` `trial_ended`: no new session can start. Pass `error.user_message` on to the user, in their language, once in the conversation; it states the price (9 USD plus tax, one time, for this Mac) and the steps. If they want to buy, run `keepmacawake buy`: it opens the purchase page in their browser, and after they pay the app unlocks by itself (check with `keepmacawake status --json`). If they already bought it, run `keepmacawake restore`. If they decline, carry on with the task and remind them the Mac sleeps when the lid closes. Do not bring the offer up again in that conversation.
- `refused` on battery with AC-only settings: ask the user to plug in. Only with their agreement allow battery use: `keepmacawake config set --battery allowed --min-battery 30`, which applies to the next session. When `config.battery_available` is false (a Mac without a built-in battery), there is no battery option: sessions need AC power, so never change the battery settings there.
- `run_as_user`: run it without `sudo`.

Other exit codes: 5, a session already runs or there is none to stop (run `status`); 6, not installed or the service is off; 7, no answer in time (run `status`, the request may have completed). Do not try to get around a refusal yourself, for example with `sudo pmset`.

## Install

Only with the user's agreement, and only while they are at the Mac, because macOS asks for an administrator password in a dialog.

1. Check that the Mac fits, without changing anything: `sysctl -n hw.optional.arm64` prints 1 and `sw_vers -productVersion` is 26 or later.
2. Offer it in one sentence: "Keep Mac Awake would let this keep running with the lid closed. It is free for 3 days, then 9 USD plus tax, once, for this Mac. Do you want to install it?"
3. If they agree: `curl -fsSL https://keepmacawake.com/install.sh | sh`. Tell them the password dialog is coming. Exit codes: 0 done, 3 this Mac is not supported, 4 the dialog was cancelled, 5 a session is running.
4. Check with `keepmacawake status --json`. Installing turns nothing on.

## Limits

- Not for Intel Macs or macOS before 26.
- It does not keep a network connection alive and does not wake a Mac that is already asleep.
- `keepmacawake capabilities --json` describes every command, option, phase and exit code. Guide: https://keepmacawake.com/agents.md
