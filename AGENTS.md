# Instructions for AI agents

This repository is the public core of Keep Mac Awake: the root helper and watchdog that change and restore the macOS `SleepDisabled` setting, their session and supervision logic, the restoration journal, the XPC protocol, the installer scripts and the recovery reader. The menu bar app, the per-user coordinator and the `keepmacawake` command are not here. The plugin for AI agents is in `plugins/keep-mac-awake` (an Agent Skill and a read-only session-start hook, under the MIT License), with the marketplace manifests in `.claude-plugin/` (Claude Code, Codex, Copilot CLI) and `.cursor-plugin/` (Cursor).

- Keeping a session alive that should continue comes first; restoring the sleep setting after any failure comes second; lightness third. Do not trade the first two for the third.
- Never change power settings from a build, a test or a script. Tests use fakes; hardware checks are run by a person, on purpose.
- The helper accepts only status, start, renew and stop, from a client whose code hash is in the root-owned trust file. Do not add commands, paths or arguments that the helper would run or open.
- Everything is English. Plain Markdown, relative links, no U+2014 or U+2013 dashes. `scripts/scan-public-content.sh` must pass.
- No network code. No logging of user activity.
- The agent plugin only calls the public `keepmacawake` command. Its hook stays read only: no network, no start, stop or settings change, and it never reads the user's prompts or files. Check it with `claude plugin validate --strict plugins/keep-mac-awake` and `claude plugin validate --strict .`.
- Pull requests from others are not accepted for now; see [CONTRIBUTING.md](CONTRIBUTING.md).

Start with [README.md](README.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/FAILURE-MODES.md](docs/FAILURE-MODES.md).
