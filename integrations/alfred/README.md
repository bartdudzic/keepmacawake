# Keep Mac Awake for Alfred

## Usage

Start, check and stop [Keep Mac Awake](https://keepmacawake.com) sessions via the `awake` keyword.

* `awake` shows whether a session runs and its time left, then the actions: keep this Mac awake for 1 hour, for 8 hours or with no time limit, and stop the session.
* `awake 3` (or `awake 3h`) starts a session of 3 hours. Any whole number from 1 to 168 works.
* `awake stop` and `awake status` go straight to those actions.

<kbd>↩︎</kbd> runs the action. A notification shows Keep Mac Awake's answer, for example the time left or why a session could not start.

The keyword can be changed in the Workflow's Configuration.

## What it needs

The [Keep Mac Awake](https://keepmacawake.com) app, installed on this Mac: a menu bar app that keeps a MacBook with Apple silicon awake with the lid closed during a session, on macOS 26 or later. It has a free trial. Without the app, the workflow offers a link to the website.

## What it runs

The workflow runs only the `keepmacawake` command that the app installs (`/usr/local/bin/keepmacawake`): `status` while you type, and `start --hours N`, `start --unlimited`, `stop` or `status` when you press Return. It makes no network connection, stores nothing and never starts a session on its own. The command's own rules apply: a session ends on its own after its hours, the trial limits a session's length, and quitting the app ends a session. The [command line reference](https://github.com/bartdudzic/keepmacawake/blob/main/docs/COMMAND-LINE.md) describes every answer.

## Build

The workflow is built from `src/` without Alfred:

```sh
./build.sh            # writes build/Keep-Mac-Awake.alfredworkflow
./test.sh             # tests the scripts with a fake keepmacawake command, then builds twice and compares
```

Open the `.alfredworkflow` file to install it in Alfred. The build is reproducible: the same sources give the same file.

## License

MIT, see [LICENSE](LICENSE).
