// pi-keepmacawake: keeps a Mac awake while Pi works, through the keepmacawake
// command of the Keep Mac Awake app.
//
// By default it starts nothing by itself: /awake start [hours] starts a timed
// Keep Mac Awake session (the Mac stays awake, also with the lid closed), and
// /awake stop ends it. With /awake auto on (an opt-in, saved in Pi's agent
// folder), each Pi run starts a timed session when none is running. It runs
// only the keepmacawake command (status, start --hours N, stop), makes no
// network connection, never reads prompts or files, never installs anything,
// never changes battery settings and never starts a session without a time
// limit.
//
// It never ends a session by itself, only when the user runs /awake stop. The
// command's answers carry no session identity (no id, no start time), so Pi
// cannot prove that the running session is the one it started: the user may
// have replaced it with one of the same hours, and another Pi window may be
// relying on it. A session Pi started ends after its hours.

import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const DEFAULT_CLI_PATH = "/usr/local/bin/keepmacawake";
export const WEBSITE_URL =
  "https://keepmacawake.com/?utm_source=pi-gallery&utm_medium=referral&utm_campaign=pi-package&utm_content=not-installed";
export const DEFAULT_HOURS = 8;
export const MAX_HOURS = 168;
// The command waits up to 15 seconds for its background service; allow a little more.
const RUN_TIMEOUT_MS = 30_000;
// During a long run, how often to check that the session has not run out.
const CHECK_INTERVAL_MS = 10 * 60_000;
const STATUS_KEY = "keepmacawake";
const CONFIG_FILE_NAME = "pi-keepmacawake.json";
const RUNNING_PHASES = ["starting", "active", "waitingForAC"];

const MESSAGES = {
  notMac:
    "pi-keepmacawake works only on a Mac with Apple silicon and macOS 26 or later, through the Keep Mac Awake app. " +
    "It does nothing on this computer.",
  notInstalled:
    "Keep Mac Awake is not installed, so this Mac may sleep while Pi works, for example when the lid closes. " +
    "pi-keepmacawake needs the Keep Mac Awake app (any Mac with Apple silicon and macOS 26 or later, free trial) " +
    `and never installs anything itself. Get the app at ${WEBSITE_URL}`,
  firstSession:
    "Keep Mac Awake is installed, but no session has run on this Mac yet, and the first one starts its free trial. " +
    "pi-keepmacawake leaves that step to you: run /awake start, or start a session from the Keep Mac Awake menu " +
    "bar panel. After that, Pi keeps this Mac awake while it works.",
  batteryDefault: (floor) =>
    "Run on battery in Keep Mac Awake turned itself on, and you have not chosen it yet, so Pi starts no session by " +
    `itself: when the Mac is unplugged, a session would run on battery down to ${floor}%. Run /awake start to start ` +
    "one anyway; Pi then starts them by itself until it quits. To let Pi start them every time, set it yourself with " +
    "keepmacawake config set --battery allowed in Terminal; to keep sessions on AC power, turn Run on battery off in " +
    "the Keep Mac Awake menu bar panel.",
  trialEnded:
    "The Keep Mac Awake free trial on this Mac has ended, so Pi cannot keep this Mac awake. The full version is in " +
    "the Keep Mac Awake menu bar panel.",
  howTo:
    "Pi does not keep this Mac awake by itself. /awake start [hours] keeps it awake, also with the lid closed; " +
    "/awake auto on starts a timed session with each Pi run.",
  firstHold:
    "Keep Mac Awake keeps this Mac awake while Pi works, also with the lid closed. The session ends after its " +
    "hours, or with /awake stop; Pi never ends it by itself. Keep a closed Mac ventilated: never in a bag or on a " +
    "soft surface.",
  ventilation: "Keep a closed Mac ventilated: never in a bag or on a soft surface.",
  waitingForAC: "Keep Mac Awake waits for AC power: plug in this Mac to keep it awake while Pi works.",
  serviceDown:
    "Keep Mac Awake is installed, but its background service did not answer. Open Keep Mac Awake from " +
    "Applications; Pi tries again on its next run.",
  timeout: "Keep Mac Awake did not answer in time. Pi tries again on its next run; /awake shows the state.",
  problem: "Keep Mac Awake reports a problem. Open its menu bar panel; Pi tries again on its next run.",
  sudo: "The keepmacawake command must run as the logged-in user, never with sudo.",
};

