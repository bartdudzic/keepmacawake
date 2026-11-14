"""keepmacawake.session(): keep the Mac awake while a block of code runs."""

from __future__ import annotations

import time
import warnings
from contextlib import ContextDecorator
from typing import Any, Optional

from ._cli import (
    DEFAULT_HOURS,
    AlreadyRunningError,
    KeepMacAwakeError,
    KeepMacAwakeWarning,
    Status,
    _hours,
    _start,
    _warn_about_power,
    status,
    stop,
)

# How far the running session's end may drift from the end this block expects
# and still count as the session this block started.
END_TOLERANCE_SECONDS = 120


class Session(ContextDecorator):
    """Starts a timed Keep Mac Awake session when the block starts.

    A session that is already running is used as it is. By default the
    session keeps running after the block, until its hours are up: the
    keepmacawake command does not tell one session from another (no session
    id), so the block cannot prove that the running session is still the one
    it started, and another tool may rely on it. With ``stop_on_exit=True``
    the block ends the session when it finishes, but only when this block
    started it and the running session still has the same hours and end time.

    After ``with``, ``started`` says whether this block started the session
    and ``status`` holds the state read at the start.
    """

    def __init__(self, hours: int = DEFAULT_HOURS, *, stop_on_exit: bool = False,
                 cli: Optional[str] = None, timeout: Optional[float] = None) -> None:
        self.hours = _hours(hours)
        self.stop_on_exit = bool(stop_on_exit)
        self.cli = cli
        self.timeout = timeout
        self.started = False
        self.status: Optional[Status] = None
        self._expected_end: Optional[float] = None

    def _recreate_cm(self) -> "Session":
        # As a decorator, each call (also a recursive or concurrent one) gets its own context,
        # so one call never overwrites another call's record of the session it started.
        return Session(self.hours, stop_on_exit=self.stop_on_exit, cli=self.cli, timeout=self.timeout)

    def __enter__(self) -> "Session":
        self.started = False
        self._expected_end = None
        try:
            current = _start(self.hours, self.cli, self.timeout)
        except AlreadyRunningError as error:
            # Someone else's session (or an earlier one): use it, never end it.
            self.status = error.status or status(cli=self.cli, timeout=self.timeout)
            return self
        self.started = True
        self.status = current
        remaining = current.remaining_seconds if current.remaining_seconds is not None else self.hours * 3600
        self._expected_end = time.time() + remaining
        _warn_about_power(current, stacklevel=3)
        return self

    def _still_ours(self, current: Status) -> bool:
        return (
            current.running
            and not current.unlimited
            and current.hours == self.hours
            and current.remaining_seconds is not None
            and self._expected_end is not None
            and abs(time.time() + current.remaining_seconds - self._expected_end) <= END_TOLERANCE_SECONDS
        )

    def __exit__(self, *exc: Any) -> bool:
        if not (self.started and self.stop_on_exit):
            return False
        # Never let a problem here hide an exception from the block.
        try:
            current = status(cli=self.cli, timeout=self.timeout)
            if not current.running:
                return False
            if not self._still_ours(current):
                warnings.warn(
                    "The Keep Mac Awake session was left running: it is not the one this block started "
                    "(its hours or end time changed). It ends after its hours, or with keepmacawake.stop().",
                    KeepMacAwakeWarning, stacklevel=2)
                return False
            stop(cli=self.cli, timeout=self.timeout)
        except KeepMacAwakeError as error:
            warnings.warn(f"Keep Mac Awake: could not end the session: {error}", KeepMacAwakeWarning, stacklevel=2)
        return False


def session(hours: int = DEFAULT_HOURS, *, stop_on_exit: bool = False,
            cli: Optional[str] = None, timeout: Optional[float] = None) -> Session:
    """Keeps this Mac awake, also with the lid closed, while the block runs.

        with keepmacawake.session(hours=8):
            train()

    Starts a session of ``hours`` (1 to 168, default 8; during the free trial
    at most 8) unless one is already running. The session ends after its
    hours; ``stop_on_exit=True`` ends it when the block finishes, only if this
    block started it. A KeepMacAwakeWarning says when the session waits for AC
    power or may run on battery because Run on battery turned itself on (code
    that an AI agent writes or runs checks ``status().battery_needs_consent``
    first and asks the user). Also works as a decorator: ``@keepmacawake.session(hours=8)``.
    """
    return Session(hours, stop_on_exit=stop_on_exit, cli=cli, timeout=timeout)
