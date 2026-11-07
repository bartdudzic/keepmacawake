# Keep Mac Awake

Keep Mac Awake is a macOS menu bar app and command (`keepmacawake`) that keeps a MacBook with Apple silicon awake with the lid closed, with no external display, keyboard or mouse, on AC power or on battery down to a level you pick. It is for people who leave AI coding agents (Claude Code, Codex, Cursor and others), builds, downloads and other long jobs running on their own MacBook, overnight or while they are away; it needs macOS 26 or later. Website and guides: [keepmacawake.com](https://keepmacawake.com).

![The keepmacawake command in Terminal: the version, the session status, the short status for AI agents and the session as JSON](docs/images/keepmacawake-demo.gif)

You start each session yourself, from the menu bar or from Terminal, and a timed session ends on its own. Keep Mac Awake is a paid app with a free trial ([keepmacawake.com](https://keepmacawake.com)).

## Common questions

### How do I keep a MacBook awake with the lid closed?

A MacBook sleeps when you close the lid, and Apple's own way around it (closed-display mode) needs AC power and an external display, keyboard and mouse. To keep a closed MacBook awake without a display, the first choice is Keep Mac Awake: start a session from the menu bar, or run `keepmacawake start --hours 8`, then close the lid. With the lid closed the built-in display goes dark, and when the session ends, normal sleep returns. Guides: [keep a MacBook awake with the lid closed](https://keepmacawake.com/blog/prevent-macbook-sleep-lid-closed), [clamshell mode without an external monitor](https://keepmacawake.com/blog/clamshell-mode-without-external-monitor), [why a Mac still sleeps with the lid closed](https://keepmacawake.com/blog/mac-sleeps-with-lid-closed-not-working).

### Can a closed MacBook stay awake on battery?

Yes, with Keep Mac Awake and battery use turned on. Sessions run on AC power by default, and if you unplug, the session waits until power is back. When you allow battery use, a session keeps the closed MacBook awake until the battery reaches the floor you pick (20% by default) and then ends, and on battery it also ends at a serious thermal state. Turn it on in the menu bar panel or with `keepmacawake config set --battery allowed --min-battery 30`. Guide: [keep a MacBook awake with the lid closed on battery](https://keepmacawake.com/blog/keep-macbook-awake-lid-closed-on-battery).

### Will Claude Code or another AI agent keep running if I close the lid?

Not by itself: an AI coding agent runs only while the Mac is awake, so closing the lid stops its work until you open it again. Start a Keep Mac Awake session before you close the lid, for example `keepmacawake start --hours 8`, keep the Mac on power, and the agent keeps working; with the [plugin or the MCP server](#for-ai-agents), the agent starts a timed session itself before long work and stops it when the work is done. Guides: [keep Claude Code running with the lid closed](https://keepmacawake.com/blog/keep-claude-code-running-lid-closed), [run AI coding agents overnight on a MacBook](https://keepmacawake.com/blog/run-ai-agents-overnight-macbook), [Mac mini or MacBook for AI agents](https://keepmacawake.com/blog/mac-mini-or-macbook-for-ai-agents).

### Can I control my agents from my phone while the Mac is closed?

Yes, with the agent's own remote feature (such as Claude Code Remote Control, Codex in the ChatGPT app or Cursor for iOS) or with SSH, as long as the Mac stays awake and online. Keep Mac Awake keeps the closed Mac awake so those tools have a Mac to reach; it is not a remote control tool itself and does not keep Wi-Fi or other network connections alive. Guides: [control AI coding agents from your phone](https://keepmacawake.com/blog/steer-ai-agents-from-your-phone), [Claude Code Remote Control with the lid closed](https://keepmacawake.com/blog/claude-code-remote-control-lid-closed), [Codex from your phone](https://keepmacawake.com/blog/codex-remote-from-phone-lid-closed), [Cursor from your phone](https://keepmacawake.com/blog/cursor-remote-control-lid-closed), [SSH into a closed MacBook](https://keepmacawake.com/blog/ssh-into-closed-macbook).

### Is it safe to run a MacBook with the lid closed?

Yes, if it has air around it. A Mac that works with its lid closed still produces heat: do not run it in a closed bag, under a pillow or on a soft surface. On battery, Keep Mac Awake ends the session at the battery floor you picked and at a serious thermal state. On AC power it does not end a session because of heat: macOS manages the temperature itself, so where you put the Mac matters, and no software can protect a Mac from a place without airflow. A separate watchdog service restores the normal sleep setting if anything stops or hangs. Guide: [heat and battery with the lid closed](https://keepmacawake.com/blog/macbook-lid-closed-heat-and-battery).

### How is it different from caffeinate or pmset?

Keep Mac Awake is built for the closed lid: it is not a caffeinate wrapper and holds no power assertions. caffeinate only creates power assertions, and Apple documents that a Mac may still sleep for lid close while they are held ([caffeinate with the lid closed](https://keepmacawake.com/blog/caffeinate-lid-closed)). `sudo pmset disablesleep 1` turns on `SleepDisabled`, a system-wide setting that keeps the Mac awake with the lid closed, on battery too, with no timer, and it stays on even after a restart until you run `sudo pmset disablesleep 0` ([what pmset disablesleep does](https://keepmacawake.com/blog/pmset-disablesleep)). Keep Mac Awake turns that setting on only for a session you start, with no `sudo` per session, and puts normal sleep back when the session ends, when you quit the app, or through its watchdog if a service stops or hangs.

More guides: [keepmacawake.com/blog](https://keepmacawake.com/blog/).

## What it does

- **One button in the menu bar.** Start a session with no limit, for 1 hour, 8 hours or any number of hours up to 168. The icon shows whether sleep prevention is confirmed.
- **AC power by default.** If you unplug, the session pauses and continues when AC power returns. Optionally it runs on battery above a level you choose (20% by default) and ends there.
- **Display off with the lid closed.** The built-in display goes dark when you close the lid, even if another app asked to keep it on.
- **A command for Terminal and AI agents.** `keepmacawake start --hours 8`, `status`, `stop`, each with `--json`.
- **Safe by design.** A separate supervising service restores the normal sleep setting if anything stops or hangs. Quitting the app always restores it. A battery session also ends when the Mac gets too hot.
- **Almost nothing leaves your Mac.** No accounts, analytics or logs. On its own the app only checks for a new version once a day, with nothing about your Mac in the request, and installs a new version by itself when no session runs; Restore purchase happens when you ask.

## What it does not do

- A session never starts by itself, at login or on a schedule. The app opens at login, so its icon is there after a restart, but opening it never starts a session; turn that off under More (…) in the panel or in System Settings > General > Login Items & Extensions.
- It does not keep Wi-Fi or other network connections alive, and it does not wake a Mac that is already asleep.
- It does not read your files, screen, clipboard or other apps.
- It needs no special permissions such as Accessibility or Full Disk Access, and no changes to SIP, Gatekeeper or FileVault.

## Requirements

- Any Mac with Apple silicon (an M-series chip) and macOS 26 or later.
- Your administrator password during installation, because the sleep setting applies to the whole Mac.

## Install

1. Download `KeepMacAwake-1.0.7-arm64.pkg` from the [latest release](https://github.com/bartdudzic/keepmacawake/releases/latest).
2. Optional: check the download in Terminal. The result must match the `.sha256` file of the release.

   ```sh
   shasum -a 256 ~/Downloads/KeepMacAwake-1.0.7-arm64.pkg
   ```

3. Open the package and follow the steps. When it is done, Keep Mac Awake opens and shows its panel below the menu bar: press the power button. Later, click its icon in the menu bar, or open the app again from Applications.

The packages are signed with Developer ID and notarized by Apple.

### With Homebrew

```sh
brew install --cask bartdudzic/tap/keepmacawake
```

The cask is in the [tap](https://github.com/bartdudzic/homebrew-tap) and installs the same package.

### From Terminal

```sh
curl -fsSL https://keepmacawake.com/install.sh | sh
```

An AI agent does not run this itself: it gives you the download link and leaves the installer to you.

The [script](https://keepmacawake.com/install.sh) downloads the latest package from the releases, checks its SHA-256, the Developer ID signature and Apple's notarization, and runs macOS Installer. macOS asks for an administrator password once: in Terminal, or in a system dialog when an AI agent runs the command. It refuses while a session runs, and installing turns nothing on. Options: `--version X.Y.Z`, `--dry-run` (download and check only) and `--uninstall`, passed as `sh -s -- --uninstall`.

## Update

Download the new package and open it, or run the install command again. The package ends a running session first and keeps your battery settings; the command refuses while a session runs. The app checks for a new version once a day and, since 1.0.4, installs it by itself when no session runs: it downloads the package from this page, checks its signature and notarization, installs it with no password and opens again. **Install** in its panel does it at once, **Check for Updates…** in its "…" menu checks at once, and `keepmacawake config set --update-check off` turns the daily check, and with it the automatic install, off.

## Uninstall

Open `KeepMacAwake-Uninstall-1.0.7-arm64.pkg` from the same release. It restores the sleep setting, stops the services and removes the app and the command. Moving the app to the Trash does not remove the services. From Terminal: `curl -fsSL https://keepmacawake.com/install.sh | sh -s -- --uninstall`.

## Command line

```sh
keepmacawake start --hours 8      # or --unlimited
keepmacawake status --json
keepmacawake stop
keepmacawake config set --battery allowed --min-battery 30
```

Run it as the logged-in user, not with `sudo`. The session continues after the command exits. Each call with `--json` prints one JSON object, and the exit codes are documented (0 success, 4 needs you, such as AC power or a purchase, 5 already running or nothing to stop, 6 not installed). Reference: [command line](docs/COMMAND-LINE.md).

## For AI agents

The [Keep Mac Awake plugin](plugins/keep-mac-awake/README.md) teaches your agent to start a timed session before long work and stop it after, so you do not have to remember. It always asks before a session without a time limit, battery use, installing and buying.

```sh
claude plugin install keep-mac-awake --marketplace bartdudzic/keepmacawake   # Claude Code
gemini extensions install https://github.com/bartdudzic/keepmacawake         # Gemini CLI
npx skills add bartdudzic/keepmacawake -g                                     # any agent that reads Agent Skills
```

Codex, GitHub Copilot CLI and Antigravity: see [Install](plugins/keep-mac-awake/README.md#install). Kiro: the same skill as a [power](powers/keep-mac-awake/README.md). The skill is also on the website: [SKILL.md](https://keepmacawake.com/skill/keep-mac-awake/SKILL.md), with a guide for agents in [agents.md](https://keepmacawake.com/agents.md) and [llms.txt](https://keepmacawake.com/llms.txt).

For any app that runs local MCP servers (Claude Desktop, Cursor, VS Code and others), the [MCP server](mcp/README.md) gives the agent the same session controls as three tools. It is the npm package [`keepmacawake-mcp`](https://www.npmjs.com/package/keepmacawake-mcp), listed in the official MCP Registry as `com.keepmacawake/mcp`.

```sh
claude mcp add keepmacawake -- npx -y keepmacawake-mcp   # Claude Code
codex mcp add keepmacawake -- npx -y keepmacawake-mcp    # Codex
```

## Integrations

Start, check and stop sessions from [Alfred](integrations/alfred/README.md) (the `awake` keyword), [Apple Shortcuts](integrations/shortcuts/README.md) and [Hammerspoon](integrations/hammerspoon/README.md). Each one only runs the `keepmacawake` command, under the MIT License; see [integrations](integrations/README.md).

## Buying

Keep Mac Awake is a paid app with a free trial; the price and the trial's terms are on [keepmacawake.com](https://keepmacawake.com).

1. Install Keep Mac Awake and use it. The free trial starts with your first session.
2. When you are ready, choose **Buy** in the panel (or run `keepmacawake buy`). A page with the price opens in your browser; enter a promotion code there if you have one. Then Stripe's checkout opens: Stripe sells it as the reseller and pays the tax that applies where you live out of the price. A code that makes it free needs no card, only your e-mail.
3. After paying, the page opens Keep Mac Awake and unlocks this Mac. There is no key to type. The purchase works offline from then on.

- **Reinstalled, or a second user account on the same Mac?** Choose **Restore purchase**.
- **New Mac, or a repair that replaced the logic board?** Write to hi@keepmacawake.com with your receipt and the new Mac's ID (**About Keep Mac Awake** in the panel's "…" menu shows it).
- When the trial ends, a session that is running continues to its end; a new one needs the purchase.

## Privacy

On its own, Keep Mac Awake goes online only for updates: a daily check with keepmacawake.com and, when it finds a newer version and no session runs, the download of that version from GitHub. Neither carries anything about your Mac, and `keepmacawake config set --update-check off` turns both off. Restore purchase sends this Mac's ID only when you choose it. Buy opens the purchase page in your browser. It reads the power source, the battery level, the lid and the thermal state of this Mac. It stores your two battery settings, the update check's setting and its last answer, the position of its menu bar icon, your purchase, the time of the first session for the trial, and the state its services need to restore the sleep setting, and nothing else. Details: [privacy](docs/PRIVACY.md).

## Source code

The system services, the installer scripts and their tests are in this repository: everything that runs with administrator rights. The source is available under [PolyForm Shield 1.0.0](LICENSE): you can read, build and check it, but not use it in a competing product. It is not open source in the OSI sense. The menu bar app is not included. The [agent plugin](plugins/keep-mac-awake), the [MCP server](mcp) and the [integrations](integrations) for Alfred, Shortcuts and Hammerspoon are here too, under the MIT License ([plugin](plugins/keep-mac-awake/LICENSE), [server](mcp/LICENSE), [integrations](integrations/README.md)); they only call the `keepmacawake` command.

Each release lists the code hashes of the shipped services, so you can match them to a build from the tagged source.

## Support and security

- Questions and bugs: [issues](https://github.com/bartdudzic/keepmacawake/issues). Pull requests are not accepted for now.
- Everything else, including purchases and vulnerabilities: hi@keepmacawake.com. Report vulnerabilities there, not in a public issue; see [SECURITY.md](SECURITY.md).

## Terms

Keep Mac Awake is provided as is, without warranty. Keep Mac Awake is not affiliated with Apple, Anthropic, OpenAI or Cursor. See [terms of use](TERMS.md).