const HELP =
  "/awake: show the state. /awake start [N]: keep this Mac awake for N hours now (default 8), also with the lid " +
  "closed. /awake stop: end the session (Pi never ends one by itself). " +
  "/awake auto on, /awake auto off: start a timed session with each Pi run, or not (off by default; saved). " +
  "/awake hours N: the longest session Pi starts (1 to 168, default 8).";

/** The keepmacawake command to run, or null when there is none. */
export function resolveCli(env) {
  // KEEPMACAWAKE_CLI, when set (also when empty), is the only path tried: the
  // tests set it to a fake command, so they can never reach the real one.
  if (Object.prototype.hasOwnProperty.call(env, "KEEPMACAWAKE_CLI")) {
    return String(env.KEEPMACAWAKE_CLI ?? "").trim() || null;
  }
  return DEFAULT_CLI_PATH;
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
 * Runs `keepmacawake <args> --json --no-input`. Resolves to { missing: true }
 * when the command is not there, otherwise to { exitCode, reply }, with the
 * command's documented exit codes (7 also when this extension stopped waiting).
 */
export function runCli(cli, args, timeoutMs = RUN_TIMEOUT_MS) {
  if (!cli) return Promise.resolve({ missing: true });
  return new Promise((resolve) => {
    execFile(
      cli,
      [...args, "--json", "--no-input"],
      { timeout: timeoutMs, maxBuffer: 1024 * 1024, windowsHide: true },
      (error, stdout) => {
        if (error && (error.code === "ENOENT" || error.code === "EACCES")) return resolve({ missing: true });
        let exitCode = 0;
        if (error) exitCode = typeof error.code === "number" ? error.code : error.killed ? 7 : 1;
        resolve({ exitCode, reply: parseReply(stdout) });
      },
    );
  });
}

function wholeNumber(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}

/** The few fields of a reply this extension uses. */
export function readState(reply) {
  const session = reply?.session ?? {};
  const access = reply?.access ?? {};
  const config = reply?.config ?? {};
  return {
    session: {
      phase: typeof session.phase === "string" ? session.phase : null,
      live: session.live === true,
      unlimited: session.unlimited === true,
      hours: wholeNumber(session.hours),
      remainingSeconds: wholeNumber(session.remaining_seconds),
      lastEndReason: typeof session.last_end_reason === "string" ? session.last_end_reason : null,
    },
    access: {
      state: typeof access.state === "string" ? access.state : null,
      trialStarted: typeof access.trial_started === "boolean" ? access.trial_started : null,
      trialSecondsLeft: wholeNumber(access.trial_seconds_left),
      maxHours: wholeNumber(access.max_hours) || null,
    },
    batteryAvailable: config.battery_available === true,
    batteryAllowed: config.battery === "allowed",
    // False only when the app (1.0.11 or later) says Run on battery turned itself on; an
    // older app sends no battery_chosen, and there battery use was always the user's choice.
    batteryChosen: config.battery_chosen !== false,
    minBatteryPercent: wholeNumber(config.min_battery_percent),
  };
}

/** Run on battery turned itself on and the user has not chosen it: a session may run on battery. */
export function batteryNotChosen(state) {
  return state.batteryAvailable && state.batteryAllowed && !state.batteryChosen;
}

export function isRunning(state) {
  return state.session.live && RUNNING_PHASES.includes(state.session.phase);
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

function describeSession(state) {
  const { session } = state;
  if (session.phase === "failed" || session.phase === "unavailable") return MESSAGES.problem;
  if (!isRunning(state)) return "No Keep Mac Awake session is running; this Mac sleeps as usual.";
  if (session.phase === "waitingForAC") return "A Keep Mac Awake session is waiting for AC power.";
  if (session.unlimited) return "A Keep Mac Awake session is running without a time limit.";
  if (session.remainingSeconds != null) {
    return `A Keep Mac Awake session is running, ${formatDuration(session.remainingSeconds)} left.`;
  }
  return "A Keep Mac Awake session is running.";
}

function describeTrial(state) {
  const { access } = state;
  if (access.state === "trialEnded") return " The free trial on this Mac has ended.";
  if (access.state !== "trial") return "";
  if (access.trialStarted && access.trialSecondsLeft != null) {
    return ` Free trial: ${formatDuration(access.trialSecondsLeft)} left.`;
  }
  return " The free trial starts with the first session.";
}

/** The app's own error message, on one line, or null. */
function appMessage(reply) {
  const message = reply?.error?.message;
  if (typeof message !== "string") return null;
  const line = message.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  return line ? line.slice(0, 300) : null;
}

function errorCode(reply, key = "code") {
  const value = reply?.error?.[key];
  return typeof value === "string" ? value : null;
}

/** Whole hours from 1 to 168, or null. */
export function parseHours(value) {
  const text = String(value ?? "").trim().replace(/\s*h(ours?)?$/i, "");
  if (!/^\d{1,3}$/.test(text)) return null;
  const hours = Number(text);
  return hours >= 1 && hours <= MAX_HOURS ? hours : null;
}

/** true or false when the text names a choice, otherwise null. */
function parseSwitch(value) {
  const text = String(value ?? "").trim();
  if (/^(1|on|true|yes)$/i.test(text)) return true;
  if (/^(0|off|false|no)$/i.test(text)) return false;
  return null;
}

/** The file where /awake auto on|off is saved: in Pi's agent folder (PI_CODING_AGENT_DIR or ~/.pi/agent). */
export function configPath(env) {
  let dir = String(env.PI_CODING_AGENT_DIR ?? "").trim();
  if (dir === "~") dir = homedir();
  else if (dir.startsWith("~/")) dir = join(homedir(), dir.slice(2));
  return join(dir || join(homedir(), ".pi", "agent"), CONFIG_FILE_NAME);
}

function readConfig(file) {
  try {
    const config = JSON.parse(readFileSync(file, "utf8"));
    return config && typeof config === "object" && !Array.isArray(config) ? config : {};
  } catch {
    return {};
  }
}

/** Saves `auto`, keeping anything else in the file. Returns false when it could not. */
function saveAuto(file, auto) {
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${JSON.stringify({ ...readConfig(file), auto }, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/**
 * Automatic start is off unless the user turned it on: KEEPMACAWAKE_PI_AUTO
 * for one launch, or /awake auto on, saved in the config file.
 */
function readAuto(env, file) {
  const fromEnv = parseSwitch(env.KEEPMACAWAKE_PI_AUTO);
  if (fromEnv != null) return { auto: fromEnv, chosen: true };
  const saved = readConfig(file).auto;
  if (typeof saved === "boolean") return { auto: saved, chosen: true };
  return { auto: false, chosen: false };
}

/**
 * Wires the extension to Pi and returns a small controller (used by the tests).
 * Options: env, platform, now, configFile, checkIntervalMs.
 * @param {import("@earendil-works/pi-coding-agent").ExtensionAPI} pi
 */
export function setup(pi, options = {}) {
  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const now = options.now ?? Date.now;
  const checkIntervalMs = options.checkIntervalMs ?? CHECK_INTERVAL_MS;
  const configFile = options.configFile ?? configPath(env);
  const { auto, chosen } = readAuto(env, configFile);
  // chosen: the user picked on or off, so the how-to notice is not needed.
  const settings = { auto, chosen, hours: parseHours(env.KEEPMACAWAKE_PI_HOURS) ?? DEFAULT_HOURS };
  // The user's own /awake start in this Pi process is their yes to sessions that may run on battery.
  let batteryAgreed = false;
  const saidOnce = new Set(); // notices given once per Pi process
  let saidThisRun = new Set(); // notices given once per run
  let running = false; // a Pi run is in progress in this process and holds the Mac awake
  let lastCheck = 0;
  let queue = Promise.resolve();

  const enqueue = (work) => {
    queue = queue.then(work).catch(() => {});
    return queue;
  };
  const cli = () => resolveCli(env);

  function tell(ctx, text, level = "info", key = null, perRun = false) {
    if (key) {
      const said = perRun ? saidThisRun : saidOnce;
      if (said.has(key)) return;
      said.add(key);
    }
    if (ctx?.hasUI) ctx.ui.notify(text, level);
  }

  function showStatus(ctx, text) {
    if (ctx?.hasUI) ctx.ui.setStatus(STATUS_KEY, text);
  }

  /** Tells the user why a command did not work; returns nothing. */
  function explain(ctx, run, action, perRun = true) {
    if (run.missing) return tell(ctx, MESSAGES.notInstalled, "warning", "missing");
    const { exitCode, reply } = run;
    const code = errorCode(reply);
    if (exitCode === 4 && code === "purchase_required") return tell(ctx, MESSAGES.trialEnded, "warning", "trial-ended");
    if (exitCode === 4 && code === "run_as_user") return tell(ctx, MESSAGES.sudo, "warning", "sudo", perRun);
    if (exitCode === 4) {
      const said = appMessage(reply);
      const battery = readState(reply).batteryAvailable
        ? " Battery use is your choice in the Keep Mac Awake menu bar panel."
        : "";
      return tell(
        ctx,
        `Keep Mac Awake needs you before it can keep this Mac awake${said ? `: "${said}"` : "."}${battery}`,
        "warning",
        "needs-user",
        perRun,
      );
    }
    if (exitCode === 6 && code === "not_installed") return tell(ctx, MESSAGES.notInstalled, "warning", "missing");
    if (exitCode === 6) return tell(ctx, MESSAGES.serviceDown, "warning", "service-down", perRun);
    if (exitCode === 7) return tell(ctx, MESSAGES.timeout, "warning", "timeout", perRun);
    return tell(ctx, `Keep Mac Awake could not ${action} (exit code ${exitCode}).`, "warning", `failed-${action}`, perRun);
  }

  async function status(ctx) {
    const run = await runCli(cli(), ["status"]);
    if (run.missing || run.exitCode !== 0 || !run.reply) {
      explain(ctx, run, "read its status");
      return null;
    }
    return readState(run.reply);
  }

  /** Starts a session of `hours`; lowers it to the trial's limit once if needed. */
  async function start(ctx, hours) {
    let run = await runCli(cli(), ["start", "--hours", String(hours)]);
    if (run.exitCode === 4 && errorCode(run.reply, "reason") === "trial_session_limit") {
      const max = readState(run.reply).access.maxHours ?? DEFAULT_HOURS;
      if (max < hours) {
        hours = max;
        run = await runCli(cli(), ["start", "--hours", String(hours)]);
      }
    }
    return { run, hours };
  }

  /** At the start of a run (and now and then during it): make sure the Mac stays awake. */
  async function hold(ctx, renewal = false) {
    if (!running) return;
    const state = await status(ctx);
    if (!state || !running) return;
    if (isRunning(state)) {
      showStatus(ctx, "Mac awake");
      return;
    }
    showStatus(ctx, undefined);
    if (state.session.phase === "failed" || state.session.phase === "unavailable") {
      return tell(ctx, MESSAGES.problem, "warning", "problem", true);
    }
    // During a run, only a session that ran out of time is started again: one
    // the user stopped, or that ended for battery or heat, stays ended.
    if (renewal && state.session.lastEndReason !== "durationElapsed") return;
    if (state.access.state === "trialEnded") return tell(ctx, MESSAGES.trialEnded, "warning", "trial-ended");
    // The first session on a Mac starts the free trial: that is the user's call.
    if (state.access.state === "trial" && state.access.trialStarted === false) {
      return tell(ctx, MESSAGES.firstSession, "info", "first-session");
    }
    // Battery use needs the user's yes; the app's default is not one. /awake start is.
    if (!batteryAgreed && batteryNotChosen(state)) {
      return tell(ctx, MESSAGES.batteryDefault(state.minBatteryPercent ?? 20), "info", "battery-default");
    }
    const hours = Math.min(settings.hours, state.access.maxHours ?? settings.hours);
    const { run } = await start(ctx, hours);
    if (run.exitCode === 0 && !run.missing) {
      showStatus(ctx, "Mac awake");
      if (run.reply?.session?.phase === "waitingForAC") return tell(ctx, MESSAGES.waitingForAC, "warning", "ac", true);
      return tell(ctx, MESSAGES.firstHold, "info", "first-hold");
    }
    if (run.exitCode === 5) return showStatus(ctx, "Mac awake"); // another Pi window started it a moment ago
    explain(ctx, run, "start a session");
  }

  function begin(ctx) {
    if (running) return;
    if (platform !== "darwin") return tell(ctx, MESSAGES.notMac, "info", "not-mac");
    // Off (the default): no command runs; one line on how to keep the Mac awake.
    if (!settings.auto) return settings.chosen ? undefined : tell(ctx, MESSAGES.howTo, "info", "how-to");
    running = true;
    saidThisRun = new Set();
    lastCheck = now();
    enqueue(() => hold(ctx));
  }

  /** The run is over. The session stays: it ends after its hours, or with /awake stop. */
  function end(ctx) {
    if (!running) return queue;
    running = false;
    showStatus(ctx, undefined);
    return queue;
  }

  function describeAuto() {
    return settings.auto
      ? `Automatic start is on: each Pi run starts a session of ${settings.hours} hours at most when none is running. ` +
          "Pi never ends it by itself: it ends after its hours, or with /awake stop (/awake auto off)."
      : "Automatic start is off: Pi starts no session by itself. /awake start [hours] keeps this Mac awake now; " +
          "/awake auto on starts a timed session with each Pi run.";
  }

  pi.on("agent_start", async (_event, ctx) => {
    begin(ctx);
  });

  pi.on("turn_start", async (_event, ctx) => {
    if (!running || now() - lastCheck < checkIntervalMs) return;
    lastCheck = now();
    enqueue(() => hold(ctx, true));
  });

  // agent_end is not final (Pi may retry or continue); agent_settled is.
  pi.on("agent_settled", async (_event, ctx) => {
    end(ctx);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    await end(ctx);
    showStatus(ctx, undefined);
  });

  pi.registerCommand("awake", {
    description: "Keep Mac Awake: keep this Mac awake, also with the lid closed (/awake help)",
    getArgumentCompletions: (prefix) => {
      const items = ["status", "start", "stop", "auto", "auto on", "auto off", "hours", "help"]
        .filter((value) => value.startsWith(String(prefix ?? "").trimStart()))
        .map((value) => ({ value, label: value }));
      return items.length ? items : null;
    },
    handler: async (args, ctx) => {
      const [word = "status", ...rest] = String(args ?? "").trim().split(/\s+/).filter(Boolean);
      const extra = rest.join(" ");
      switch (word.toLowerCase()) {
        case "status": {
          if (platform !== "darwin") return tell(ctx, MESSAGES.notMac);
          await enqueue(async () => {
            const state = await status(ctx);
            const mode = ` ${describeAuto()}`;
            if (state) tell(ctx, `${describeSession(state)}${describeTrial(state)}${mode}`);
          });
          return;
        }
        case "auto": {
          const choice = parseSwitch(extra);
          if (!extra) return tell(ctx, describeAuto());
          if (choice == null) return tell(ctx, "Use /awake auto on or /awake auto off.", "warning");
          settings.auto = choice;
          settings.chosen = true;
          const saved = saveAuto(configFile, choice)
            ? ""
            : " It could not be saved, so it applies until Pi quits.";
          if (choice) {
            tell(ctx, `${describeAuto()}${saved}`);
            if (!ctx.isIdle?.()) begin(ctx);
          } else {
            await end(ctx);
            tell(ctx, `${describeAuto()}${saved}`);
          }
          return;
        }
        case "hours": {
          const hours = parseHours(extra);
          if (hours == null) return tell(ctx, "Give whole hours from 1 to 168, for example /awake hours 12.", "warning");
          settings.hours = hours;
          tell(ctx, `Pi now starts sessions of ${hours} hours at most. A running session keeps its own time.`);
          return;
        }
        case "start": {
          if (platform !== "darwin") return tell(ctx, MESSAGES.notMac);
          const hours = extra ? parseHours(extra) : settings.hours;
          if (hours == null) return tell(ctx, "Give whole hours from 1 to 168, for example /awake start 3.", "warning");
          await enqueue(async () => {
            const { run, hours: started } = await start(ctx, hours);
            if (run.exitCode === 0 && !run.missing) {
              showStatus(ctx, "Mac awake");
              if (batteryNotChosen(readState(run.reply))) batteryAgreed = true;
              const floor = wholeNumber(run.reply?.session?.min_battery_percent);
              const battery = floor != null ? ` When the Mac is unplugged, it runs on battery down to ${floor}%.` : "";
              tell(ctx, `Keep Mac Awake keeps this Mac awake for ${started} hours, also with the lid closed.${battery} Pi leaves this session running; /awake stop ends it.`);
              return tell(ctx, MESSAGES.ventilation, "info", "ventilation");
            }
            if (run.exitCode === 5) return tell(ctx, "A Keep Mac Awake session is already running; /awake shows its time left.");
            explain(ctx, run, "start a session", false);
          });
          return;
        }
        case "stop": {
          if (platform !== "darwin") return tell(ctx, MESSAGES.notMac);
          await enqueue(async () => {
            const run = await runCli(cli(), ["stop"]);
            if (!run.missing && (run.exitCode === 0 || run.exitCode === 5)) {
              showStatus(ctx, undefined);
              return tell(
                ctx,
                run.exitCode === 0
                  ? "The Keep Mac Awake session has ended; this Mac sleeps as usual."
                  : "No Keep Mac Awake session is running.",
              );
            }
            explain(ctx, run, "end the session", false);
          });
          return;
        }
        default:
          tell(ctx, HELP);
      }
    },
  });

  return {
    settings,
    idle: () => queue,
    get running() {
      return running;
    },
  };
}

/** @param {import("@earendil-works/pi-coding-agent").ExtensionAPI} pi */
export default function keepMacAwake(pi) {
  setup(pi);
}
