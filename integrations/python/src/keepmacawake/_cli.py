"""Runs the keepmacawake command of the Keep Mac Awake app and reads its answer.

The package runs only that command, with ``status``, ``start --hours N`` and
``stop``, each with ``--json --no-input``. It makes no network connection,
reads no files, changes no settings and never starts a session without a
time limit.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import warnings
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence

DEFAULT_CLI_PATH = "/usr/local/bin/keepmacawake"
WEBSITE_URL = "https://keepmacawake.com/?utm_source=pypi&utm_medium=referral&utm_campaign=integrations"
DEFAULT_HOURS = 8
MAX_HOURS = 168
# The command waits up to 15 seconds for its background service; allow a little more.
DEFAULT_TIMEOUT = 30.0
RUNNING_PHASES = ("starting", "active", "waitingForAC")

_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")


class KeepMacAwakeWarning(UserWarning):
    """Something about the session that does not stop the code, for example a session that waits
    for AC power or may run on battery."""


class KeepMacAwakeError(RuntimeError):
    """A keepmacawake command did not do what was asked.

    ``exit_code`` is the command's exit code (None when it did not run),
    ``code`` the ``error.code`` of its JSON answer, and ``reply`` the whole
    answer as a dict (or None).
    """

    def __init__(
        self,
        message: str,
        *,
        exit_code: Optional[int] = None,
        code: Optional[str] = None,
        reply: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code
        self.code = code
        self.reply = reply


class NotSupportedError(KeepMacAwakeError):
    """This computer is not a Mac."""


class NotInstalledError(KeepMacAwakeError):
    """The Keep Mac Awake app (and its keepmacawake command) is not installed."""


class PurchaseRequiredError(KeepMacAwakeError):
    """The free trial does not allow this session, or it has ended.

    The message is the app's own. ``reason`` is ``trial_session_limit`` (during
    the free trial a session lasts at most ``max_hours``) or ``trial_ended``;
    ``next_steps`` lists the commands the app suggests.
    """

    def __init__(self, message: str, *, reason: Optional[str], max_hours: Optional[int],
                 next_steps: List[Dict[str, str]], **kwargs: Any) -> None:
        super().__init__(message, **kwargs)
        self.reason = reason
        self.max_hours = max_hours
        self.next_steps = next_steps


class ActionRequiredError(KeepMacAwakeError):
    """The app needs the person at the Mac first, for example AC power."""


class AlreadyRunningError(KeepMacAwakeError):
    """A session is already running, so ``start`` changed nothing. ``status`` is that session."""

    def __init__(self, message: str, *, status: Optional["Status"], **kwargs: Any) -> None:
        super().__init__(message, **kwargs)
        self.status = status


class ServiceUnavailableError(KeepMacAwakeError):
    """The app's background service did not answer."""


class NoAnswerError(KeepMacAwakeError):
    """No answer in time. After start or stop, the request may still have completed: check status()."""


def _whole(value: Any) -> Optional[int]:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _flag(value: Any) -> Optional[bool]:
    return value if isinstance(value, bool) else None


def _text(value: Any) -> Optional[str]:
    return value if isinstance(value, str) else None


def format_duration(seconds: int) -> str:
    """Seconds as "2 d 5 h", "3 h 10 min" or "40 min"."""
    minutes = max(0, round(seconds / 60))
    days, rest = divmod(minutes, 1440)
    hours, minutes = divmod(rest, 60)
    if days:
        return f"{days} d {hours} h"
    if hours:
        return f"{hours} h {minutes} min"
    return f"{minutes} min"


