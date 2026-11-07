// Tests against a fake keepmacawake command and a fake Pi: nothing here
// starts, stops or reads a real Keep Mac Awake session. Every test passes the
// fake's path as KEEPMACAWAKE_CLI, the only path the extension then tries.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import keepMacAwake, { WEBSITE_URL, configPath, parseHours, resolveCli, setup } from "../src/index.js";

const FAKE = fileURLToPath(new URL("./fake-keepmacawake.mjs", import.meta.url));
chmodSync(FAKE, 0o755);

let dir;
let configFile;
let clock;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "pi-kma-test-"));
  configFile = join(dir, "pi-agent", "pi-keepmacawake.json");
  process.env.FAKE_KMA_DIR = dir;
  clock = 1_800_000_000_000;
  setFake({});
});

afterEach(() => {
  // Whatever a test did, the fake is the only command that ran, and only with
  // status, start --hours N or stop: never no time limit, battery or buying.
  for (const args of calls()) {
    assert.ok(["status", "start", "stop"].includes(args[0]), `unexpected command ${args.join(" ")}`);
    assert.ok(!args.includes("--unlimited") && !args.includes("--battery"), `unexpected option in ${args.join(" ")}`);
  }
  rmSync(dir, { recursive: true, force: true });
  delete process.env.FAKE_KMA_DIR;
});

function setFake({ session = { live: false }, access = {}, battery_available = true, startPhase } = {}) {
  writeFileSync(join(dir, "state.json"), JSON.stringify({ session, access, battery_available, startPhase }));
}

function force(replies) {
  writeFileSync(join(dir, "replies.json"), JSON.stringify(replies));
}

function fakeState() {
  return JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
}

