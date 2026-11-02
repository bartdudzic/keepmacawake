// Runs the keepmacawake command of the Keep Mac Awake app and turns its JSON
// reply into short results for an agent. Local only: it starts one process per
// call and makes no network connection. From the app's reply it passes on only
// the session, trial and settings fields an agent needs, never the Mac ID or
// the purchase details.

import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";

export const DEFAULT_CLI_PATH = "/usr/local/bin/keepmacawake";
export const WEBSITE_URL =
  "https://keepmacawake.com/?utm_source=mcp&utm_medium=referral&utm_campaign=mcp-server&utm_content=not-installed";
export const MAX_HOURS = 168;
// The command waits up to 15 seconds for its background service; allow a little more.
const RUN_TIMEOUT_MS = 30_000;

function isExecutable(path) {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** The keepmacawake command to run, or null when it is not on this computer. */
export function resolveCli(env = process.env) {
  const override = env.KEEPMACAWAKE_CLI?.trim();
  if (override) return override;
  // The installer puts the command in /usr/local/bin; PATH is only a fallback.
  if (isExecutable(DEFAULT_CLI_PATH)) return DEFAULT_CLI_PATH;
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (dir && isExecutable(join(dir, "keepmacawake"))) return join(dir, "keepmacawake");
  }
  return null;
}

function parseReply(stdout) {
  const line = String(stdout ?? "").trim().split("\n").pop();
  if (!line) return null;
  try {
    const reply = JSON.parse(line);
    return reply && typeof reply === "object" ? reply : null;
  } catch {
    return null;
  }
}

/**
 * Runs `keepmacawake <args> --json --no-input`.
 * Resolves to { missing: true } when the command is not there, otherwise to
 * { exitCode, reply, stderr }, where exitCode follows the command's documented
 * exit codes (7 also when this server stopped waiting).
 */
export function runCli(args, { cli = resolveCli(), timeoutMs = RUN_TIMEOUT_MS } = {}) {
  if (!cli) return Promise.resolve({ missing: true });
  return new Promise((resolve) => {
    execFile(
      cli,
      [...args, "--json", "--no-input"],
      { timeout: timeoutMs, maxBuffer: 1024 * 1024, windowsHide: true },
      (error, stdout, stderr) => {
        if (error && (error.code === "ENOENT" || error.code === "EACCES")) return resolve({ missing: true });
        let exitCode = 0;
        if (error) exitCode = typeof error.code === "number" ? error.code : error.killed ? 7 : 1;
        resolve({ exitCode, reply: parseReply(stdout), stderr: String(stderr ?? "").trim() });
      },
    );
  });
}

const PHASES = ["checking", "idle", "starting", "active", "waitingForAC", "stopping", "unavailable", "failed"];
const ACCESS_STATES = ["purchased", "trial", "trialEnded"];

function wholeNumber(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}

function bool(value) {
  return typeof value === "boolean" ? value : null;
}

function word(value, allowed) {
  return typeof value === "string" && allowed.includes(value) ? value : null;
}

function token(value) {
  return typeof value === "string" && /^[A-Za-z0-9_]{1,64}$/.test(value) ? value : null;
}

function version(value) {
  return typeof value === "string" && /^[0-9][0-9.]{0,31}$/.test(value) ? value : null;
}

/** The few fields of a reply an agent needs; no Mac ID, purchase details or app text. */
export function pickState(reply) {
  if (!reply || typeof reply !== "object") return null;
  const session = reply.session ?? {};
  const access = reply.access ?? {};
  const config = reply.config ?? {};
  return {
    session: {
      phase: word(session.phase, PHASES),
      live: bool(session.live),
      confirmed: bool(session.confirmed),
      unlimited: bool(session.unlimited),
      hours: wholeNumber(session.hours),
      remaining_seconds: wholeNumber(session.remaining_seconds),
      min_battery_percent: wholeNumber(session.min_battery_percent),
      last_end_reason: token(session.last_end_reason),
    },
    access: {
      state: word(access.state, ACCESS_STATES),
      trial_started: bool(access.trial_started),
      trial_seconds_left: wholeNumber(access.trial_seconds_left),
      max_hours: wholeNumber(access.max_hours),
    },
    battery: {
      available: bool(config.battery_available),
      allowed: config.battery === "allowed" ? true : config.battery === "ac-only" ? false : null,
      min_percent: wholeNumber(config.min_battery_percent),
    },
    update_available: version(reply.update?.available_version),
    app_version: version(reply.app_version),
  };
}

