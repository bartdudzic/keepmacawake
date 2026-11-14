"""Keep a Mac awake, also with the lid closed, while Python code runs.

    import keepmacawake

    with keepmacawake.session(hours=8):
        train()

    keepmacawake.status()

In IPython or Jupyter: ``%load_ext keepmacawake``, then ``%keepmacawake 8h``
and ``%keepmacawake off``.

It runs only the ``keepmacawake`` command of the Keep Mac Awake app
(https://keepmacawake.com), which must be installed on this Mac: any Mac with
Apple silicon and macOS 26 or later. No dependencies, no network connection.
"""

from ._cli import (
    DEFAULT_CLI_PATH,
    WEBSITE_URL,
    ActionRequiredError,
    AlreadyRunningError,
    KeepMacAwakeError,
    KeepMacAwakeWarning,
    NoAnswerError,
    NotInstalledError,
    NotSupportedError,
    PurchaseRequiredError,
    ServiceUnavailableError,
    Status,
    start,
    status,
    stop,
)
from ._magic import load_ipython_extension
from ._session import Session, session

__version__ = "1.0.0"

__all__ = [
    "DEFAULT_CLI_PATH",
    "WEBSITE_URL",
    "ActionRequiredError",
    "AlreadyRunningError",
    "KeepMacAwakeError",
    "KeepMacAwakeWarning",
    "NoAnswerError",
    "NotInstalledError",
    "NotSupportedError",
    "PurchaseRequiredError",
    "ServiceUnavailableError",
    "Session",
    "Status",
    "load_ipython_extension",
    "session",
    "start",
    "status",
    "stop",
]
