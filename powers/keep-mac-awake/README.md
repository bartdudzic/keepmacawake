# Keep Mac Awake power for Kiro

This power teaches the Kiro agent to use Keep Mac Awake, a macOS app that keeps a MacBook with Apple silicon awake with the lid closed during a session. It needs the app, which is installed separately and starts with a free trial ([keepmacawake.com](https://keepmacawake.com)). With it, the agent starts a timed session before long work, stops it when the work is done, and tells you when the app needs something from you, such as AC power. Why an agent needs it: a MacBook sleeps when you close the lid, and the agent's work stops with it ([keep AI agents running with the lid closed](https://keepmacawake.com/blog/run-ai-agents-overnight-macbook)).

The power is in the [Agent Plugins](https://agent-plugins.org) format: a `plugin.json` manifest and one skill, `skills/keepmacawake/SKILL.md`, the same skill as the [Keep Mac Awake plugin](../../plugins/keep-mac-awake/README.md) for Claude Code, Codex, Cursor and Copilot CLI. It has no hook and no MCP server. Kiro activates it when your request mentions keeping the Mac awake, closing the lid or long work you leave running.

The agent starts timed sessions on its own and tells you in one line. It always asks before a session without a time limit, battery use, installing the app and buying.

## What it runs

- The skill has the agent run the `keepmacawake` command (`status`, `start`, `stop`, `config`, `buy`, `restore`, `capabilities`), and `sysctl` and `sw_vers` to check that the Mac fits. `keepmacawake buy` opens the purchase page on keepmacawake.com in your browser, and `keepmacawake restore`, when you ask for it, sends this Mac's ID to keepmacawake.com to find an earlier purchase. When a task you asked for needs the app and it is missing, the agent offers it once and gives you the download link; you download and open the installer yourself.
- The power never downloads or runs an installer or a script, never uses `sudo` and never pays.
- It works where Kiro runs commands on your Mac itself. When the commands run elsewhere, such as a cloud session, the agent says the app is out of reach. When a sandbox keeps `keepmacawake` from reaching the app's background service, the agent asks to run it outside the sandbox; approve it.

## Examples

- "Run the full test suite and fix what fails. I'm closing the lid and will check back from my phone."
- "Keep the Mac awake for the next 2 hours while this migration runs."
- "Is Keep Mac Awake on, and how much time is left?"

## Install

In Kiro, open the Powers panel, choose Add Custom Power, then Import power from GitHub, and enter:

```text
https://github.com/bartdudzic/keepmacawake/tree/main/powers/keep-mac-awake
```

The power needs the Keep Mac Awake app (any Mac with Apple silicon and macOS 26 or later): <https://keepmacawake.com>.

## Privacy

Privacy policy: <https://keepmacawake.com/privacy>.

The power itself sends nothing anywhere; of the commands it runs, only `keepmacawake restore` goes online, with this Mac's ID, and `keepmacawake buy` opens a page in your browser, both only when you ask. When the agent runs `keepmacawake status --json`, its output enters the conversation, so Kiro's model provider receives it; it includes the Mac ID that a purchase is tied to (`access.mac_id`).

## Support

Write to hi@keepmacawake.com. Security issues: see [SECURITY.md](https://github.com/bartdudzic/keepmacawake/blob/main/SECURITY.md). Keep Mac Awake is not affiliated with Apple or Amazon.

## License

The power is under the [MIT License](LICENSE). The Keep Mac Awake app it controls is not: buying it after the free trial is covered by its own terms.
