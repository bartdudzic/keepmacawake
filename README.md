# Keep Mac Awake

Keep Mac Awake keeps your MacBook awake with the lid closed, without an external display or keyboard, so long jobs, downloads and AI agents keep running. You start each session yourself, from the menu bar or from Terminal; a timed session ends on its own.

**9 USD plus applicable tax, a one-time payment per Mac.** No subscription. Try it free for 3 days, with no card and no account; during the trial a session lasts up to 8 hours. See [Buying](#buying).

## What it does

- **One button in the menu bar.** Start a session with no limit, for 1 hour, 8 hours or any number of hours up to 168. The icon shows whether sleep prevention is confirmed.
- **AC power by default.** If you unplug, the session pauses and continues when AC power returns. Optionally it runs on battery above a level you choose (20% by default) and ends there.
- **Display off with the lid closed.** The built-in display goes dark when you close the lid, even if another app asked to keep it on.
- **A command for Terminal and AI agents.** `keepmacawake start --hours 8`, `status`, `stop`, each with `--json`.
- **Safe by design.** A separate supervising service restores the normal sleep setting if anything stops or hangs. Quitting the app always restores it. A battery session also ends when the Mac gets too hot.
- **Almost nothing leaves your Mac.** No accounts, analytics or logs. On its own the app only checks for a new version once a day, with nothing about your Mac in the request, and installs a new version by itself when no session runs; Restore purchase happens when you ask.

## What it does not do

- A session never starts by itself, at login or on a schedule.
- It does not keep Wi-Fi or other network connections alive, and it does not wake a Mac that is already asleep.
- It does not read your files, screen, clipboard or other apps.
- It needs no special permissions such as Accessibility or Full Disk Access, and no changes to SIP, Gatekeeper or FileVault.

## Requirements

- Any Mac with Apple silicon (an M-series chip) and macOS 26 or later.
- Your administrator password during installation, because the sleep setting applies to the whole Mac.

## Keep it ventilated

A Mac that works with its lid closed still produces heat. Do not run it in a closed bag, under a pillow or on a soft surface. On battery, Keep Mac Awake ends the session at a serious thermal state, but it cannot protect a Mac from a place without airflow.

## Install

1. Download `KeepMacAwake-1.0.4-arm64.pkg` from the [latest release](https://github.com/bartdudzic/keepmacawake/releases/latest).
2. Optional: check the download in Terminal. The result must match the `.sha256` file of the release.

   ```sh
   shasum -a 256 ~/Downloads/KeepMacAwake-1.0.4-arm64.pkg
   ```

3. Open the package and follow the steps. Then click the icon in the menu bar and press the power button.

The packages are signed with Developer ID and notarized by Apple.

### From Terminal

```sh
curl -fsSL https://keepmacawake.com/install.sh | sh
```

An AI agent does not run this itself: it gives you the download link and leaves the installer to you.

The [script](https://keepmacawake.com/install.sh) downloads the latest package from the releases, checks its SHA-256, the Developer ID signature and Apple's notarization, and runs macOS Installer. macOS asks for an administrator password once: in Terminal, or in a system dialog when an AI agent runs the command. It refuses while a session runs, and installing turns nothing on. Options: `--version X.Y.Z`, `--dry-run` (download and check only) and `--uninstall`, passed as `sh -s -- --uninstall`.

## Update

Download the new package and open it, or run the install command again. The package ends a running session first and keeps your battery settings; the command refuses while a session runs. The app checks for a new version once a day and, since 1.0.4, installs it by itself when no session runs: it downloads the package from this page, checks its signature and notarization, installs it with no password and opens again. **Install** in its panel does it at once, **Check for Updates…** in its "…" menu checks at once, and `keepmacawake config set --update-check off` turns the daily check, and with it the automatic install, off.

## Uninstall

Open `KeepMacAwake-Uninstall-1.0.4-arm64.pkg` from the same release. It restores the sleep setting, stops the services and removes the app and the command. Moving the app to the Trash does not remove the services. From Terminal: `curl -fsSL https://keepmacawake.com/install.sh | sh -s -- --uninstall`.

## Command line

```sh
keepmacawake start --hours 8      # or --unlimited
keepmacawake status --json
keepmacawake stop
keepmacawake config set --battery allowed --min-battery 30
```

Run it as the logged-in user, not with `sudo`. The session continues after the command exits. Reference: [command line](docs/COMMAND-LINE.md).

## For AI agents

The [Keep Mac Awake plugin](plugins/keep-mac-awake/README.md) teaches your agent to start a timed session before long work and stop it after, so you do not have to remember. It always asks before a session without a time limit, battery use, installing and buying.

```sh
claude plugin install keep-mac-awake --marketplace bartdudzic/keepmacawake   # Claude Code
npx skills add bartdudzic/keepmacawake -g                                     # any agent that reads Agent Skills
```

## Buying

1. Install Keep Mac Awake and use it. The 3-day trial starts with your first session; sessions last up to 8 hours.
2. When you are ready, choose **Buy for $9** in the panel (or run `keepmacawake buy`). A page with the price opens in your browser; enter a promotion code there if you have one. Then Stripe's checkout opens: Stripe sells it as the reseller and adds the tax that applies where you live. A code that makes it free needs no card.
3. After paying, the page opens Keep Mac Awake and unlocks this Mac. There is no key to type. The purchase works offline from then on.

- **Reinstalled, or a second user account on the same Mac?** Choose **Restore purchase**.
- **New Mac, or a repair that replaced the logic board?** Write to hi@keepmacawake.com with your receipt and the new Mac's ID (**About Keep Mac Awake** in the panel's "…" menu shows it).
- When the trial ends, a session that is running continues to its end; a new one needs the purchase.

## Privacy

On its own, Keep Mac Awake goes online only for a daily update check to keepmacawake.com, which carries nothing about your Mac and can be turned off. Restore purchase sends this Mac's ID when you choose it, and Install downloads a new version from GitHub when you choose it. Buy opens the purchase page in your browser. It reads the power source, the battery level, the lid and the thermal state of this Mac. It stores your two battery settings, the update check's setting and its last answer, the position of its menu bar icon, your purchase, the time of the first session for the trial, and the state its services need to restore the sleep setting, and nothing else. Details: [privacy](docs/PRIVACY.md).

## Source code

The system services, the installer scripts and their tests are in this repository: everything that runs with administrator rights. The source is available under [PolyForm Shield 1.0.0](LICENSE): you can read, build and check it, but not use it in a competing product. It is not open source in the OSI sense. The menu bar app is not included. The [agent plugin](plugins/keep-mac-awake) is here too, under the [MIT License](plugins/keep-mac-awake/LICENSE); it only calls the `keepmacawake` command.

Each release lists the code hashes of the shipped services, so you can match them to a build from the tagged source.

## Support and security

- Questions and bugs: [issues](https://github.com/bartdudzic/keepmacawake/issues). Pull requests are not accepted for now.
- Everything else, including purchases and vulnerabilities: hi@keepmacawake.com. Report vulnerabilities there, not in a public issue; see [SECURITY.md](SECURITY.md).

## Terms

Keep Mac Awake is provided as is, without warranty. See [terms of use](TERMS.md).
