# Contributing

Issues are welcome: bugs, unclear behavior, Macs where Keep Mac Awake does or does not work. Please include the Mac model, the macOS version and the Keep Mac Awake version.

Pull requests are not accepted for now, so that nobody spends effort on a change that cannot be merged. This may change later.

Security problems go to the address in [SECURITY.md](SECURITY.md), not to a public issue.

## Building and testing

```sh
swift build
swift test
scripts/scan-public-content.sh
```

Building and testing never install anything or change power settings. The signed release packages are built from a tag of this repository together with the menu bar app, which is not part of this repository.
