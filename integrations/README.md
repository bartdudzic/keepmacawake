# Integrations

Ways to start, check and stop Keep Mac Awake sessions from the automation tools you already use. Each one only runs the `keepmacawake` command that the app installs, so it needs the [Keep Mac Awake](https://keepmacawake.com) app on the Mac (it has a free trial). All of them are under the MIT License.

| Tool | Folder | What you get |
| --- | --- | --- |
| Alfred | [alfred](alfred/README.md) | The `awake` keyword: start for 1 hour, 8 hours, any number of hours or with no time limit, status, stop |
| Apple Shortcuts | [shortcuts](shortcuts/README.md) | Shortcuts to start 8 hours, show the status and stop, for the menu bar, Spotlight and Siri |
| Hammerspoon | [hammerspoon](hammerspoon/README.md) | `KeepMacAwake.spoon`: hotkeys and Lua methods for start, status and stop |

For AI agents, see the [plugin](../plugins/keep-mac-awake/README.md) and the [MCP server](../mcp/README.md). Every command and answer is in the [command line reference](../docs/COMMAND-LINE.md).