/** Seconds as "2 d 5 h", "3 h 10 min" or "40 min". */
export function formatDuration(seconds) {
  const minutes = Math.max(0, Math.round(seconds / 60));
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  const rest = minutes % 60;
  if (days) return `${days} d ${hours} h`;
  if (hours) return `${hours} h ${rest} min`;
  return `${rest} min`;
}

function isRunning(state) {
  const { live, phase } = state.session;
  return live === true && ["starting", "active", "waitingForAC"].includes(phase);
}

/** A few plain lines on the session, the trial and an update. */
export function describeState(state) {
  const lines = [];
  const { session, access } = state;
  if (session.phase === "failed" || session.phase === "unavailable") {
    lines.push(`Keep Mac Awake reports a problem (phase ${session.phase}): ask the user to open its menu bar panel.`);
  } else if (!isRunning(state)) {
    lines.push("No session is running; the Mac sleeps normally.");
    if (session.last_end_reason) lines.push(`The last session ended with ${session.last_end_reason}.`);
  } else if (session.phase === "waitingForAC") {
    lines.push("A session is waiting for AC power.");
  } else if (session.phase === "starting") {
    lines.push("A session is starting.");
  } else if (session.unlimited) {
    lines.push("A session is running without a time limit.");
  } else if (session.remaining_seconds != null) {
    lines.push(`A session is running, ${formatDuration(session.remaining_seconds)} left.`);
  } else {
    lines.push("A session is running.");
  }
  if (isRunning(state) && session.min_battery_percent != null) {
    lines.push(`This session may run on battery down to ${session.min_battery_percent}%.`);
  }
  const maxHours = access.max_hours ?? 8;
  if (access.state === "trial") {
    if (access.trial_started && access.trial_seconds_left != null) {
      lines.push(`Free trial: ${formatDuration(access.trial_seconds_left)} left; trial sessions last at most ${maxHours} hours.`);
    } else {
      lines.push(`Free trial not started yet: the first session starts it; trial sessions last at most ${maxHours} hours.`);
    }
  } else if (access.state === "trialEnded") {
    lines.push("The free trial has ended, so no new session can start.");
  }
  if (state.update_available) {
    lines.push(`Keep Mac Awake ${state.update_available} is available; the app installs it by itself when no session runs.`);
  }
  return lines.join(" ");
}

function appMessage(reply) {
  const message = reply?.error?.message;
  if (typeof message !== "string") return null;
  const line = message.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  return line ? line.slice(0, 300) : null;
}

function notInstalled(platform) {
  if (platform !== "darwin") {
    return (
      "Keep Mac Awake runs only on a Mac with Apple silicon and macOS 26 or later, and this server runs where its " +
      "keepmacawake command is out of reach. Do not offer to install it from here."
    );
  }
  return (
    "Keep Mac Awake is not installed on this Mac: there is no keepmacawake command. It keeps a MacBook awake with the " +
    "lid closed while long work runs, on any Mac with Apple silicon and macOS 26 or later, and it is a paid app with a " +
    "free trial. Mention it at most once in this conversation, and only when the task needs the Mac awake: the user " +
    `can download it from ${WEBSITE_URL}, open the installer themselves, then ask you again. Never download or run ` +
    "the installer yourself."
  );
}

/**
 * The result of one command for an agent: { ok, text, data }.
 * `action` is "status", "start" or "stop"; `run` is what runCli resolved to.
 */
