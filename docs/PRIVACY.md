# Keep Mac Awake privacy

This describes version 1.0. It is meant to match the actual behavior of the shipped build; the network check on the running build confirms it before each release.

## What the app reads

| Data | Who reads it | Purpose |
| --- | --- | --- |
| Power source, level and charging state of the built-in battery; on a Mac without one, only which source macOS says is providing power (AC, battery or UPS) | app (menu bar panel, only while open), helper, watchdog | Deciding whether the session may continue; information for the user |
| Lid state | app (menu bar panel, only while open); coordinator, during a session | Information for the user; turning the display off when the lid closes |
| Which displays are active, whether the built-in display sleeps, and the time since the last keyboard, mouse or remote input (not the input itself) | coordinator, only while the lid is closed in a session | Turning the built-in display off only when no other display is in use and nobody works remotely |
| macOS thermal state | helper, watchdog | Ending the session on battery in the `serious`/`critical` state |
| Console user identifier | helper, watchdog | The session belongs to the logged-in user and ends on a user switch |
| Code signatures of the app, the command, the coordinator and the helper | helper, coordinator, app, command | Mutual authentication |
| The Mac's platform UUID (`IOPlatformUUID`) | coordinator | Deriving the Mac ID (below); the UUID itself is not stored or sent |
| The `SleepDisabled` setting | helper, watchdog | Enabling, verifying and restoring sleep prevention |

Readings are not stored or sent; each reading replaces the previous one in memory.

## What the app writes

- In the user preferences (`com.keepmacawake`): `allowsBattery` and `minimumBatteryPercent`, written by the per-user background service (the coordinator), which the panel and the command line both use, and for the update check `checksForUpdates` (only once it is switched), `updateCheckedAt` and `updateLatestVersion` (when the last check got an answer, and the latest version it named). After a purchase the coordinator also keeps it there (`license`), and a copy of the first-session record (`firstSessionAt`, `latestSeenAt`). macOS also stores the position of the menu bar icon there, and the panel stores `agentInviteDismissed` once its AI agent card is dismissed or its prompt copied.
- The installer adds the coordinator's LaunchAgent (`/Library/LaunchAgents/com.keepmacawake.Coordinator.plist`) and, where the path is free, the link `/usr/local/bin/keepmacawake`; the uninstaller removes both.
- In the protected system directory `/Library/Application Support/KeepMacAwake` (root, 0700): a restoration journal that exists only during a session, helper and watchdog supervision signals with the current session state, and a lock file. During an update that replaces a running app, the installer keeps there, for a moment, which user to open the new app for. No session history.
- In the same directory, the first-session record (`first-session.json`): the time of the first session the helper accepted on this Mac and the latest time it has seen since. The helper writes it at the first session, at the start and end of later sessions and at most once an hour in between, and never again once a week has passed since the first session. Moving the clock back does not lower either value. The uninstaller leaves it in place, so a reinstall continues from it; the app counts the 3-day trial from it.
- Nothing from NoSleepMac, the development name, is read or changed. Its preferences (`com.bartdudzic.NoSleepMac`) and report files from test versions stay until deleted by hand.

## What the app sends

On its own, one thing; the rest only when you ask:

- **The update check**, on by default. About once a day the coordinator makes one HTTPS request to `keepmacawake.com/api/latest` and gets back the number of the latest version. The request carries nothing about this Mac: no Mac ID, no version, no cookies, and a User-Agent that says only "Keep Mac Awake". Turn it off with `keepmacawake config set --update-check off`; then it checks only when you choose **Check for Updates…** in the panel's "…" menu (or run `keepmacawake check-updates`), and nothing installs by itself.
- **Restore purchase**, only when you ask (in the panel, or `keepmacawake restore`): one HTTPS request from the coordinator to `keepmacawake.com` with the Mac ID in the address, which gets back the purchase if this Mac was paid for. No cookies, no cache, nothing else in the request.
- **Installing an update**, by itself when the update check found a newer version and no session runs (since 1.0.4), or at once when you choose **Install** in the panel: the coordinator downloads that release's package and its checksum file from the public releases page (`github.com/bartdudzic/keepmacawake/releases`), as the command-line installer does; GitHub sees that download like any other, and it carries nothing about this Mac. The package is installed only if it matches the checksum, carries the Developer ID signature of the Keep Mac Awake developer and is notarized by Apple, and only if it is newer than the installed version; the system service checks its own copy again and installs it with no password. With the update check off, nothing installs by itself.

Otherwise the app, the coordinator, the helper and the watchdog make no network connections; a session never needs the network.

The **Mac ID** is the first 32 hexadecimal characters of SHA-256 over a purpose label and the platform UUID. It does not reveal the UUID or the serial number, but it is a pseudonym, not anonymous: the server and Stripe can link a purchase and its restores to the same Mac. **Buy** opens the purchase page `keepmacawake.com/buy` with the Mac ID in your default browser; from there the browser goes to Stripe Checkout, with a promotion code if you entered one. Stripe, as the reseller, receives what the purchase needs (e-mail, payment details, billing country and address for tax) and the Mac ID with the payment; for an order that a code makes free, Stripe keeps the Mac ID with a customer record instead. The server stores nothing: it reads Stripe and signs the purchase for that Mac.

Independently of the app, macOS may check the certificate status online when verifying the Developer ID signature or notarization; this is system behavior, not Keep Mac Awake.

## AI agents

The Keep Mac Awake plugin and skill for AI agents send nothing anywhere. An agent runs `keepmacawake` on this Mac as a person would in Terminal. The plugin's hook runs `keepmacawake status --json` when an agent session begins and adds a few sentences of its own to the agent's conversation, so the agent's provider receives them with the rest of the conversation: whether a session runs and its time left, the trial's time left, and a newer version. They do not contain the Mac ID; `keepmacawake status --json`, which an agent may also run, does. The app and the command never read the agent's files, settings or prompts.

## What the app does not do

It does not read documents, the screen, the clipboard, the activity of other apps or hardware identifiers other than the platform UUID used for the Mac ID. It does not require Full Disk Access, Accessibility or screen recording. It has no analytics, error reports or accounts. A purchase is a signed statement for one Mac, checked offline; nothing checks it online. The helper does not execute commands passed by the client.
