# Support: the Mac does not sleep, or the service does not respond

What to do when a Mac with Keep Mac Awake does not sleep when it should, or a session does not start. Every step is a readout first; changes are made only by the installer and uninstaller from an official release.

## 1. Determine the state

Ask for the output (without personal data):

```sh
sw_vers; sysctl -n hw.model
defaults read "/Applications/Keep Mac Awake.app/Contents/Info.plist" CFBundleShortVersionString
pmset -g | grep -i sleep
pmset -g assertions | grep -iE "PreventSystemSleep|PreventUserIdleSystemSleep" | head
sudo launchctl print system/com.keepmacawake.Helper | grep -E "state|pid"
sudo launchctl print system/com.keepmacawake.Watchdog | grep -E "state|pid"
```

A `SleepDisabled 1` line in `pmset -g` means an active global lock. It may come from Keep Mac Awake or another tool (`pmset disablesleep 1`, other apps). Keep Mac Awake does not take over or revert someone else's lock.

If the reader from [tools/recovery-readout](../tools/recovery-readout/README.md) is available, its output distinguishes the preference, the kernel and the Keep Mac Awake journal. A present journal (`journal: present`) without an active session means an unfinished restoration on the Keep Mac Awake side.

## 2. Restore

1. Quit the app (**Quit Keep Mac Awake**). This sends Stop to the service.
2. If the lock remains and the Keep Mac Awake journal is present: run the installer or the uninstaller from the same version again. Both stop the services and perform recovery based on the journal, and on an error they abort, keeping the files for another attempt.
3. If the lock remains without a Keep Mac Awake journal: the setting does not come from Keep Mac Awake or was changed by another tool. Point the user to that tool or, with their consent, to the system command `sudo pmset -a disablesleep 0`.

## 3. What not to do

Do not manually delete files from `/Library/Application Support/KeepMacAwake` or `/Library/PrivilegedHelperTools/com.keepmacawake`; the recovery journal is needed for correct restoration. Do not disable SIP, Gatekeeper or FileVault. Do not ask for full system logs or user files.