@dataclass(frozen=True)
class Status:
    """The state of Keep Mac Awake, read from the command's JSON answer."""

    running: bool
    """A session is running (also while it waits for AC power)."""
    phase: Optional[str]
    """``idle``, ``starting``, ``active``, ``waitingForAC``, ``stopping``, ``unavailable``, ``failed`` and others."""
    hours: Optional[int]
    unlimited: bool
    remaining_seconds: Optional[int]
    last_end_reason: Optional[str]
    access: Optional[str]
    """``purchased``, ``trial`` or ``trialEnded``."""
    trial_started: Optional[bool]
    trial_seconds_left: Optional[int]
    max_hours: Optional[int]
    """The longest session a start may ask for; None without a limit."""
    app_version: Optional[str]
    battery_available: Optional[bool] = None
    """False on a Mac without a built-in battery: sessions there need AC power."""
    battery_allowed: Optional[bool] = None
    """Run on battery is on for the next session (``config.battery`` is ``allowed``)."""
    battery_chosen: Optional[bool] = None
    """True when the user set Run on battery themselves, on or off; False while it is unset or was
    turned on by the battery default (Keep Mac Awake 1.0.11 or later); None from an older app."""
    min_battery_percent: Optional[int] = None
    """The battery threshold for the next session."""
    raw: Dict[str, Any] = field(default_factory=dict, repr=False, compare=False)

    @property
    def waiting_for_ac(self) -> bool:
        return self.running and self.phase == "waitingForAC"

    @property
    def battery_needs_consent(self) -> bool:
        """Run on battery turned itself on and the user has not set it, so a session may run on
        battery: code that an AI agent writes or runs asks the user before starting one."""
        return self.battery_available is True and self.battery_allowed is True and self.battery_chosen is False

    @classmethod
    def from_reply(cls, reply: Dict[str, Any]) -> "Status":
        session = reply.get("session") if isinstance(reply.get("session"), dict) else {}
        access = reply.get("access") if isinstance(reply.get("access"), dict) else {}
        phase = _text(session.get("phase"))
        config = reply.get("config") if isinstance(reply.get("config"), dict) else {}
        trial_started = access.get("trial_started")
        battery = config.get("battery")
        return cls(
            running=session.get("live") is True and phase in RUNNING_PHASES,
            phase=phase,
            hours=_whole(session.get("hours")),
            unlimited=session.get("unlimited") is True,
            remaining_seconds=_whole(session.get("remaining_seconds")),
            last_end_reason=_text(session.get("last_end_reason")),
            access=_text(access.get("state")),
            trial_started=trial_started if isinstance(trial_started, bool) else None,
            trial_seconds_left=_whole(access.get("trial_seconds_left")),
            max_hours=_whole(access.get("max_hours")) or None,
            app_version=_text(reply.get("app_version")),
            battery_available=_flag(config.get("battery_available")),
            battery_allowed=True if battery == "allowed" else False if battery == "ac-only" else None,
            battery_chosen=_flag(config.get("battery_chosen")),
            min_battery_percent=_whole(config.get("min_battery_percent")),
            raw=reply,
        )

    def __str__(self) -> str:
        if self.phase in ("failed", "unavailable"):
            text = "Keep Mac Awake reports a problem; open its menu bar panel."
        elif not self.running:
            text = "No Keep Mac Awake session is running; normal sleep applies."
        elif self.waiting_for_ac:
            text = "A Keep Mac Awake session is waiting for AC power."
        elif self.unlimited:
            text = "A Keep Mac Awake session is running without a time limit."
        elif self.remaining_seconds is not None:
            text = f"A Keep Mac Awake session is running, {format_duration(self.remaining_seconds)} left."
        else:
            text = "A Keep Mac Awake session is running."
        if not self.running and self.battery_needs_consent:
            floor = self.min_battery_percent if self.min_battery_percent is not None else 20
            text += (f" Run on battery turned itself on and was not set by the user: unplugged, a session "
                     f"would run on battery down to {floor}%.")
        if self.access == "trialEnded":
            text += " The free trial on this Mac has ended."
        elif self.access == "trial":
            if self.trial_started and self.trial_seconds_left is not None:
                text += f" Free trial: {format_duration(self.trial_seconds_left)} left."
            elif self.trial_started is False:
                text += " The free trial starts with the first session."
        return text


def _is_mac() -> bool:
    return sys.platform == "darwin"


def resolve_cli(cli: Optional[str] = None) -> Optional[str]:
    """The keepmacawake command to run: ``cli`` when given, else KEEPMACAWAKE_CLI
    when set (also when empty: then there is none), else /usr/local/bin/keepmacawake.
    PATH is never searched: a bare name without a slash is refused when it runs."""
    if cli is not None:
        return str(cli).strip() or None
    if "KEEPMACAWAKE_CLI" in os.environ:
        return os.environ["KEEPMACAWAKE_CLI"].strip() or None
    return DEFAULT_CLI_PATH


