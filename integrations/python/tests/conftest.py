"""Every test runs against a fake keepmacawake command and can never reach the real one.

KEEPMACAWAKE_CLI and the package's default path both point to a path that does
not exist, and each test that needs a command passes the fake one explicitly.
"""

import json
import os
import stat
import sys

import pytest

import keepmacawake
from keepmacawake import _cli

HERE = os.path.dirname(os.path.abspath(__file__))
NOWHERE = "/nonexistent/keepmacawake"


@pytest.fixture(autouse=True)
def never_the_real_command(monkeypatch):
    monkeypatch.setenv("KEEPMACAWAKE_CLI", NOWHERE)
    monkeypatch.setattr(_cli, "DEFAULT_CLI_PATH", NOWHERE)
    # The tests also run on Linux in CI; the package itself refuses to run off a Mac.
    monkeypatch.setattr(_cli, "_is_mac", lambda: True)


class FakeCli:
    def __init__(self, directory):
        self.dir = str(directory)
        self.path = os.path.join(self.dir, "keepmacawake")
        with open(self.path, "w") as handle:
            handle.write(f'#!/bin/sh\nexec "{sys.executable}" -I "{os.path.join(HERE, "fake_keepmacawake.py")}" "$@"\n')
        os.chmod(self.path, os.stat(self.path).st_mode | stat.S_IXUSR)
        self.state = {"session": {"live": False}}

    @property
    def state(self):
        with open(os.path.join(self.dir, "state.json")) as handle:
            return json.load(handle)

    @state.setter
    def state(self, value):
        with open(os.path.join(self.dir, "state.json"), "w") as handle:
            json.dump(value, handle)

    def force(self, **replies):
        with open(os.path.join(self.dir, "replies.json"), "w") as handle:
            json.dump(replies, handle)

    def calls(self):
        path = os.path.join(self.dir, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as handle:
            return [json.loads(line) for line in handle]

    def commands(self):
        return [call[0] for call in self.calls()]


@pytest.fixture
def fake(tmp_path, monkeypatch):
    cli = FakeCli(tmp_path)
    monkeypatch.setenv("FAKE_KMA_DIR", str(tmp_path))
    return cli


__all__ = ["keepmacawake"]
