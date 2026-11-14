import os
import warnings

import pytest

import keepmacawake
from keepmacawake import _cli, _magic
from conftest import NOWHERE

RUNNING = {"live": True, "hours": 8, "phase": "active"}


# Finding the command


def test_tests_can_never_reach_the_real_command():
    assert _cli.resolve_cli() == NOWHERE
    with pytest.raises(keepmacawake.NotInstalledError):
        keepmacawake.status()


def test_explicit_path_wins_over_the_environment(fake, monkeypatch):
    monkeypatch.setenv("KEEPMACAWAKE_CLI", "/nonexistent/other")
    assert _cli.resolve_cli(fake.path) == fake.path
    assert keepmacawake.status(cli=fake.path).running is False


def test_environment_path_is_used(fake, monkeypatch):
    monkeypatch.setenv("KEEPMACAWAKE_CLI", fake.path)
    assert keepmacawake.status().running is False
    assert fake.commands() == ["status"]


def test_empty_environment_path_means_no_command(monkeypatch):
    monkeypatch.setenv("KEEPMACAWAKE_CLI", "")
    assert _cli.resolve_cli() is None
    with pytest.raises(keepmacawake.NotInstalledError, match="no keepmacawake command was given"):
        keepmacawake.status()


def test_default_path_without_environment(monkeypatch):
    monkeypatch.delenv("KEEPMACAWAKE_CLI")
    assert _cli.resolve_cli() == NOWHERE  # the default path, pointed away from the real one by conftest


def test_path_is_never_searched(fake, monkeypatch):
    monkeypatch.setenv("PATH", fake.dir)
    with pytest.raises(keepmacawake.NotInstalledError):
        keepmacawake.status()
    assert fake.calls() == []


def test_bare_name_in_cli_is_refused_not_searched(fake, monkeypatch):
    monkeypatch.setenv("PATH", fake.dir)
    with pytest.raises(keepmacawake.NotInstalledError, match="never searches PATH"):
        keepmacawake.status(cli="keepmacawake")
    assert fake.calls() == []


def test_bare_name_in_environment_is_refused_not_searched(fake, monkeypatch):
    monkeypatch.setenv("PATH", fake.dir)
    monkeypatch.setenv("KEEPMACAWAKE_CLI", "keepmacawake")
    with pytest.raises(keepmacawake.NotInstalledError, match="never searches PATH"):
        keepmacawake.start(hours=1)
    assert fake.calls() == []


# Without the app


def test_missing_command_names_what_is_missing_and_the_site():
    with pytest.raises(keepmacawake.NotInstalledError) as raised:
        keepmacawake.start(8)
    message = str(raised.value)
    assert NOWHERE in message
    assert "Keep Mac Awake app" in message
    assert "https://keepmacawake.com/?utm_source=pypi&utm_medium=referral&utm_campaign=integrations" in message
    assert "never installs anything" in message


def test_command_reports_the_app_missing(fake):
    fake.force(status={"exit": 6, "reply": {"result": "error", "error": {"code": "not_installed", "message": "Test: app missing."}}})
    with pytest.raises(keepmacawake.NotInstalledError) as raised:
        keepmacawake.status(cli=fake.path)
    assert raised.value.exit_code == 6
    assert "Test: app missing." in str(raised.value)
    assert keepmacawake.WEBSITE_URL in str(raised.value)


def test_not_a_mac(fake, monkeypatch):
    monkeypatch.setattr(_cli, "_is_mac", lambda: False)
    with pytest.raises(keepmacawake.NotSupportedError, match="only on a Mac"):
        keepmacawake.status(cli=fake.path)
    assert fake.calls() == []


# status, start, stop


def test_status_reads_the_answer(fake):
    fake.state = {"session": {"live": True, "hours": 8, "remaining_seconds": 7200},
                  "access": {"state": "trial", "trial_seconds_left": 90000, "max_hours": 8}}
    state = keepmacawake.status(cli=fake.path)
    assert state.running and state.hours == 8 and state.remaining_seconds == 7200
    assert state.access == "trial" and state.max_hours == 8 and state.app_version == "1.0.11"
    assert str(state) == "A Keep Mac Awake session is running, 2 h 0 min left. Free trial: 1 d 1 h left."
    assert fake.calls() == [["status", "--json", "--no-input"]]


def test_status_without_a_session(fake):
    state = keepmacawake.status(cli=fake.path)
    assert not state.running
    assert str(state) == "No Keep Mac Awake session is running; normal sleep applies."


def test_start_runs_a_timed_session_only(fake):
    state = keepmacawake.start(3, cli=fake.path)
    assert state.running and state.hours == 3
    assert fake.calls() == [["start", "--hours", "3", "--json", "--no-input"]]