def _not_installed(path: Optional[str], detail: str = "") -> NotInstalledError:
    where = f"the keepmacawake command was not found at {path}" if path else "no keepmacawake command was given"
    return NotInstalledError(
        f"Keep Mac Awake is not installed: {where}{detail}. The keepmacawake Python package only runs that command, "
        "which the Keep Mac Awake app installs (any Mac with Apple silicon and macOS 26 or later, free trial); "
        f"it never installs anything itself. Get the app at {WEBSITE_URL}"
    )


def _parse_reply(stdout: str) -> Optional[Dict[str, Any]]:
    lines = [line for line in (stdout or "").strip().splitlines() if line.strip()]
    if not lines:
        return None
    try:
        reply = json.loads(lines[-1])
    except ValueError:
        return None
    return reply if isinstance(reply, dict) else None


def _app_message(reply: Optional[Dict[str, Any]], key: str = "message") -> Optional[str]:
    error = (reply or {}).get("error")
    message = error.get(key) if isinstance(error, dict) else None
    if not isinstance(message, str):
        return None
    line = _CONTROL.sub(" ", message).strip()
    return line[:600] or None


def _error_field(reply: Optional[Dict[str, Any]], key: str) -> Any:
    error = (reply or {}).get("error")
    return error.get(key) if isinstance(error, dict) else None