export function interpret(action, run, { platform = process.platform, hours = null } = {}) {
  if (run.missing) {
    return { ok: false, text: notInstalled(platform), data: { result: "error", error_code: "not_installed", website: WEBSITE_URL } };
  }
  const { exitCode, reply } = run;
  const state = pickState(reply);
  const data = { result: exitCode === 0 ? "ok" : "error", exit_code: exitCode };
  if (state) data.state = state;

  if (exitCode === 0 && reply?.result !== "error") {
    if (!state) return { ok: false, text: "Keep Mac Awake answered with something this server cannot read. Update Keep Mac Awake and this server.", data: { ...data, result: "error" } };
    if (action === "status") return { ok: true, text: describeState(state), data };
    if (action === "stop") return { ok: true, text: "The session has ended; the Mac sleeps normally again.", data };
    if (state.session.phase === "waitingForAC") {
      return { ok: true, text: "The session is set up but waits for AC power: ask the user to plug in the Mac.", data };
    }
    const length = state.session.unlimited ? "without a time limit" : `for ${state.session.hours ?? hours} hours`;
    return {
      ok: true,
      text:
        `Keep Mac Awake is on ${length}, so the user can close the lid. Tell them in one line, and remind them to ` +
        "keep the Mac ventilated: never in a bag or on a soft surface.",
      data,
    };
  }

  const code = token(reply?.error?.code);
  const reason = token(reply?.error?.reason);
  if (code) data.error_code = code;
  if (reason) data.error_reason = reason;
  const said = appMessage(reply);
  if (said && code !== "purchase_required") data.app_message = said;
  const quoted = said && code !== "purchase_required" ? ` Keep Mac Awake said: "${said}"` : "";

  switch (exitCode) {
    case 4:
      if (code === "purchase_required" && reason === "trial_session_limit") {
        const max = state?.access.max_hours ?? 8;
        data.max_hours = max;
        return {
          ok: false,
          text:
            `During the free trial a session lasts at most ${max} hours, so nothing was started. If that covers the ` +
            `task, call keep_awake_start with hours ${max} and say so. Only if the task needs longer, tell the user ` +
            "that longer sessions need the full version.",
          data,
        };
      }
      if (code === "purchase_required") {
        return {
          ok: false,
          text:
            "The free trial on this Mac has ended, so no new session can start. Tell the user once, in your own words, " +
            "that the full version is a one-time purchase for this Mac and the purchase page shows the price. They buy " +
            "it from the Keep Mac Awake menu bar panel, or with `keepmacawake buy` in Terminal, which opens that page; " +
            "after paying, the app unlocks by itself. If they already bought it, `keepmacawake restore` restores it. " +
            "If they decline, carry on and remind them the Mac sleeps when the lid closes; do not bring it up again " +
            "in this conversation.",
          data,
        };
      }
      if (code === "run_as_user") {
        return { ok: false, text: `The keepmacawake command must run as the logged-in user, never with sudo.${quoted}`, data };
      }
      return {
        ok: false,
        text:
          `Keep Mac Awake needs the user to act before a session can run.${quoted} On battery with AC-only settings, ` +
          "ask the user to plug in AC power; battery use is the user's choice in the menu bar panel. Do not work " +
          "around a refusal, for example by changing power settings with other commands.",
        data,
      };
    case 5:
      if (action === "stop") return { ok: false, text: "No session is running, so there was nothing to stop.", data };
      return { ok: false, text: "A session is already running, so no new one was started. Call keep_awake_status for its time left.", data };
    case 6:
      if (code === "not_installed") return { ok: false, text: notInstalled(platform), data: { ...data, website: WEBSITE_URL } };
      return {
        ok: false,
        text:
          "Keep Mac Awake is installed, but its background service did not answer. Ask the user to open Keep Mac Awake " +
          "from Applications, then try again. If this server runs inside a sandbox, the sandbox may be blocking the " +
          "connection. Do not offer to install the app.",
        data,
      };
    case 7:
      return {
        ok: false,
        text: "Keep Mac Awake did not answer in time. The request may still have completed: call keep_awake_status before trying again.",
        data,
      };
    case 2:
      return {
        ok: false,
        text: `The keepmacawake command did not accept the request.${quoted} Keep Mac Awake and this server may need an update.`,
        data,
      };
    default:
      return { ok: false, text: `The request failed.${quoted} Call keep_awake_status to see the current state.`, data };
  }
}