@pytest.mark.parametrize("hours", [0, 169, -1, 2.5, "8", None, True])
def test_start_refuses_bad_hours_before_running_anything(fake, hours):
    with pytest.raises(ValueError):
        keepmacawake.start(hours, cli=fake.path)
    assert fake.calls() == []


def test_start_when_a_session_runs(fake):
    fake.state = {"session": RUNNING}
    with pytest.raises(keepmacawake.AlreadyRunningError) as raised:
        keepmacawake.start(8, cli=fake.path)
    assert raised.value.exit_code == 5 and raised.value.status.running


def test_trial_session_over_eight_hours_surfaces_the_apps_message(fake):
    fake.state = {"session": {"live": False}, "access": {"state": "trial", "max_hours": 8, "trial_seconds_left": 200000}}
    with pytest.raises(keepmacawake.PurchaseRequiredError) as raised:
        keepmacawake.start(12, cli=fake.path)
    error = raised.value
    assert str(error) == "During the Keep Mac Awake trial a session lasts at most 8 hours, so this one cannot start."
    assert error.exit_code == 4 and error.code == "purchase_required"
    assert error.reason == "trial_session_limit" and error.max_hours == 8
    assert error.next_steps[0]["command"] == "keepmacawake start --hours 8 --json"
    assert fake.commands() == ["start"]  # never retried with fewer hours behind the user's back


def test_trial_ended(fake):
    fake.state = {"session": {"live": False}, "access": {"state": "trialEnded"}}
    with pytest.raises(keepmacawake.PurchaseRequiredError, match="trial on this Mac has ended") as raised:
        keepmacawake.start(cli=fake.path)
    assert raised.value.reason == "trial_ended"


def test_action_needed(fake):
    fake.force(start={"exit": 4, "reply": {"result": "error", "error": {"code": "refused", "message": "Connect AC power."}}})
    with pytest.raises(keepmacawake.ActionRequiredError, match="Connect AC power."):
        keepmacawake.start(cli=fake.path)


def test_sudo(fake):
    fake.force(status={"exit": 4, "reply": {"result": "error", "error": {"code": "run_as_user", "message": "Run it as the user."}}})
    with pytest.raises(keepmacawake.ActionRequiredError, match="never with sudo"):
        keepmacawake.status(cli=fake.path)


def test_service_down(fake):
    fake.force(status={"exit": 6, "reply": {"result": "error", "error": {"code": "service_unavailable", "message": "x"}}})
    with pytest.raises(keepmacawake.ServiceUnavailableError, match="background service"):
        keepmacawake.status(cli=fake.path)


def test_no_answer_in_time(fake):
    fake.force(start={"sleep": 3})
    with pytest.raises(keepmacawake.NoAnswerError, match="check keepmacawake.status"):
        keepmacawake.start(cli=fake.path, timeout=0.5)


def test_command_says_no_answer(fake):
    fake.force(stop={"exit": 7, "reply": {"result": "error", "error": {"code": "timed_out", "message": "x"}}})
    with pytest.raises(keepmacawake.NoAnswerError):
        keepmacawake.stop(cli=fake.path)


def test_answer_that_is_not_json(fake):
    fake.force(status={"exit": 0, "raw": "not json\n"})
    with pytest.raises(keepmacawake.KeepMacAwakeError, match="no JSON answer"):
        keepmacawake.status(cli=fake.path)


def test_other_failure_names_the_exit_code(fake):
    fake.force(status={"exit": 1, "reply": {"result": "error", "error": {"code": "failed", "message": "Test failure."}}})
    with pytest.raises(keepmacawake.KeepMacAwakeError, match="exit code 1: Test failure.") as raised:
        keepmacawake.status(cli=fake.path)
    assert type(raised.value) is keepmacawake.KeepMacAwakeError


def test_stop_ends_any_session_and_tolerates_none(fake):
    fake.state = {"session": RUNNING}
    assert keepmacawake.stop(cli=fake.path).running is False
    assert keepmacawake.stop(cli=fake.path).running is False
    assert fake.commands() == ["stop", "stop"]


# session()


def test_session_starts_and_leaves_the_session_running_by_default(fake):
    with keepmacawake.session(hours=8, cli=fake.path) as held:
        assert held.started and held.status.running
    assert fake.commands() == ["start"]
    assert fake.state["session"]["live"] is True


