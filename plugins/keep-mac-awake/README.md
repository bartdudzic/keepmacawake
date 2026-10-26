# Keep Mac Awake plugin for AI agents

This plugin teaches an AI agent to use Keep Mac Awake, a macOS app that keeps a MacBook with Apple silicon awake with the lid closed during a session. With it, the agent starts a timed session before long work, stops it when the work is done, and tells you when the app needs something from you, such as AC power or a purchase after the trial.

It has two parts:

- **A skill** (`skills/keepmacawake/SKILL.md`, in the Agent Skills format): when to start and stop a session, what to ask you first, and what to do when the command refuses.
- **A session-start hook** (`hooks/session-start.sh`): when an agent session begins, it runs `keepmacawake status --agent` once and adds its few lines to the agent's context, so the agent knows the app is there without being reminded. It is read only: it makes no network connection and never starts, stops or changes anything.

The agent starts timed sessions on its own and tells you in one line. It always asks before a session without a time limit, battery use, installing the app and buying.

## Install

Claude Code:

```sh
claude plugin install keep-mac-awake --marketplace bartdudzic/keepmacawake
```

Codex (it asks you once, in `/hooks`, to trust the plugin's hook):

```sh
codex plugin marketplace add bartdudzic/keepmacawake
codex plugin add keep-mac-awake@keepmacawake
```

GitHub Copilot CLI:

```sh
copilot plugin marketplace add bartdudzic/keepmacawake
copilot plugin install keep-mac-awake@keepmacawake
```

Any agent that reads Agent Skills (the skill only, without the hook):

```sh
npx skills add bartdudzic/keepmacawake -g
```

The plugin needs the Keep Mac Awake app; without it, the agent offers to install it when a long task comes up. Guide for agents: <https://keepmacawake.com/agents.md>.

## Privacy

The plugin sends nothing anywhere. The hook's lines become part of the agent's conversation, so the agent's provider receives them: whether a session runs, its time left, the trial's time left and the price. They do not include this Mac's ID.

## License

The plugin is under the [MIT License](LICENSE). The Keep Mac Awake app it controls is not: buying it after the 3-day trial is covered by its own terms.
