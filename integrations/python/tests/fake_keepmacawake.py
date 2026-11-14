"""A stand-in for the keepmacawake command in tests. It never touches the Mac.

It keeps a pretend session in $FAKE_KMA_DIR/state.json, appends its arguments
to $FAKE_KMA_DIR/calls.jsonl and answers like the real command: one JSON
object on stdout and the documented exit codes. $FAKE_KMA_DIR/replies.json can
force an answer for "status", "start" or "stop": {"exit": N, "reply": {...}},
and {"sleep": seconds} slows one down.
"""

import json
import os
import sys
import time

directory = os.environ.get("FAKE_KMA_DIR")
if not directory:
    sys.stderr.write("FAKE_KMA_DIR is not set.\n")
    sys.exit(1)
args = sys.argv[1:]
with open(os.path.join(directory, "calls.jsonl"), "a") as calls:
    calls.write(json.dumps(args) + "\n")

state_file = os.path.join(directory, "state.json")
with open(state_file) as handle:
    state = json.load(handle)
replies_file = os.path.join(directory, "replies.json")
replies = {}
if os.path.exists(replies_file):
    with open(replies_file) as handle:
        replies = json.load(handle)


def body(result="ok", error=None):
    session = state["session"]
    live = session.get("live", False)
    access = {
        "state": "purchased",
        "mac_id": "0123456789abcdef0123456789abcdef",
        "max_hours": None,
        "purchase": None,
        "trial_started": True,
        "trial_seconds_left": None,
        "trial_ends_at": None,
    }
    access.update(state.get("access", {}))
    config = {
        "battery": "ac-only",
        "battery_available": True,
        "battery_chosen": True,
        "min_battery_percent": 20,
        "mute_on_lid_close": "off",
        "update_check": "daily",
    }
    config.update(state.get("config", {}))
    for key in [key for key, value in config.items() if value is None]:
        del config[key]  # None in the test state: a key an older app does not send
    reply = {
        "result": result,
        "schema_version": 1,
        "protocol_version": "2",
        "app_version": "1.0.11",
        "session": {
            "phase": session.get("phase", "active") if live else "idle",
            "live": live,
            "confirmed": live,
            "hours": session.get("hours") if live else None,
            "unlimited": session.get("unlimited", False) if live else False,
            "remaining_seconds": session.get("remaining_seconds", (session.get("hours") or 0) * 3600)
            if live and not session.get("unlimited")
            else None,
            "min_battery_percent": None,
            "last_end_reason": session.get("last_end_reason"),
            "message": "Sleep prevention is on." if live else "Sleep prevention is off.",
        },
        "config": config,
        "access": access,
        "update": {"current_version": "1.0.11", "available_version": None, "install_command": None},
    }
    if error:
        reply["error"] = error
    return reply


def answer(code, reply):
    sys.stdout.write(json.dumps(reply) + "\n")
    with open(state_file, "w") as handle:
        json.dump(state, handle)
    sys.exit(code)


command = args[0] if args else ""
if "--json" not in args or "--no-input" not in args:
    answer(2, body("error", {"code": "invalid_arguments", "message": "Test: --json and --no-input expected."}))
forced = replies.get(command)
if forced:
    if forced.get("sleep"):
        time.sleep(forced["sleep"])
    if "exit" in forced:
        if forced.get("raw") is not None:
            sys.stdout.write(forced["raw"])
            sys.exit(forced["exit"])
        answer(forced["exit"], forced.get("reply") or body())

if command == "status":
    answer(0, body())
if command == "start":
    if "--hours" not in args:
        answer(2, body("error", {"code": "invalid_arguments", "message": "Test: only --hours is expected."}))
    hours = args[args.index("--hours") + 1]
    hours = int(hours) if hours.isdigit() else 0
    if not 1 <= hours <= 168:
        answer(2, body("error", {"code": "invalid_arguments", "message": "Hours from 1 to 168."}))
    if state["session"].get("live"):
        answer(5, body("error", {"code": "conflict", "message": "A session is already running.", "retryable": False}))
    access = body()["access"]
    if access["state"] == "trialEnded":
        answer(4, body("error", {"code": "purchase_required", "reason": "trial_ended", "message": "Test: trial ended.",
                                 "user_message": "Test: the trial on this Mac has ended.", "next_steps": []}))
    if access["max_hours"] and hours > access["max_hours"]:
        limit = access["max_hours"]
        answer(4, body("error", {
            "code": "purchase_required",
            "reason": "trial_session_limit",
            "message": "Test: purchase required.",
            "user_message": f"During the Keep Mac Awake trial a session lasts at most {limit} hours, so this one cannot start.",
            "next_steps": [{"command": f"keepmacawake start --hours {limit} --json", "does": "Starts the longest session the trial allows."}],
        }))
    state["session"] = {"live": True, "hours": hours, "phase": state.get("start_phase", "active")}
    state.setdefault("access", {})["trial_started"] = True
    answer(0, body())
if command == "stop":
    if not state["session"].get("live"):
        answer(5, body("error", {"code": "conflict", "message": "No session is running.", "retryable": False}))
    state["session"] = {"live": False, "last_end_reason": "clientStopped"}
    answer(0, body())
answer(2, body("error", {"code": "invalid_arguments", "message": "Test: unknown command."}))