def test_session_uses_a_running_session_and_never_ends_it(fake):
    fake.state = {"session": {"live": True, "hours": 2, "phase": "active"}}
    with keepmacawake.session(hours=8, stop_on_exit=True, cli=fake.path) as held:
        assert not held.started and held.status.hours == 2
    assert fake.commands() == ["start"]
    assert fake.state["session"]["live"] is True


def test_stop_on_exit_ends_the_session_this_block_started(fake):
    with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
        pass
    assert fake.commands() == ["start", "status", "stop"]
    assert fake.state["session"]["live"] is False


def test_stop_on_exit_also_after_an_exception_which_still_propagates(fake):
    with pytest.raises(KeyError):
        with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
            raise KeyError("boom")
    assert fake.commands() == ["start", "status", "stop"]


def test_stop_on_exit_leaves_a_replaced_session_with_other_hours(fake):
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="left running"):
        with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
            fake.state = {"session": {"live": True, "hours": 6, "phase": "active"}}
    assert fake.commands() == ["start", "status"]
    assert fake.state["session"]["live"] is True


def test_stop_on_exit_leaves_a_replaced_session_with_the_same_hours_but_another_end(fake):
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="left running"):
        with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
            fake.state = {"session": {"live": True, "hours": 4, "remaining_seconds": 4 * 3600 - 600, "phase": "active"}}
    assert "stop" not in fake.commands()


def test_stop_on_exit_leaves_an_unlimited_session(fake):
    with pytest.warns(keepmacawake.KeepMacAwakeWarning):
        with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
            fake.state = {"session": {"live": True, "unlimited": True, "phase": "active"}}
    assert "stop" not in fake.commands()


def test_stop_on_exit_with_the_session_already_over(fake):
    with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
        fake.state = {"session": {"live": False, "last_end_reason": "clientStopped"}}
    assert fake.commands() == ["start", "status"]


def test_problem_at_exit_warns_and_never_hides_the_blocks_exception(fake):
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="could not end the session"):
        with pytest.raises(KeyError):
            with keepmacawake.session(hours=4, stop_on_exit=True, cli=fake.path):
                fake.force(status={"exit": 6, "reply": {"result": "error", "error": {"code": "service_unavailable"}}})
                raise KeyError("boom")


def test_session_raises_the_trial_limit_before_the_block_runs(fake):
    fake.state = {"session": {"live": False}, "access": {"state": "trial", "max_hours": 8}}
    ran = []
    with pytest.raises(keepmacawake.PurchaseRequiredError, match="at most 8 hours"):
        with keepmacawake.session(hours=12, cli=fake.path):
            ran.append(True)
    assert ran == []


def test_session_without_the_app():
    with pytest.raises(keepmacawake.NotInstalledError, match="keepmacawake.com"):
        with keepmacawake.session():
            pass


def test_session_waiting_for_ac_warns(fake):
    fake.state = {"session": {"live": False}, "start_phase": "waitingForAC"}
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="AC power"):
        with keepmacawake.session(hours=2, cli=fake.path) as held:
            assert held.status.waiting_for_ac


BATTERY_DEFAULT = {"battery": "allowed", "battery_chosen": False, "min_battery_percent": 20}


def test_status_reads_the_battery_settings(fake):
    state = keepmacawake.status(cli=fake.path)
    assert state.battery_available is True and state.battery_allowed is False and state.battery_chosen is True
    assert state.min_battery_percent == 20 and not state.battery_needs_consent


def test_status_names_a_battery_default_the_user_did_not_choose(fake):
    fake.state = {"session": {"live": False}, "config": BATTERY_DEFAULT}
    state = keepmacawake.status(cli=fake.path)
    assert state.battery_allowed is True and state.battery_chosen is False and state.battery_needs_consent
    assert "Run on battery turned itself on" in str(state) and "down to 20%" in str(state)


def test_battery_the_user_chose_needs_no_consent(fake):
    fake.state = {"session": {"live": False}, "config": {"battery": "allowed", "battery_chosen": True}}
    assert not keepmacawake.status(cli=fake.path).battery_needs_consent


def test_older_app_without_battery_chosen_needs_no_consent(fake):
    fake.state = {"session": {"live": False}, "config": {"battery": "allowed", "battery_chosen": None}}
    state = keepmacawake.status(cli=fake.path)
    assert state.battery_chosen is None and not state.battery_needs_consent


def test_mac_without_a_battery_needs_no_consent(fake):
    fake.state = {"session": {"live": False},
                  "config": {"battery": "ac-only", "battery_available": False, "battery_chosen": False}}
    assert not keepmacawake.status(cli=fake.path).battery_needs_consent


