# Keep Mac Awake MCP server

<!-- mcp-name: com.keepmacawake/mcp -->

This MCP server lets an AI agent use Keep Mac Awake, a macOS app that keeps a MacBook with Apple silicon awake with the lid closed during a session. It needs the app, which is installed separately and is a paid app with a free trial ([keepmacawake.com](https://keepmacawake.com/?utm_source=github&utm_medium=community&utm_campaign=readme&utm_content=mcp)). With it, the agent starts a timed session before long work, stops it when the work is done, and tells you when the app needs something from you, such as AC power or a purchase after the trial.

It works in any app that runs local MCP servers (Claude Desktop, Claude Code, Codex, Cursor, VS Code, Windsurf and others). If your agent takes plugins, the [Keep Mac Awake plugin](https://github.com/bartdudzic/keepmacawake/tree/main/plugins/keep-mac-awake) does the same with a skill and adds a session-start hook.

## Tools

| Tool | What it does |
| --- | --- |
| `keep_awake_status` | Whether a session runs and its time left, the free trial, and a newer version of the app. Read only. |
| `keep_awake_start` | Starts a session of 1 to 168 whole hours, or without a time limit. |
| `keep_awake_stop` | Ends the session and restores the normal sleep setting. |

The agent starts timed sessions on its own and tells you in one line. It asks you first before a session without a time limit and before the first session on a Mac, which starts the free trial: `keep_awake_start` refuses both until the agent passes `user_agreed`. It never starts a second session over a running one. Battery use, buying and installing stay with you, in the menu bar panel or in Terminal.

## Install

You need Node.js 20 or later and the Keep Mac Awake app (any Mac with Apple silicon and macOS 26 or later).

Claude Code:

```sh
claude mcp add keepmacawake -- npx -y keepmacawake-mcp
```

Codex:

```sh
codex mcp add keepmacawake -- npx -y keepmacawake-mcp
```

Claude Desktop, Cursor and other apps with a JSON configuration (`claude_desktop_config.json`, `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "keepmacawake": {
      "command": "npx",
      "args": ["-y", "keepmacawake-mcp"]
    }
  }
}
```

If the app reports that `npx` is not found, give its full path, for example `/opt/homebrew/bin/npx`.

From a clone of this repository instead of npm:

```sh
git clone https://github.com/bartdudzic/keepmacawake
cd keepmacawake/mcp && npm ci --omit=dev
claude mcp add keepmacawake -- node "$PWD/bin/keepmacawake-mcp.mjs"
```

## Examples

- "Run the full test suite and fix what fails. I'm closing the lid and will check back from my phone."
- "Keep the Mac awake for the next 2 hours while this migration runs."
- "Is Keep Mac Awake on, and how much time is left?"

## What it runs

- Each tool runs the app's `keepmacawake` command once on this Mac (`status`, `start` or `stop`, with `--json`), from `/usr/local/bin`, where the installer puts it, or from `PATH`. Set `KEEPMACAWAKE_CLI` to use another path.
- It never runs anything else: no installer, no script, no `sudo`, no settings changes, no payments.
- The command talks only to the app's background service on this Mac. The server opens no network connection and has no telemetry.
- It works only where the server runs on your Mac itself. Elsewhere, such as a cloud container, every tool answers that Keep Mac Awake is out of reach from there.

## Privacy

The server sends nothing anywhere. Its results become part of the agent's conversation, so the agent's provider receives them: whether a session runs, its time left, the trial's time left, the battery settings and a newer version. From the app's reply the server passes on only those fields: never this Mac's ID, the purchase details or the app's own messages, apart from the short reason the app gives when it refuses a session. The app's own data use is in its [privacy description](https://keepmacawake.com/privacy.md).

## Troubleshooting

- "Keep Mac Awake is not installed": install the app from [keepmacawake.com](https://keepmacawake.com/?utm_source=github&utm_medium=community&utm_campaign=readme&utm_content=mcp), or set `KEEPMACAWAKE_CLI` if the command is somewhere else.
- "Its background service did not answer": open Keep Mac Awake from Applications. An MCP host that runs servers in a sandbox may block the connection to the service.
- A session refused on battery: plug in AC power, or allow battery use in the menu bar panel.

## Development

```sh
npm ci
npm test
```

The tests run against a fake `keepmacawake` command and never touch a real session.

## Support

Write to hi@keepmacawake.com. Security issues: see [SECURITY.md](https://github.com/bartdudzic/keepmacawake/blob/main/SECURITY.md). Keep Mac Awake is not affiliated with Apple.

## License

The server is under the [MIT License](LICENSE). The Keep Mac Awake app it controls is not: buying it after the free trial is covered by its own terms.