def _run(args: Sequence[str], cli: Optional[str], timeout: Optional[float]) -> "tuple[int, Optional[Dict[str, Any]]]":
    if not _is_mac():
        raise NotSupportedError(
            "Keep Mac Awake works only on a Mac with Apple silicon and macOS 26 or later, "
            f"so the keepmacawake package does nothing on this computer ({sys.platform})."
        )
    path = resolve_cli(cli)
    if not path:
        raise _not_installed(None)
    if "/" not in path:
        # A bare name would make subprocess search PATH, which the package never does.
        raise NotInstalledError(
            f"{path!r} is not a path to the keepmacawake command: give its full path, for example "
            f"{DEFAULT_CLI_PATH}, in cli= or KEEPMACAWAKE_CLI. The package never searches PATH."
        )
    try:
        done = subprocess.run(
            [path, *args, "--json", "--no-input"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT if timeout is None else timeout,
            check=False,
        )
    except (FileNotFoundError, NotADirectoryError, PermissionError):
        raise _not_installed(path) from None
    except subprocess.TimeoutExpired:
        raise NoAnswerError(
            f"Keep Mac Awake did not answer `keepmacawake {args[0]}` in time. "
            "After a start or a stop the request may still have completed: check keepmacawake.status().",
            exit_code=7,
        ) from None
    return done.returncode, _parse_reply(done.stdout)


def _raise_for(exit_code: int, reply: Optional[Dict[str, Any]], command: str, path: Optional[str]) -> None:
    code = _error_field(reply, "code")
    code = code if isinstance(code, str) else None
    said = _app_message(reply)
    extra = {"exit_code": exit_code, "code": code, "reply": reply}
    if exit_code == 4 and code == "purchase_required":
        steps = _error_field(reply, "next_steps")
        access = (reply or {}).get("access")
        raise PurchaseRequiredError(
            _app_message(reply, "user_message") or said or "Keep Mac Awake needs a purchase for this session.",
            reason=_error_field(reply, "reason") if isinstance(_error_field(reply, "reason"), str) else None,
            max_hours=_whole(access.get("max_hours")) if isinstance(access, dict) else None,
            next_steps=[s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else [],
            **extra,
        )
    if exit_code == 4:
        if code == "run_as_user":
            raise ActionRequiredError(
                "The keepmacawake command must run as the logged-in user, never with sudo." + (f" ({said})" if said else ""),
                **extra,
            )
        raise ActionRequiredError(
            f"Keep Mac Awake needs you before it can keep this Mac awake: {said or 'see its menu bar panel.'}", **extra
        )
    if exit_code == 5:
        status = Status.from_reply(reply) if reply else None
        raise AlreadyRunningError(
            "A Keep Mac Awake session is already running." + (f" {status}" if status else ""), status=status, **extra
        )
    if exit_code == 6 and code == "not_installed":
        err = _not_installed(path, f" or the app is missing ({said})" if said else " or the app is missing")
        err.exit_code, err.code, err.reply = exit_code, code, reply
        raise err
    if exit_code == 6:
        raise ServiceUnavailableError(
            "Keep Mac Awake is installed, but its background service did not answer. Open Keep Mac Awake from "
            "Applications and try again." + (f" ({said})" if said else ""),
            **extra,
        )
    if exit_code == 7:
        raise NoAnswerError(
            f"Keep Mac Awake did not answer `keepmacawake {command}` in time. "
            "After a start or a stop the request may still have completed: check keepmacawake.status()."
            + (f" ({said})" if said else ""),
            **extra,
        )
    raise KeepMacAwakeError(
        f"`keepmacawake {command}` failed with exit code {exit_code}" + (f": {said}" if said else "."), **extra
    )


def _hours(hours: Any) -> int:
    if isinstance(hours, bool) or not isinstance(hours, int) or not 1 <= hours <= MAX_HOURS:
        raise ValueError(f"hours must be a whole number from 1 to {MAX_HOURS}, got {hours!r}")
    return hours


def _answer(args: Sequence[str], cli: Optional[str], timeout: Optional[float], *, ok_codes: Sequence[int] = (0,)) -> Dict[str, Any]:
    """Runs one command and returns its JSON answer, or raises the matching error."""
    exit_code, reply = _run(args, cli, timeout)
    if exit_code in ok_codes and reply is not None:
        return reply
    if exit_code == 0:
        raise KeepMacAwakeError(
            f"`keepmacawake {args[0]}` gave no JSON answer; check keepmacawake.status().", exit_code=exit_code
        )
    _raise_for(exit_code, reply, args[0], resolve_cli(cli))
    raise AssertionError("unreachable")  # pragma: no cover


def status(*, cli: Optional[str] = None, timeout: Optional[float] = None) -> Status:
    """The current state: whether a session runs, its time left and the free trial."""
    return Status.from_reply(_answer(["status"], cli, timeout))


def start(hours: int = DEFAULT_HOURS, *, cli: Optional[str] = None, timeout: Optional[float] = None) -> Status:
    """Starts a session of ``hours`` whole hours (1 to 168) now, also for a closed lid.

    It ends after its hours, with stop() or from the menu bar panel. On a
    MacBook on battery, Keep Mac Awake 1.0.11 or later turns Run on battery on
    at 20% unless the user set it; then the session may run on battery, the
    returned state has ``battery_needs_consent`` set and a KeepMacAwakeWarning
    says so. Code that an AI agent writes or runs checks
    ``status().battery_needs_consent`` first and asks the user. Raises
    AlreadyRunningError when a session already runs, and PurchaseRequiredError
    with the app's message when the free trial does not allow it (during the
    trial a session lasts at most 8 hours).
    """
    result = _start(hours, cli, timeout)
    _warn_about_power(result, stacklevel=3)
    return result


def _start(hours: int, cli: Optional[str], timeout: Optional[float]) -> Status:
    hours = _hours(hours)
    return Status.from_reply(_answer(["start", "--hours", str(hours)], cli, timeout))


def battery_note(state: Status) -> Optional[str]:
    """One line when a session may run on battery without the user's choice, else None."""
    if not state.battery_needs_consent:
        return None
    floor = state.min_battery_percent if state.min_battery_percent is not None else 20
    return (
        f"This Keep Mac Awake session may run on battery down to {floor}%: Run on battery turned itself on "
        "and you have not set it. Set it in the menu bar panel, or run `keepmacawake config set --battery ac-only` "
        "in Terminal to keep sessions on AC power (`--battery allowed` keeps battery use)."
    )


def _warn_about_power(state: Status, stacklevel: int) -> None:
    if state.waiting_for_ac:
        warnings.warn("Keep Mac Awake waits for AC power: plug in this Mac to keep it awake.",
                      KeepMacAwakeWarning, stacklevel=stacklevel)
    note = battery_note(state)
    if note:
        warnings.warn(note, KeepMacAwakeWarning, stacklevel=stacklevel)


def stop(*, cli: Optional[str] = None, timeout: Optional[float] = None) -> Status:
    """Ends the running session, whoever started it; normal sleep returns.

    With no session running it changes nothing and returns the state.
    """
    return Status.from_reply(_answer(["stop"], cli, timeout, ok_codes=(0, 5)))
