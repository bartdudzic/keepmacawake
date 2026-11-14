"""The IPython and Jupyter magic: %keepmacawake 8h, %keepmacawake off, %keepmacawake."""

from __future__ import annotations

import re
from typing import Any, Optional

from ._cli import DEFAULT_HOURS, MAX_HOURS, AlreadyRunningError, _start, battery_note, format_duration, status, stop

USAGE = (
    "%keepmacawake 8h: keep this Mac awake for 8 hours (1 to 168; during the free trial at most 8), "
    "also with the lid closed. %keepmacawake off: end the session, whoever started it. "
    "%keepmacawake: show the state."
)

_HOURS = re.compile(r"^(\d{1,3})\s*(h|hr|hrs|hour|hours)?$", re.IGNORECASE)


def parse(line: str) -> "tuple[str, Optional[int]]":
    """("status", None), ("start", hours), ("stop", None) or ("help", None)."""
    text = (line or "").strip().lower()
    if text in ("", "status"):
        return "status", None
    if text in ("off", "stop"):
        return "stop", None
    if text in ("on", "start"):
        return "start", DEFAULT_HOURS
    if text in ("help", "-h", "--help", "?"):
        return "help", None
    match = _HOURS.match(re.sub(r"^start\s+", "", text))
    if match and 1 <= int(match.group(1)) <= MAX_HOURS:
        return "start", int(match.group(1))
    raise ValueError(f"Keep Mac Awake: cannot read {line.strip()!r}. {USAGE}")


def keepmacawake_magic(line: str = "", cli: Optional[str] = None) -> None:
    """Runs one %keepmacawake line. Errors are raised, so a notebook run stops
    before a long job if the Mac cannot be kept awake."""
    action, hours = parse(line)
    if action == "help":
        print(USAGE)
    elif action == "status":
        print(status(cli=cli))
    elif action == "stop":
        result = stop(cli=cli)
        print("No Keep Mac Awake session is running; normal sleep applies." if not result.running else result)
    else:
        try:
            result = _start(hours, cli, None)
        except AlreadyRunningError as error:
            running = error.status
            if running is not None and running.unlimited:
                left = " without a time limit"
            elif running is not None and running.remaining_seconds is not None:
                left = f", {format_duration(running.remaining_seconds)} left"
            else:
                left = ""
            print(f"A Keep Mac Awake session is already running{left}, so no new one started. "
                  "%keepmacawake off ends it.")
            return
        print(f"Keep Mac Awake keeps this Mac awake for {hours} hours, also with the lid closed. "
              "The session ends after its hours or with %keepmacawake off. "
              "Keep a closed Mac ventilated, never in a bag or on a soft surface.")
        if result.waiting_for_ac:
            print("It waits for AC power: plug in this Mac.")
        note = battery_note(result)
        if note:
            print(note)


def load_ipython_extension(ipython: Any) -> None:
    """%load_ext keepmacawake registers the %keepmacawake line magic."""

    def keepmacawake(line: str = "") -> None:
        keepmacawake_magic(line)

    keepmacawake.__doc__ = USAGE
    ipython.register_magic_function(keepmacawake, magic_kind="line", magic_name="keepmacawake")