def test_start_warns_when_the_session_may_run_on_battery_unchosen(fake):
    fake.state = {"session": {"live": False}, "config": BATTERY_DEFAULT}
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="may run on battery down to 20%"):
        result = keepmacawake.start(hours=8, cli=fake.path)
    assert result.running and result.battery_needs_consent


def test_session_warns_when_it_may_run_on_battery_unchosen(fake):
    fake.state = {"session": {"live": False}, "config": dict(BATTERY_DEFAULT, min_battery_percent=30)}
    with pytest.warns(keepmacawake.KeepMacAwakeWarning, match="down to 30%"):
        with keepmacawake.session(hours=2, cli=fake.path) as held:
            assert held.started


def test_start_with_settings_the_user_chose_gives_no_warning(fake):
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        keepmacawake.start(hours=8, cli=fake.path)


def test_magic_names_the_battery_default(fake, capsys):
    fake.state = {"session": {"live": False}, "config": BATTERY_DEFAULT}
    _magic.keepmacawake_magic("8h", cli=fake.path)
    out = capsys.readouterr().out
    assert "keeps this Mac awake for 8 hours" in out and "may run on battery down to 20%" in out


def test_session_as_a_decorator(fake):
    @keepmacawake.session(hours=2, stop_on_exit=True, cli=fake.path)
    def job():
        return fake.state["session"]["live"]

    assert job() is True
    assert fake.commands() == ["start", "status", "stop"]


def test_recursive_decorated_calls_keep_their_own_ownership(fake):
    @keepmacawake.session(hours=2, stop_on_exit=True, cli=fake.path)
    def job(depth):
        if depth:
            job(depth - 1)

    job(1)
    # The outer call started the session; the inner one found it running and left it to the outer call.
    assert fake.commands() == ["start", "start", "status", "stop"]
    assert not fake.state["session"]["live"]


def test_session_checks_hours_when_made(fake):
    with pytest.raises(ValueError):
        keepmacawake.session(hours=0)
    assert fake.calls() == []


def test_never_an_unlimited_session(fake):
    with keepmacawake.session(cli=fake.path):
        pass
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        _magic.keepmacawake_magic("on", cli=fake.path)
    assert all("--unlimited" not in call for call in fake.calls())


# The IPython magic


@pytest.mark.parametrize("line,expected", [
    ("", ("status", None)), ("status", ("status", None)), ("off", ("stop", None)), ("stop", ("stop", None)),
    ("on", ("start", 8)), ("start", ("start", 8)), ("8h", ("start", 8)), ("8", ("start", 8)),
    ("2 hours", ("start", 2)), ("start 3h", ("start", 3)), ("168h", ("start", 168)), ("help", ("help", None)),
])
def test_magic_reads_its_line(line, expected):
    assert _magic.parse(line) == expected


@pytest.mark.parametrize("line", ["0h", "169h", "forever", "8m", "-1"])
def test_magic_rejects_other_lines(line):
    with pytest.raises(ValueError, match="%keepmacawake 8h"):
        _magic.parse(line)


def test_magic_start_status_and_off(fake, capsys):
    _magic.keepmacawake_magic("8h", cli=fake.path)
    assert "keeps this Mac awake for 8 hours" in capsys.readouterr().out
    _magic.keepmacawake_magic("", cli=fake.path)
    assert "8 h 0 min left" in capsys.readouterr().out
    _magic.keepmacawake_magic("8h", cli=fake.path)
    assert capsys.readouterr().out.startswith("A Keep Mac Awake session is already running, 8 h 0 min left, so no new one")
    _magic.keepmacawake_magic("off", cli=fake.path)
    assert "normal sleep applies" in capsys.readouterr().out
    assert fake.commands() == ["start", "status", "start", "stop"]


def test_magic_raises_so_a_notebook_run_stops(fake):
    fake.state = {"session": {"live": False}, "access": {"state": "trial", "max_hours": 8}}
    with pytest.raises(keepmacawake.PurchaseRequiredError):
        _magic.keepmacawake_magic("12h", cli=fake.path)


def test_load_ipython_extension_registers_the_magic(fake, monkeypatch, capsys):
    monkeypatch.setenv("KEEPMACAWAKE_CLI", fake.path)

    class Shell:
        def register_magic_function(self, func, magic_kind, magic_name):
            self.registered = (func, magic_kind, magic_name)

    shell = Shell()
    keepmacawake.load_ipython_extension(shell)
    func, kind, name = shell.registered
    assert (kind, name) == ("line", "keepmacawake")
    func("status")
    assert "No Keep Mac Awake session is running" in capsys.readouterr().out


def test_version_matches_the_changelog():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "CHANGELOG.md")) as handle:
        assert f"## [{keepmacawake.__version__}]" in handle.read()
