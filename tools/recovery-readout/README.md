# Recovery state reader

A support and acceptance tool, not installed on the user's Mac. It performs one non-modifying readout of three layers: the `SleepDisabled` preference in `SystemPowerSettings`, the `SleepDisabled` value in the kernel and the Keep Mac Awake recovery journal in `/Library/Application Support/KeepMacAwake`. It does not activate the backend, does not perform recovery, does not write files and does not connect to the network.

Build and readout (requires Xcode tools; the readout requires root):

```sh
mkdir -p .local/readout
xcrun swiftc -parse-as-library tools/recovery-readout/read-recovery-state.swift \
  -o .local/readout/KeepMacAwakeRecoveryReadout
sudo .local/readout/KeepMacAwakeRecoveryReadout --json
```

Expected idle state: `preferences` equal to `keyAbsent`, `containerAbsent` or `false` (whatever it was before the first session), `kernel` equal to `false`, `journal` equal to `absent`. Exit code 0 means a complete readout, not a correct state.

Synthetic tests (without reading the native state):

```sh
xcrun swiftc -parse-as-library -D RECOVERY_READOUT_TESTS \
  tools/recovery-readout/read-recovery-state.swift tools/recovery-readout/recovery-readout-tests.swift \
  -o .local/readout/RecoveryReadoutTests && .local/readout/RecoveryReadoutTests
```

Used in the [support procedure](../../docs/SUPPORT.md).
