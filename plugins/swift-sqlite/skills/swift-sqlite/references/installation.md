# Installing the kit

The kit is optional and instruction-only: no server, hook, connector or telemetry.

## Claude Code

The Swift-SQLite repository is a Claude Code plugin marketplace:

```text
/plugin marketplace add ThorFuchs/Swift-SQLite
/plugin install swift-sqlite@swift-sqlite
```

Both commands change the user's settings, so they are the user's action.

## Codex and other agents

Copy `plugins/swift-sqlite/skills/swift-sqlite` (or the standalone skill archive's
`swift-sqlite` folder) to `.agents/skills/swift-sqlite` in the consumer workspace,
then invoke the skill by name. The portable `plugins/swift-sqlite/plugin.json` uses
the Agent Plugins format with `skills/` discovery.

Keep the library's contributor `AGENTS.md` separate from this consumer skill. Do
not install into a personal or global directory merely to try the kit.