function calls() {
  const file = join(dir, "calls.jsonl");
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function commands() {
  return calls().map((args) => args.filter((a) => a !== "--json" && a !== "--no-input").join(" "));
}

function savedConfig() {
  return existsSync(configFile) ? JSON.parse(readFileSync(configFile, "utf8")) : null;
}

/**
 * A fake Pi: records handlers and the one command, and a ctx that records the UI.
 * `saved` is written to the config file first: { auto: true } (automatic start
 * turned on with /awake auto on) unless a test passes null (nothing saved: the
 * default) or "keep" (the file as it is).
 */
function makePi({ env = {}, platform = "darwin", checkIntervalMs, saved = { auto: true } } = {}) {
  if (saved === null) rmSync(configFile, { force: true });
  else if (saved !== "keep") {
    mkdirSync(join(dir, "pi-agent"), { recursive: true });
    writeFileSync(configFile, JSON.stringify(saved));
  }
  const handlers = {};
  const command = {};
  const notes = [];
  const statuses = [];
  let idle = true;
  const pi = {
    on: (event, handler) => {
      (handlers[event] ??= []).push(handler);
    },
    registerCommand: (name, options) => {
      command[name] = options;
    },
  };
  const ctx = {
    hasUI: true,
    mode: "tui",
    isIdle: () => idle,
    ui: {
      notify: (text, level) => notes.push({ text, level }),
      setStatus: (key, text) => statuses.push({ key, text }),
    },
  };
  const fullEnv = { KEEPMACAWAKE_CLI: FAKE, ...env };
  assert.equal(resolveCli(fullEnv), fullEnv.KEEPMACAWAKE_CLI, "tests must name the command themselves");
  const controller = setup(pi, {
    env: fullEnv,
    platform,
    configFile,
    now: () => clock,
    checkIntervalMs,
  });
  const fire = async (event) => {
    for (const handler of handlers[event] ?? []) await handler({}, ctx);
    await controller.idle();
  };
  return {
    controller,
    notes,
    statuses,
    texts: () => notes.map((n) => n.text).join("\n"),
    lastStatus: () => statuses.at(-1)?.text,
    run: async () => {
      idle = false;
      await fire("agent_start");
    },
    turn: () => fire("turn_start"),
    settle: async () => {
      await fire("agent_settled");
      idle = true;
    },
    shutdown: () => fire("session_shutdown"),
    awake: async (args = "") => {
      await command.awake.handler(args, ctx);
      await controller.idle();
    },
    complete: (prefix) => command.awake.getArgumentCompletions(prefix),
  };
}

test("the default export registers with Pi without running anything", () => {
  const events = [];
  let name;
  keepMacAwake({ on: (event) => events.push(event), registerCommand: (n) => (name = n) });
  assert.deepEqual(events.sort(), ["agent_settled", "agent_start", "session_shutdown", "turn_start"]);
  assert.equal(name, "awake");
  assert.deepEqual(calls(), []);
});

test("KEEPMACAWAKE_CLI, also empty, is the only path tried", () => {
  assert.equal(resolveCli({ KEEPMACAWAKE_CLI: "" }), null);
  assert.equal(resolveCli({ KEEPMACAWAKE_CLI: " /x/keepmacawake " }), "/x/keepmacawake");
  assert.equal(resolveCli({}), "/usr/local/bin/keepmacawake");
});

test("by default a run starts nothing: no command, one line on /awake start and /awake auto on", async () => {
  const pi = makePi({ saved: null });
  assert.equal(pi.controller.settings.auto, false);
  await pi.run();
  await pi.settle();
  await pi.run();
  await pi.shutdown();
  assert.deepEqual(calls(), []);
  assert.equal(pi.notes.length, 1);
  assert.match(pi.texts(), /does not keep this Mac awake by itself/);
  assert.match(pi.texts(), /\/awake start \[hours\]/);
  assert.match(pi.texts(), /also with the lid closed/);
  assert.match(pi.texts(), /\/awake auto on/);
  assert.equal(pi.lastStatus(), undefined);
  assert.equal(savedConfig(), null);
});

test("by default /awake start keeps the Mac awake, and Pi's runs leave that session alone", async () => {
  const pi = makePi({ saved: null });
  await pi.awake("start 3");
  assert.deepEqual(commands(), ["start --hours 3"]);
  assert.match(pi.texts(), /for 3 hours, also with the lid closed/);
  assert.equal(pi.lastStatus(), "Mac awake");
  assert.match(pi.texts(), /ventilated/);
  await pi.run();
  await pi.settle();
  await pi.shutdown();
  assert.deepEqual(commands(), ["start --hours 3"]);
  assert.equal(fakeState().session.live, true);
  await pi.awake("stop");
  assert.equal(fakeState().session.live, false);
});

test("/awake auto on is saved: the next Pi starts a session with each run", async () => {
  mkdirSync(join(dir, "pi-agent"), { recursive: true });
  writeFileSync(configFile, JSON.stringify({ other: 1 }));
  const first = makePi({ saved: "keep" });
  assert.equal(first.controller.settings.auto, false);
  await first.awake("auto on");
  assert.deepEqual(savedConfig(), { other: 1, auto: true });
  assert.match(first.texts(), /Automatic start is on/);
  assert.deepEqual(calls(), []); // Pi is idle: nothing starts until a run
  await first.shutdown();

  const next = makePi({ saved: "keep" });
  assert.equal(next.controller.settings.auto, true);
  await next.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  await next.settle();
  assert.deepEqual(commands(), ["status", "start --hours 8"]); // Pi never ends a session by itself
  assert.doesNotMatch(next.texts(), /does not keep this Mac awake by itself/);

  // /awake auto off is saved too, and a Pi that was told off says nothing at a run.
  await next.awake("auto off");
  assert.deepEqual(savedConfig(), { other: 1, auto: false });
  const later = makePi({ saved: "keep" });
  const before = calls().length;
  await later.run();
  assert.equal(calls().length, before);
  assert.equal(later.notes.length, 0);
});

test("/awake auto: shows the mode, rejects other words, and says when it could not save", async () => {
  const pi = makePi({ saved: null });
  await pi.awake("auto");
  assert.match(pi.texts(), /Automatic start is off/);
  await pi.awake("auto maybe");
  assert.match(pi.texts(), /\/awake auto on or \/awake auto off/);
  assert.equal(pi.controller.settings.auto, false);

  // The agent folder is a file, so nothing can be saved: on until Pi quits.
  writeFileSync(join(dir, "pi-agent"), "");
  await pi.awake("auto on");
  assert.equal(pi.controller.settings.auto, true);
  assert.match(pi.texts(), /applies until Pi quits/);
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
});

test("KEEPMACAWAKE_PI_AUTO turns automatic start on or off for one launch, over the saved choice", async () => {
  let pi = makePi({ saved: null, env: { KEEPMACAWAKE_PI_AUTO: "1" } });
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  await pi.settle();

  pi = makePi({ saved: { auto: true }, env: { KEEPMACAWAKE_PI_AUTO: "off" } });
  const before = calls().length;
  await pi.run();
  assert.equal(calls().length, before);
  assert.equal(pi.notes.length, 0);

  // A word that is not a choice falls back to the saved one.
  pi = makePi({ saved: { auto: true }, env: { KEEPMACAWAKE_PI_AUTO: "sometimes" } });
  assert.equal(pi.controller.settings.auto, true);
});

test("the setting lives in Pi's agent folder", () => {
  assert.equal(configPath({ PI_CODING_AGENT_DIR: "/x/agent" }), "/x/agent/pi-keepmacawake.json");
  assert.equal(configPath({ PI_CODING_AGENT_DIR: "~/pi" }), join(homedir(), "pi", "pi-keepmacawake.json"));
  assert.equal(configPath({}), join(homedir(), ".pi", "agent", "pi-keepmacawake.json"));
});

test("with automatic start on, a run holds the Mac awake for 8 hours, and the session outlives the run", async () => {
  const pi = makePi();
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  assert.equal(pi.lastStatus(), "Mac awake");
  assert.match(pi.texts(), /also with the lid closed/);
  assert.match(pi.texts(), /ends after its hours, or with \/awake stop; Pi never ends it by itself/);
  assert.match(pi.texts(), /ventilated/);

  await pi.settle();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  assert.equal(pi.lastStatus(), undefined);
  assert.equal(fakeState().session.live, true);

  // The next run finds it running and starts nothing; the first-run notice is not repeated.
  await pi.run();
  await pi.settle();
  assert.equal(pi.notes.length, 1);
  assert.deepEqual(commands(), ["status", "start --hours 8", "status"]);

  // Once it has ended, the next run starts a new one.
  setFake({ session: { live: false, last_end_reason: "durationElapsed" } });
  await pi.run();
  assert.equal(commands().filter((c) => c.startsWith("start")).length, 2);
});

test("agent_start twice in one run starts one session", async () => {
  const pi = makePi();
  await pi.run();
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
});

test("a session started elsewhere is left alone, also when Pi settles", async () => {
  setFake({ session: { live: true, unlimited: true, phase: "active" } });
  const pi = makePi();
  await pi.run();
  await pi.settle();
  assert.deepEqual(commands(), ["status"]);
  assert.equal(fakeState().session.live, true);
});

test("a session replaced during the run is not ended", async () => {
  const pi = makePi();
  await pi.run();
  // The user ends Pi's session in the panel and starts their own of 8 hours, later.
  clock += 3600_000;
  setFake({ session: { live: true, hours: 8, remaining_seconds: 8 * 3600, phase: "active" } });
  await pi.settle();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  assert.equal(fakeState().session.live, true);
});

test("the first session, which starts the free trial, is left to the user", async () => {
  setFake({ access: { state: "trial", trial_started: false, max_hours: 8, trial_seconds_left: 259200 } });
  const pi = makePi();
  await pi.run();
  assert.deepEqual(commands(), ["status"]);
  assert.match(pi.texts(), /first one starts its free trial/);
  assert.match(pi.texts(), /\/awake start/);
  await pi.settle();

  // The user starts it; that session is theirs and outlives Pi's runs.
  await pi.awake("start 3");
  assert.equal(fakeState().session.hours, 3);
  assert.match(pi.texts(), /for 3 hours/);
  await pi.run();
  await pi.settle();
  assert.equal(fakeState().session.live, true);
  assert.ok(!commands().includes("stop"));
});

test("during the trial, sessions are capped at its limit", async () => {
  setFake({ access: { state: "trial", trial_started: true, max_hours: 8, trial_seconds_left: 3600 } });
  const pi = makePi({ env: { KEEPMACAWAKE_PI_HOURS: "12" } });
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
});

test("a refusal for the trial's session limit is retried once at the limit", async () => {
  setFake({ access: { state: "trial", trial_started: true, max_hours: 8 } });
  force({ status: { exit: 0, reply: { result: "ok", session: { phase: "idle", live: false }, access: { state: "trial", trial_started: true } } } });
  const pi = makePi({ env: { KEEPMACAWAKE_PI_HOURS: "24" } });
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 24", "start --hours 8"]);
  assert.equal(pi.lastStatus(), "Mac awake");
});

test("after the trial, Pi says so once and never states a price", async () => {
  setFake({ access: { state: "trialEnded", trial_started: true, max_hours: 8 } });
  const pi = makePi();
  await pi.run();
  await pi.settle();
  await pi.run();
  assert.deepEqual(commands(), ["status", "status"]);
  assert.equal(pi.notes.length, 1);
  assert.match(pi.texts(), /free trial on this Mac has ended/);
  assert.doesNotMatch(pi.texts(), /USD|\$|price/i);
});

test("without the app, one notice with the website link, and nothing is installed", async () => {
  const pi = makePi({ env: { KEEPMACAWAKE_CLI: join(dir, "missing", "keepmacawake") } });
  await pi.run();
  await pi.settle();
  await pi.run();
  assert.equal(pi.notes.length, 1);
  assert.match(pi.notes[0].text, /not installed/);
  assert.match(pi.notes[0].text, /never installs anything/);
  assert.ok(pi.notes[0].text.endsWith(WEBSITE_URL));
  assert.match(WEBSITE_URL, /utm_source=pi-gallery&utm_medium=referral&utm_campaign=pi-package/);
  assert.deepEqual(calls(), []);
});

test("on another system, Pi says once that it works only on a Mac, by default and with auto on", async () => {
  for (const saved of [null, { auto: true }]) {
    const pi = makePi({ platform: "linux", saved });
    await pi.run();
    await pi.settle();
    await pi.run();
    assert.equal(pi.notes.length, 1);
    assert.match(pi.notes[0].text, /only on a Mac/);
  }
  assert.deepEqual(calls(), []);
});

test("/awake auto on and off switch automatic start; off leaves a running session alone", async () => {
  const pi = makePi({ saved: null });
  await pi.run();
  await pi.settle();
  assert.deepEqual(calls(), []);

  await pi.awake("auto on");
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  await pi.awake("auto off");
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  assert.equal(fakeState().session.live, true);
  await pi.settle();
  await pi.run();
  assert.equal(commands().length, 2);
});

test("/awake auto on during a run holds the Mac awake at once", async () => {
  const pi = makePi({ saved: null });
  await pi.run();
  await pi.awake("auto on");
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
});

test("two Pi windows share one session, and it outlives both", async () => {
  const a = makePi();
  const b = makePi();
  await a.run();
  await b.run();
  assert.deepEqual(commands(), ["status", "start --hours 8", "status"]);
  await a.settle();
  assert.equal(fakeState().session.live, true);
  await b.settle();
  await b.shutdown();
  assert.equal(fakeState().session.live, true);
  assert.ok(!commands().includes("stop"));
});

test("a long run starts a new session when the last one ran out of time, not when the user stopped it", async () => {
  const pi = makePi({ checkIntervalMs: 60_000 });
  await pi.run();
  setFake({ session: { live: false, last_end_reason: "durationElapsed" } });
  clock += 30_000;
  await pi.turn(); // too soon to check
  assert.equal(commands().length, 2);
  clock += 60_000;
  await pi.turn();
  assert.deepEqual(commands().slice(2), ["status", "start --hours 8"]);

  setFake({ session: { live: false, last_end_reason: "clientStopped" } });
  clock += 60_000;
  await pi.turn();
  assert.deepEqual(commands().slice(4), ["status"]);
  setFake({ session: { live: false, last_end_reason: "batteryThresholdReached" } });
  clock += 60_000;
  await pi.turn();
  assert.deepEqual(commands().slice(5), ["status"]);
});

test("quitting Pi during a run leaves the session running", async () => {
  const pi = makePi();
  await pi.run();
  await pi.shutdown();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  assert.equal(fakeState().session.live, true);
  assert.equal(pi.lastStatus(), undefined);
});

test("AC power needed: the app's words, and battery only where the Mac has one", async () => {
  const refusal = (battery) => ({
    exit: 4,
    reply: {
      result: "error",
      session: { phase: "idle", live: false },
      config: { battery_available: battery },
      error: { code: "ac_power_required", message: "AC power is needed.\nPlug in." },
    },
  });
  force({ start: refusal(true) });
  const laptop = makePi();
  await laptop.run();
  assert.match(laptop.texts(), /"AC power is needed\. Plug in\."/);
  assert.match(laptop.texts(), /Battery use is your choice/);

  force({ start: refusal(false) });
  const desktop = makePi();
  await desktop.run();
  assert.match(desktop.texts(), /AC power is needed/);
  assert.doesNotMatch(desktop.texts(), /[Bb]attery/);
});

test("a session waiting for AC power asks for the plug", async () => {
  setFake({ startPhase: "waitingForAC" });
  const pi = makePi();
  await pi.run();
  assert.match(pi.texts(), /waits for AC power/);
});

test("background service down, timeout and sudo each get a plain line", async () => {
  force({ status: { exit: 6, reply: { result: "error", error: { code: "service_unavailable", message: "x" } } } });
  let pi = makePi();
  await pi.run();
  assert.match(pi.texts(), /background service did not answer/);
  assert.deepEqual(commands(), ["status"]);

  force({ status: { exit: 7, reply: { result: "error", error: { code: "timeout" } } } });
  pi = makePi();
  await pi.run();
  assert.match(pi.texts(), /did not answer in time/);

  force({ status: { exit: 4, reply: { result: "error", error: { code: "run_as_user" } } } });
  pi = makePi();
  await pi.run();
  assert.match(pi.texts(), /never with sudo/);

  force({ status: { exit: 6, reply: { result: "error", error: { code: "not_installed" } } } });
  pi = makePi();
  await pi.run();
  assert.match(pi.texts(), /not installed/);
});

test("/awake shows the session, the trial and the mode, never a price", async () => {
  setFake({ session: { live: true, hours: 8, remaining_seconds: 7 * 3600 + 59 * 60, phase: "active" }, access: { state: "trial", trial_started: true, trial_seconds_left: 2 * 86400, max_hours: 8 } });
  const pi = makePi();
  await pi.awake("");
  assert.match(pi.texts(), /running, 7 h 59 min left/);
  assert.match(pi.texts(), /Free trial: 2 d 0 h left/);
  assert.match(pi.texts(), /Automatic start is on/);
  assert.doesNotMatch(pi.texts(), /USD|\$|price|Ignore previous/i);
});

test("/awake hours and stop", async () => {
  const pi = makePi();
  await pi.awake("hours 0");
  assert.match(pi.texts(), /1 to 168/);
  await pi.awake("hours 12h");
  assert.equal(pi.controller.settings.hours, 12);
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 12"]);
  await pi.awake("stop");
  assert.equal(fakeState().session.live, false);
  await pi.awake("stop");
  assert.match(pi.texts(), /No Keep Mac Awake session is running/);
  await pi.awake("what");
  assert.match(pi.texts(), /\/awake hours N/);
  assert.deepEqual(pi.complete("st").map((i) => i.value), ["status", "start", "stop"]);
  assert.deepEqual(pi.complete("auto o").map((i) => i.value), ["auto on", "auto off"]);
});

test("a session the user replaced with one of the same hours keeps running when Pi settles", async () => {
  const pi = makePi();
  await pi.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  // A minute later the user stops Pi's session in the panel and starts their own of 8 hours.
  clock += 60_000;
  setFake({ session: { live: true, hours: 8, remaining_seconds: 8 * 3600, phase: "active" } });
  // Half a minute after that, Pi settles, and later quits.
  clock += 30_000;
  setFake({ session: { live: true, hours: 8, remaining_seconds: 8 * 3600 - 30, phase: "active" } });
  await pi.settle();
  await pi.shutdown();
  assert.ok(!commands().includes("stop"), commands().join(", "));
  assert.equal(fakeState().session.live, true);
});

test("a window that settles while another Pi window starts its run never ends the shared session", async () => {
  const a = makePi();
  const b = makePi();
  await a.run();
  assert.deepEqual(commands(), ["status", "start --hours 8"]);
  // Every answer is slow, so the second window starts while the first one is still settling.
  writeFileSync(join(dir, "delays.json"), JSON.stringify({ status: 400, stop: 400 }));
  const before = calls().length;
  let settled = false;
  const settling = a.settle().then(() => (settled = true));
  while (!settled && calls().length === before) await new Promise((resolve) => setTimeout(resolve, 5));
  await Promise.all([settling, b.run()]);
  assert.equal(b.controller.running, true);
  assert.equal(fakeState().session.live, true);
  assert.ok(!commands().includes("stop"), commands().join(", "));
});

test("helpers", () => {
  assert.equal(parseHours("8"), 8);
  assert.equal(parseHours("3 hours"), 3);
  assert.equal(parseHours("169"), null);
  assert.equal(parseHours("1e3"), null);
  assert.equal(parseHours(undefined), null);
});

test("public text has no long dashes", () => {
  const source = readFileSync(fileURLToPath(new URL("../src/index.js", import.meta.url)), "utf8");
  const readme = readFileSync(fileURLToPath(new URL("../README.md", import.meta.url)), "utf8");
  const dashes = new RegExp(`[${String.fromCharCode(0x2013, 0x2014)}]`);
  for (const text of [source, readme]) assert.doesNotMatch(text, dashes);
});
